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
protocol HCKRequest: Sendable {
    func request(
        method: HTTPRequest.Method,
        url: URL,
        headers: HTTPFields,
        body: Data?
    ) async throws -> HCKResponse
}

/// A completed HTTP response.
///
/// `head` is the status and header fields. `body` is the collected payload, or `nil` when the
/// response had no body.
public struct HCKResponse: Sendable {
    public var head: HTTPResponse
    public var body: Data?

    public init(head: HTTPResponse, body: Data?) {
        self.head = head
        self.body = body
    }

    /// Challenges from `WWW-Authenticate` and `Proxy-Authenticate`.
    public var challenges: [HTTPChallenge] {
        HTTPChallenge.parse(head.headerFields)
    }
}

typealias Request = HCKRequest
typealias Response = HCKResponse

/// Failures produced while preparing or finishing a request.
public enum HTTPConnectionError: Error, Equatable, Sendable {
    /// The client does not perform this operation. CONNECT opens a tunnel and is not sent as a request.
    case unimplemented
    /// The URL or the message on the wire could not be used.
    case invalidRequest
    /// A body or multipart parameter is malformed.
    case invalidMultipart
    /// A one-shot body was consumed before a retry could use it.
    case bodyAlreadyConsumed
    /// A redirect or authentication retry requires a replayable body.
    case unreplayableBody
    /// A compressed response exceeded the configured expansion limit.
    case decompressionLimit
    /// The redirect limit was exhausted.
    case tooManyRedirects
    /// A buffered response exceeded `maximumBufferedBodySize`.
    case responseTooLarge
    /// The configured request deadline elapsed.
    case timeout
    /// The authentication refresh window rejected another refresh.
    case authenticationRefreshLimitExceeded
    /// An authentication provider could not renew its credential.
    case authenticationFailed(any Error)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.unimplemented, .unimplemented),
             (.invalidRequest, .invalidRequest),
             (.invalidMultipart, .invalidMultipart),
             (.bodyAlreadyConsumed, .bodyAlreadyConsumed),
             (.unreplayableBody, .unreplayableBody),
             (.decompressionLimit, .decompressionLimit),
             (.tooManyRedirects, .tooManyRedirects),
             (.responseTooLarge, .responseTooLarge),
             (.timeout, .timeout),
             (.authenticationRefreshLimitExceeded, .authenticationRefreshLimitExceeded),
             (.authenticationFailed, .authenticationFailed):
            true
        default:
            false
        }
    }
}
