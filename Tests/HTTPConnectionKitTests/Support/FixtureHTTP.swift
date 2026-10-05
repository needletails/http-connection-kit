//
//  FixtureHTTP.swift
//  HTTPConnectionKit
//
//  Created by NeedleTails on 10/5/26.
//

import Foundation
import NIOCore
import NIOHTTP1

/// Counts accepted connections. HTTP/2 and HTTP/3 streams on one connection do not increment it.
final class AcceptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Wakes a test once a `/hold` request has reached the server.
actor HoldGate {
    private var signaled = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        signaled = true
        waiter?.resume()
        waiter = nil
    }

    func wait() async {
        if signaled {
            return
        }
        await withCheckedContinuation { continuation in
            if signaled {
                continuation.resume()
            } else {
                waiter = continuation
            }
        }
    }
}

/// What the fixture should write after it has the whole request.
struct FixtureResponse: Sendable {
    var informational: Bool
    var status: Int
    var headers: [(String, String)]
    var body: ByteBuffer?
    var trailers: [(String, String)]
}

enum FixturePlan: Sendable {
    case hold
    case response(FixtureResponse)
}

/// Builds the fixture response for one collected request.
///
/// `/hold` never answers, so a test can cancel the request. `/informational` sends `100` and then
/// `200`. `/trailers` ends with `x-trailer`. `/empty` and `HEAD` have no body. `/status/<code>`
/// uses that status. Every other path echoes the request.
func fixturePlan(
    method: String,
    uri: String,
    version: String?,
    scheme: String?,
    authority: String?,
    headers: [(String, String)],
    body: ByteBuffer
) -> FixturePlan {
    let path = fixturePath(uri)
    if path == "/hold" {
        return .hold
    }

    let informational = path == "/informational"
    let trailers = path == "/trailers"
    let empty = path == "/empty" || method == "HEAD"
    let status: Int
    if path.hasPrefix("/status/"), let code = Int(path.dropFirst("/status/".count)), (100...999).contains(code) {
        status = code
    } else if empty && path == "/empty" {
        status = 204
    } else {
        status = 200
    }

    let payload: ByteBuffer?
    if empty {
        payload = nil
    } else if informational {
        payload = ByteBuffer(string: "final")
    } else if trailers {
        payload = ByteBuffer(string: "trailed")
    } else {
        payload = fixtureEcho(
            method: method,
            uri: uri,
            version: version,
            scheme: scheme,
            authority: authority,
            headers: headers,
            body: body
        )
    }

    var responseHeaders = [
        ("x-server", "fixture"),
        ("x-method", method),
        ("x-uri", uri),
        ("content-type", "text/plain; charset=utf-8"),
    ]
    if !trailers, let payload {
        responseHeaders.append(("content-length", String(payload.readableBytes)))
    } else if payload == nil {
        responseHeaders.append(("content-length", "0"))
    }

    return .response(
        FixtureResponse(
            informational: informational,
            status: status,
            headers: responseHeaders,
            body: payload,
            trailers: trailers ? [("x-trailer", "yes")] : []
        )
    )
}

func fixturePath(_ uri: String) -> String {
    guard let query = uri.firstIndex(of: "?") else {
        return uri
    }
    return String(uri[..<query])
}

func fixtureEcho(
    method: String,
    uri: String,
    version: String?,
    scheme: String?,
    authority: String?,
    headers: [(String, String)],
    body: ByteBuffer
) -> ByteBuffer {
    var lines = ["method=\(method)", "uri=\(uri)"]
    if let version {
        lines.append("version=\(version)")
    }
    if let scheme {
        lines.append("scheme=\(scheme)")
    }
    if let authority {
        lines.append("authority=\(authority)")
    }
    for (name, value) in headers {
        lines.append("header.\(name.lowercased())=\(value)")
    }
    let encoded = Data(body.readableBytesView).base64EncodedString()
    lines.append("body-base64=\(encoded)")
    return ByteBuffer(string: lines.joined(separator: "\n"))
}

/// The request echo carried in a fixture body.
struct FixtureEcho: Sendable {
    var fields: [String: String]
    var body: Data

    init(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        var fields: [String: String] = [:]
        var encodedBody = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            if let range = line.range(of: "body-base64=") {
                encodedBody = String(line[range.upperBound...])
            } else if let separator = line.firstIndex(of: "=") {
                fields[String(line[..<separator])] = String(line[line.index(after: separator)...])
            }
        }
        self.fields = fields
        self.body = Data(base64Encoded: encodedBody) ?? Data()
    }
}

/// HTTP/1 and HTTP/2 server handler. Both pipelines deliver `HTTPServerRequestPart`.
final class FixtureHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let hold: HoldGate
    private var method = ""
    private var uri = ""
    private var version = ""
    private var headers: [(String, String)] = []
    private var body = ByteBuffer()
    private var sawHead = false

    init(hold: HoldGate) {
        self.hold = hold
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch Self.unwrapInboundIn(data) {
        case .head(let head):
            sawHead = true
            method = head.method.rawValue
            uri = head.uri
            version = "\(head.version.major).\(head.version.minor)"
            headers = head.headers.map { ($0.name, $0.value) }
            body = context.channel.allocator.buffer(capacity: 0)
            if fixturePath(uri) == "/hold" {
                let hold = self.hold
                Task { await hold.signal() }
            }
        case .body(var buffer):
            body.writeBuffer(&buffer)
        case .end:
            guard sawHead else {
                return
            }
            let plan = fixturePlan(
                method: method,
                uri: uri,
                version: version,
                scheme: nil,
                authority: nil,
                headers: headers,
                body: body
            )
            guard case .response(let response) = plan else {
                return
            }
            write(response, context: context)
        }
    }

    private func write(_ response: FixtureResponse, context: ChannelHandlerContext) {
        if response.informational {
            let interim = HTTPResponseHead(
                version: .http1_1,
                status: .custom(code: 100, reasonPhrase: "Continue")
            )
            context.write(Self.wrapOutboundOut(.head(interim)), promise: nil)
        }

        var headers = HTTPHeaders()
        for (name, value) in response.headers {
            headers.add(name: name, value: value)
        }
        let head = HTTPResponseHead(
            version: .http1_1,
            status: HTTPResponseStatus(statusCode: response.status),
            headers: headers
        )
        context.write(Self.wrapOutboundOut(.head(head)), promise: nil)
        if let payload = response.body, payload.readableBytes > 0 {
            context.write(Self.wrapOutboundOut(.body(.byteBuffer(payload))), promise: nil)
        }
        let trailers = response.trailers.isEmpty
            ? nil
            : HTTPHeaders(response.trailers.map { ($0.0, $0.1) })
        context.writeAndFlush(Self.wrapOutboundOut(.end(trailers)), promise: nil)
    }
}
