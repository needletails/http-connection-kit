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
#if canImport(Network)
import Network
#endif

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
    let configurationValidationError: Configuration.ValidationError?
    let authenticationSession: (any HTTPAuthenticationSession)?
    var connections: [ObjectIdentifier: LiveConnection] = [:]
    /// Origins whose QUIC handshake failed. Later requests on this client use TCP until the
    /// network path changes.
    var quicDeniedOrigins: Set<Origin> = []
    /// QUIC handshakes in flight, one per origin. Requests share the attempt instead of racing their own.
    var quicAttempts: [Origin: QUICAttempt] = [:]
    /// Connections being opened for an origin that may yield a multiplexed connection. Requests
    /// arriving meanwhile wait for the opener and then reuse its connection.
    var pendingOpens: [Origin: SharedOutcome<Void>] = [:]
    /// TLS origins that selected HTTP/1. Requests to them do not wait on each other's opens.
    var singleStreamOrigins: Set<Origin> = []
    #if canImport(Network)
    /// Started on the first QUIC denial. A path change clears `quicDeniedOrigins`.
    private var pathMonitor: NWPathMonitor?
    private var pathSignature: String?
    #endif

    /// Creates a client using the protocol negotiation policy in `configuration`.
    public init(configuration: Configuration = Configuration()) {
        version = configuration.protocols.preferredVersion.nio
        self.configuration = configuration
        do {
            try configuration.validate()
            configurationValidationError = nil
        } catch {
            configurationValidationError = error
        }
        authenticationSession = configuration.authentication.map {
            makeAuthenticationSession($0, window: configuration.authenticationRefreshWindow)
        }
    }

    /// Creates a client and reports an invalid configuration immediately.
    public init(validating configuration: Configuration) throws (Configuration.ValidationError) {
        try configuration.validate()
        version = configuration.protocols.preferredVersion.nio
        self.configuration = configuration
        configurationValidationError = nil
        authenticationSession = configuration.authentication.map {
            makeAuthenticationSession($0, window: configuration.authenticationRefreshWindow)
        }
    }

    deinit {
        // Channel.close is thread-safe. Deinitialization cannot await, so this is deliberately a
        // best-effort safety net; shutdown() remains the deterministic way to wait for cleanup.
        for connection in connections.values {
            connection.channel.close(promise: nil)
        }
        for attempt in quicAttempts.values {
            attempt.task?.cancel()
        }
        #if canImport(Network)
        pathMonitor?.cancel()
        #endif
    }

    /// Closes every connection this client still holds.
    ///
    /// In-flight request streams fail and close with their connection. QUIC handshakes still in
    /// flight are cancelled. Call this when the client is finished.
    public func shutdown() async {
        let attempts = quicAttempts.values
        quicAttempts.removeAll()
        for attempt in attempts {
            attempt.task?.cancel()
        }
        #if canImport(Network)
        pathMonitor?.cancel()
        pathMonitor = nil
        pathSignature = nil
        #endif
        let open = connections.values.map(\.channel)
        connections.removeAll()
        for channel in open {
            await Self.closeConnection(channel)
        }
    }

    /// Tells the client the device's network path changed.
    ///
    /// Origins that were pinned to TCP after a failed QUIC handshake are allowed to try QUIC again.
    /// Apple platforms call this from `NWPathMonitor`. Android hosts should call it from a
    /// `ConnectivityManager.NetworkCallback`, which this package cannot observe directly.
    public func networkPathDidChange() {
        quicDeniedOrigins.removeAll()
    }

    /// Remembers that QUIC failed for an origin and starts watching for a path change.
    func denyQUIC(for origin: Origin) {
        quicDeniedOrigins.insert(origin)
        #if canImport(Network)
        startPathMonitorIfNeeded()
        #endif
    }

    #if canImport(Network)
    private func startPathMonitorIfNeeded() {
        guard pathMonitor == nil else {
            return
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            // The first update describes the current path and is the baseline, not a change.
            let signature = "\(path.status)|\(path.availableInterfaces.map(\.name).sorted().joined(separator: ","))"
            Task { await self?.pathUpdated(signature: signature) }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        pathMonitor = monitor
    }

    private func pathUpdated(signature: String) {
        defer { pathSignature = signature }
        guard let previous = pathSignature, previous != signature else {
            return
        }
        networkPathDidChange()
    }
    #endif

    /// Sends one request and returns the collected response.
    ///
    /// GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS, TRACE, QUERY, and any other method token share
    /// one exchange. CONNECT is rejected because it opens a tunnel.
    public func request(
        method: HTTPRequest.Method,
        url: URL,
        headers: HTTPFields = [:],
        body: Data? = nil
    ) async throws -> HCKResponse {
        try await request(method: method, url: url, headers: headers, body: body, options: RequestOptions())
    }

    /// Sends one request with behavior scoped to this request.
    public func request(
        method: HTTPRequest.Method,
        url: URL,
        headers: HTTPFields = [:],
        body: Data? = nil,
        options: RequestOptions
    ) async throws -> HCKResponse {
        try await collectedRequest(
            method: method,
            url: url,
            headers: headers,
            body: body.map(HTTPBody.data),
            timeout: options.timeout,
            onProgress: options.onProgress
        )
    }

    /// Sends a swift-http-types request and collects the response.
    public func request(
        _ request: HTTPRequest,
        body: HTTPBody? = nil,
        options: RequestOptions = RequestOptions()
    ) async throws -> HCKResponse {
        try await collectedRequest(
            method: request.method,
            url: try requestURL(request),
            headers: request.headerFields,
            body: body,
            timeout: options.timeout,
            onProgress: options.onProgress
        )
    }

    /// Sends a body sequence and collects the response.
    public func request(
        method: HTTPRequest.Method,
        url: URL,
        headers: HTTPFields,
        body: HTTPBody,
        options: RequestOptions = RequestOptions()
    ) async throws -> HCKResponse {
        try await collectedRequest(
            method: method,
            url: url,
            headers: headers,
            body: body,
            timeout: options.timeout,
            onProgress: options.onProgress
        )
    }

    /// Sends chunks from any `AsyncSequence` and collects the response.
    public func request<S: AsyncSequence & Sendable>(
        method: HTTPRequest.Method,
        url: URL,
        headers: HTTPFields,
        body: S,
        options: RequestOptions = RequestOptions()
    ) async throws -> HCKResponse where S.Element == Data {
        let stream = HTTPBody.sequence(body)
        return try await collectedRequest(
            method: method,
            url: url,
            headers: headers,
            body: stream,
            timeout: options.timeout,
            onProgress: options.onProgress
        )
    }

    /// Returns the response head and a body that is pulled from the socket.
    public func requestStream(
        method: HTTPRequest.Method,
        url: URL,
        headers: HTTPFields = [:],
        body: HTTPBody? = nil,
        options: RequestOptions = RequestOptions()
    ) async throws -> StreamingResponse {
        let result = try await requestPrepared(
            method: method,
            url: url,
            headers: headers,
            body: body,
            collect: false,
            timeout: options.timeout,
            onProgress: options.onProgress
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
        body: HTTPBody? = nil,
        options: RequestOptions = RequestOptions()
    ) async throws -> StreamingResponse {
        try await requestStream(
            method: request.method,
            url: try requestURL(request),
            headers: request.headerFields,
            body: body,
            options: options
        )
    }

    public func requestStream(
        method: HTTPRequest.Method,
        url: URL,
        headers: HTTPFields,
        body: Data?,
        options: RequestOptions = RequestOptions()
    ) async throws -> StreamingResponse {
        try await requestStream(
            method: method,
            url: url,
            headers: headers,
            body: body.map(HTTPBody.data),
            options: options
        )
    }

    public func requestStream<S: AsyncSequence & Sendable>(
        method: HTTPRequest.Method,
        url: URL,
        headers: HTTPFields = [:],
        body: S,
        options: RequestOptions = RequestOptions()
    ) async throws -> StreamingResponse where S.Element == Data {
        try await requestStream(
            method: method,
            url: url,
            headers: headers,
            body: Optional(HTTPBody.sequence(body)),
            options: options
        )
    }

    public func requestStream(
        method: HTTPRequest.Method,
        url: URL,
        headers: HTTPFields = [:],
        body: HTTPBody,
        options: RequestOptions = RequestOptions()
    ) async throws -> StreamingResponse {
        try await requestStream(
            method: method,
            url: url,
            headers: headers,
            body: Optional(body),
            options: options
        )
    }

    private func collectedRequest(
        method: HTTPRequest.Method,
        url: URL,
        headers: HTTPFields,
        body: HTTPBody?,
        timeout: Duration?,
        onProgress: (@Sendable (HTTPProgress) -> Void)? = nil
    ) async throws -> Response {
        let result = try await requestPrepared(
            method: method,
            url: url,
            headers: headers,
            body: body,
            collect: true,
            timeout: timeout,
            onProgress: onProgress
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

}
