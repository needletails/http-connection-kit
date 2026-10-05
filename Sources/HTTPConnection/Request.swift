//
//  Request.swift
//  HTTPConnectionKit
//
//  Created by NeedleTails on 10/5/26.
//

import Foundation
import HTTPTypes

/// One request operation for HTTP/1, HTTP/2, and HTTP/3.
///
/// The method, URL, headers, and optional body are the whole request. The connection selects the
/// protocol during the handshake.
public protocol Request: Sendable {
    func request(
        method: HTTPRequest.Method,
        url: URL,
        headers: HTTPFields,
        body: Data?
    ) async throws -> Response
}

/// A completed HTTP response.
///
/// `head` is the status and header fields. `body` is the collected payload, or `nil` when the
/// response had no body.
public struct Response: Sendable {
    public var head: HTTPResponse
    public var body: Data?

    public init(head: HTTPResponse, body: Data?) {
        self.head = head
        self.body = body
    }
}

/// Failures produced while preparing or finishing a request.
public enum HTTPConnectionError: Error, Equatable, Sendable {
    /// The client does not perform this operation. CONNECT opens a tunnel and is not sent as a request.
    case unimplemented
    /// The URL or the message on the wire could not be used.
    case invalidRequest
}
