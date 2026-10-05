//
//  HTTPConnection.swift
//  HTTPConnectionKit
//
//  Created by NeedleTails on 10/5/26.
//

import Foundation
import HTTPTypes
import NIOCore
import NIOHTTP1

/// A long-lived HTTP client.
///
/// `version` is the highest protocol this client may use. One TLS handshake offers the protocols
/// under that cap, and the server selects HTTP/2 or HTTP/1.1. When the cap is HTTP/3, that QUIC
/// handshake runs beside the TCP connection and is used only if it succeeds.
///
/// Create one instance per TLS policy and call `shutdown()` when it is finished. The event-loop
/// groups are process-wide and are not shut down with the client.
public actor HTTPConnection: Request {
    /// Highest HTTP version this client may use.
    let version: HTTPVersion
    /// Channel and TLS settings applied to every connection this client opens.
    let configuration: Configuration
    let authenticationSession: (any HTTPAuthenticationSession)?
    let proxyAuthenticationSession: (any HTTPAuthenticationSession)?
    var connections: [ObjectIdentifier: LiveConnection] = [:]
    /// Origins whose QUIC handshake failed while TCP succeeded. Later requests on this client use TCP.
    var quicDeniedOrigins: Set<Origin> = []

    /// Creates a client whose preferred version is the highest protocol it may negotiate.
    public init(preferred version: HTTPVersion = .http3, configuration: Configuration = Configuration()) {
        self.version = version
        self.configuration = configuration
        authenticationSession = configuration.authentication.map {
            makeAuthenticationSession($0, window: configuration.authenticationRefreshWindow)
        }
        proxyAuthenticationSession = configuration.proxyAuthentication.map {
            makeAuthenticationSession($0, window: configuration.authenticationRefreshWindow)
        }
    }

    deinit {
        // Channel.close is thread-safe. Deinitialization cannot await, so this is deliberately a
        // best-effort safety net; shutdown() remains the deterministic way to wait for cleanup.
        for connection in connections.values {
            connection.channel.close(promise: nil)
        }
    }

    /// Closes every connection this client still holds.
    ///
    /// In-flight request streams fail and close with their connection. Call this when the client is finished.
    public func shutdown() async {
        let open = connections.values.map(\.channel)
        connections.removeAll()
        for channel in open {
            await Self.closeConnection(channel)
        }
    }

    /// Sends one request and returns the collected response.
    ///
    /// GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS, TRACE, QUERY, and any other method token share
    /// one exchange. CONNECT is rejected because it opens a tunnel.
    public func request(
        method: HTTPRequest.Method,
        url: URL,
        headers: HTTPFields = [:],
        body: Data? = nil
    ) async throws -> Response {
        let components = try requestComponents(from: url)

        switch method {
        case .connect:
            throw HTTPConnectionError.unimplemented
        case .get:
            return try await performGet(components, headers: headers, body: body)
        case .head:
            return try await performHead(components, headers: headers, body: body)
        case .post:
            return try await performPost(components, headers: headers, body: body)
        case .put:
            return try await performPut(components, headers: headers, body: body)
        case .patch:
            return try await performPatch(components, headers: headers, body: body)
        case .delete:
            return try await performDelete(components, headers: headers, body: body)
        case .options:
            return try await performOptions(components, headers: headers, body: body)
        case .trace:
            return try await performTrace(components, headers: headers, body: body)
        case .query:
            return try await performQuery(components, headers: headers, body: body)
        default:
            return try await performExtension(method, components, headers: headers, body: body)
        }
    }

    /// Sends a swift-http-types request and collects the response.
    public func request(
        _ request: HTTPRequest,
        body: HTTPBody? = nil
    ) async throws -> Response {
        try await collectedRequest(
            method: request.method,
            url: try requestURL(request),
            headers: request.headerFields,
            body: body
        )
    }

    /// Sends a body sequence and collects the response.
    public func request(
        method: HTTPRequest.Method,
        url: URL,
        headers: HTTPFields,
        body: HTTPBody
    ) async throws -> Response {
        try await collectedRequest(method: method, url: url, headers: headers, body: body)
    }

    /// Sends chunks from any `AsyncSequence` and collects the response.
    public func request<S: AsyncSequence & Sendable>(
        method: HTTPRequest.Method,
        url: URL,
        headers: HTTPFields,
        body: S
    ) async throws -> Response where S.Element == Data {
        let stream = HTTPBody.sequence(body)
        return try await collectedRequest(method: method, url: url, headers: headers, body: stream)
    }

    /// Returns the response head and a body that is pulled from the socket.
    public func requestStream(
        method: HTTPRequest.Method,
        url: URL,
        headers: HTTPFields = [:],
        body: HTTPBody? = nil
    ) async throws -> StreamingResponse {
        let result = try await requestPrepared(
            method: method,
            url: url,
            headers: headers,
            body: body,
            collect: false
        )
        switch result {
        case .streaming(let streamed):
            return streamed
        case .collected(let response):
            let trailerBox = TrailerBox()
            await trailerBox.set(HTTPFields())
            return StreamingResponse(
                head: response.head,
                body: HTTPBody.data(response.body ?? Data()),
                trailerBox: trailerBox
            )
        }
    }

    /// Sends a swift-http-types request and streams the response body.
    public func requestStream(
        _ request: HTTPRequest,
        body: HTTPBody? = nil
    ) async throws -> StreamingResponse {
        try await requestStream(
            method: request.method,
            url: try requestURL(request),
            headers: request.headerFields,
            body: body
        )
    }

    public func requestStream(
        method: HTTPRequest.Method,
        url: URL,
        headers: HTTPFields,
        body: Data?
    ) async throws -> StreamingResponse {
        try await requestStream(
            method: method,
            url: url,
            headers: headers,
            body: body.map(HTTPBody.data)
        )
    }

    public func requestStream<S: AsyncSequence & Sendable>(
        method: HTTPRequest.Method,
        url: URL,
        headers: HTTPFields = [:],
        body: S
    ) async throws -> StreamingResponse where S.Element == Data {
        try await requestStream(
            method: method,
            url: url,
            headers: headers,
            body: Optional(HTTPBody.sequence(body))
        )
    }

    public func requestStream(
        method: HTTPRequest.Method,
        url: URL,
        headers: HTTPFields = [:],
        body: HTTPBody
    ) async throws -> StreamingResponse {
        try await requestStream(
            method: method,
            url: url,
            headers: headers,
            body: Optional(body)
        )
    }

    private func collectedRequest(
        method: HTTPRequest.Method,
        url: URL,
        headers: HTTPFields,
        body: HTTPBody?
    ) async throws -> Response {
        let result = try await requestPrepared(
            method: method,
            url: url,
            headers: headers,
            body: body,
            collect: true
        )
        guard case .collected(let response) = result else {
            throw HTTPConnectionError.invalidRequest
        }
        return response
    }

    private func requestURL(_ request: HTTPRequest) throws -> URL {
        guard let scheme = request.scheme,
              let authority = request.authority,
              !scheme.isEmpty,
              !authority.isEmpty
        else {
            throw HTTPConnectionError.invalidRequest
        }
        let path = request.path ?? "/"
        guard let url = URL(string: "\(scheme)://\(authority)\(path)") else {
            throw HTTPConnectionError.invalidRequest
        }
        return url
    }

    /// Accepts `http` and `https` URLs and builds the path, query, and authority the wire request uses.
    func requestComponents(from url: URL) throws -> RequestComponents {
        guard
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = parts.scheme?.lowercased(),
            let host = parts.host,
            !host.isEmpty
        else {
            throw HTTPConnectionError.invalidRequest
        }

        let enableTLS: Bool
        let defaultPort: Int
        switch scheme {
        case "https":
            enableTLS = true
            defaultPort = 443
        case "http":
            enableTLS = false
            defaultPort = 80
        default:
            throw HTTPConnectionError.invalidRequest
        }

        let port = parts.port ?? defaultPort
        guard (1...65535).contains(port) else {
            throw HTTPConnectionError.invalidRequest
        }

        var path = parts.percentEncodedPath
        if path.isEmpty {
            path = "/"
        }
        if let query = parts.percentEncodedQuery {
            path += "?\(query)"
        }

        let authorityHost = host.contains(":") ? "[\(host)]" : host
        let authority = port == defaultPort ? authorityHost : "\(authorityHost):\(port)"
        return RequestComponents(
            scheme: scheme,
            host: host,
            port: port,
            path: path,
            authority: authority,
            enableTLS: enableTLS
        )
    }

    private func performGet(
        _ components: RequestComponents,
        headers: HTTPFields,
        body: Data?
    ) async throws -> Response {
        try await performExchange(.get, components, headers: headers, body: body)
    }

    private func performHead(
        _ components: RequestComponents,
        headers: HTTPFields,
        body: Data?
    ) async throws -> Response {
        try await performExchange(.head, components, headers: headers, body: body)
    }

    private func performPost(
        _ components: RequestComponents,
        headers: HTTPFields,
        body: Data?
    ) async throws -> Response {
        try await performExchange(.post, components, headers: headers, body: body)
    }

    private func performPatch(
        _ components: RequestComponents,
        headers: HTTPFields,
        body: Data?
    ) async throws -> Response {
        try await performExchange(.patch, components, headers: headers, body: body)
    }

    private func performPut(
        _ components: RequestComponents,
        headers: HTTPFields,
        body: Data?
    ) async throws -> Response {
        try await performExchange(.put, components, headers: headers, body: body)
    }

    private func performDelete(
        _ components: RequestComponents,
        headers: HTTPFields,
        body: Data?
    ) async throws -> Response {
        try await performExchange(.delete, components, headers: headers, body: body)
    }

    private func performOptions(
        _ components: RequestComponents,
        headers: HTTPFields,
        body: Data?
    ) async throws -> Response {
        try await performExchange(.options, components, headers: headers, body: body)
    }

    private func performTrace(
        _ components: RequestComponents,
        headers: HTTPFields,
        body: Data?
    ) async throws -> Response {
        try await performExchange(.trace, components, headers: headers, body: body)
    }

    private func performQuery(
        _ components: RequestComponents,
        headers: HTTPFields,
        body: Data?
    ) async throws -> Response {
        try await performExchange(.query, components, headers: headers, body: body)
    }

    /// Extension methods such as WebDAV verbs use the same request shape as the standard methods.
    private func performExtension(
        _ method: HTTPRequest.Method,
        _ components: RequestComponents,
        headers: HTTPFields,
        body: Data?
    ) async throws -> Response {
        try await performExchange(method, components, headers: headers, body: body)
    }

    /// Opens the request channel for the negotiated protocol, then reads the response.
    private func performExchange(
        _ method: HTTPRequest.Method,
        _ components: RequestComponents,
        headers: HTTPFields,
        body: Data?
    ) async throws -> Response {
        try await collectedRequest(
            method: method,
            url: components.url,
            headers: headers,
            body: body.map(HTTPBody.data)
        )
    }
}
