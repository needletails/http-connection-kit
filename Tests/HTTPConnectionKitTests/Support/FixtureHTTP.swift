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

/// Wakes a test once a request has reached a fixture checkpoint.
actor HoldGate {
    private var signaled = false
    private var continuation: AsyncStream<Void>.Continuation?

    func signal() {
        signaled = true
        continuation?.yield(())
        continuation?.finish()
        continuation = nil
    }

    func wait() async {
        if signaled {
            return
        }
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        if signaled {
            continuation.finish()
            self.continuation = nil
            return
        }
        await withTaskCancellationHandler {
            for await _ in stream {
                return
            }
        } onCancel: {
            continuation.finish()
        }
    }
}

final class FixtureGates: @unchecked Sendable {
    let hold = HoldGate()
    let upload = HoldGate()
    let drip = HoldGate()
    let dripRelease = HoldGate()
    let multipart = HoldGate()
    let multipartRelease = HoldGate()
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
    case drip
    case multipartPause
}

enum FixtureCompressed {
    static let gzipHello = Data(hex: "1f8b08000000000002ffcb48cdc9c9d74dafca2c0000a8ae42270a000000")
    static let deflateHello = Data(hex: "789ccb48cdc9c9d74d494dcb492c49050023740517")
    static let gzipBomb = Data(
        hex: "1f8b08000000000002ffedc1010d000000c2a0f74f6d0f07140000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004f0625b3b71650c30000"
    )
}

private extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}

/// Builds the fixture response for one collected request.
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
    if path == "/drip" {
        return .drip
    }
    if path == "/multipart-pause" {
        return .multipartPause
    }

    let headerMap = fixtureHeaderMap(headers)
    let informational = path == "/informational"
    let trailers = path == "/trailers"
    let empty = path == "/empty" || method == "HEAD"
    var status = 200
    var responseHeaders: [(String, String)] = [
        ("x-server", "fixture"),
        ("x-method", method),
        ("x-uri", uri),
    ]
    var payload: ByteBuffer?
    var responseTrailers: [(String, String)] = []

    if path.hasPrefix("/status/"), let code = Int(path.dropFirst("/status/".count)), (100...999).contains(code) {
        status = code
        payload = fixtureEcho(
            method: method,
            uri: uri,
            version: version,
            scheme: scheme,
            authority: authority,
            headers: headers,
            body: body
        )
    } else if let redirect = fixtureRedirect(path: path, uri: uri, headers: headers, scheme: scheme) {
        status = redirect.status
        responseHeaders.append(("location", redirect.location))
        payload = ByteBuffer(string: "redirect")
    } else if path == "/gzip" {
        responseHeaders.append(("content-encoding", "gzip"))
        payload = ByteBuffer(bytes: FixtureCompressed.gzipHello)
    } else if path == "/deflate" {
        responseHeaders.append(("content-encoding", "deflate"))
        payload = ByteBuffer(bytes: FixtureCompressed.deflateHello)
    } else if path == "/br" {
        responseHeaders.append(("content-encoding", "br"))
        payload = ByteBuffer(string: "brotli-raw")
    } else if path == "/gzip-bomb" {
        responseHeaders.append(("content-encoding", "gzip"))
        payload = ByteBuffer(bytes: FixtureCompressed.gzipBomb)
    } else if path == "/large" {
        let count = Int(fixtureQuery(uri, name: "bytes") ?? "") ?? 0
        payload = ByteBuffer(repeating: 0x61, count: max(count, 0))
    } else if path == "/range" || path == "/bytes" {
        let resource = "0123456789"
        responseHeaders.append(("etag", "\"r1\""))
        responseHeaders.append(("last-modified", "Wed, 21 Oct 2015 07:28:00 GMT"))
        responseHeaders.append(("accept-ranges", "bytes"))
        let range = headerMap["range"]
        let ifRange = headerMap["if-range"]
        let honorRange = range != nil && (ifRange == nil || ifRange == "\"r1\"" || ifRange == "Wed, 21 Oct 2015 07:28:00 GMT")
        if honorRange, let range, let start = fixtureRangeStart(range) {
            let slice = String(resource.dropFirst(start))
            status = 206
            responseHeaders.append(("content-range", "bytes \(start)-\(resource.count - 1)/\(resource.count)"))
            payload = ByteBuffer(string: slice)
        } else {
            payload = ByteBuffer(string: resource)
        }
    } else if let auth = fixtureAuth(path: path, headerMap: headerMap, body: body) {
        status = auth.status
        responseHeaders.append(contentsOf: auth.headers)
        payload = ByteBuffer(string: auth.body)
    } else if path == "/set-cookie" {
        responseHeaders.append(("set-cookie", "session=1; Path=/; SameSite=Lax"))
        payload = ByteBuffer(string: "ok")
    } else if path == "/set-cookie-path" {
        responseHeaders.append(("set-cookie", "scoped=1; Path=/echo"))
        payload = ByteBuffer(string: "ok")
    } else if path == "/set-cookie-secure" {
        responseHeaders.append(("set-cookie", "secure=1; Secure; Path=/"))
        payload = ByteBuffer(string: "ok")
    } else if empty && path == "/empty" {
        status = 204
        payload = nil
    } else if informational {
        payload = ByteBuffer(string: "final")
    } else if trailers {
        payload = ByteBuffer(string: "trailed")
        responseTrailers = [("x-trailer", "yes")]
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
        responseHeaders.append(("content-type", "text/plain; charset=utf-8"))
    }

    if method == "HEAD" {
        payload = nil
    }
    if payload == nil {
        responseHeaders.append(("content-length", "0"))
    } else if responseTrailers.isEmpty, let payload {
        responseHeaders.append(("content-length", String(payload.readableBytes)))
    }

    return .response(
        FixtureResponse(
            informational: informational,
            status: status,
            headers: responseHeaders,
            body: payload,
            trailers: responseTrailers
        )
    )
}

func fixturePath(_ uri: String) -> String {
    guard let query = uri.firstIndex(of: "?") else {
        return uri
    }
    return String(uri[..<query])
}

func fixtureQuery(_ uri: String, name: String) -> String? {
    guard let queryIndex = uri.firstIndex(of: "?") else {
        return nil
    }
    let query = uri[uri.index(after: queryIndex)...]
    for pair in query.split(separator: "&") {
        let pieces = pair.split(separator: "=", maxSplits: 1)
        if pieces.first.map(String.init) == name {
            return pieces.count == 2 ? String(pieces[1]) : ""
        }
    }
    return nil
}

func fixtureHeaderMap(_ headers: [(String, String)]) -> [String: String] {
    var map: [String: String] = [:]
    for (name, value) in headers {
        map[name.lowercased()] = value
    }
    return map
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

private func fixtureRedirect(
    path: String,
    uri: String,
    headers: [(String, String)],
    scheme: String?
) -> (status: Int, location: String)? {
    if path == "/redirect-loop" {
        return (302, "/redirect-loop")
    }
    if path == "/redirect-host" {
        let host = fixtureHeaderMap(headers)["host"] ?? "127.0.0.1"
        let port: String
        if let colon = host.lastIndex(of: ":") {
            port = String(host[host.index(after: colon)...])
        } else {
            port = scheme == "https" ? "443" : "80"
        }
        let nextScheme = scheme ?? "http"
        return (302, "\(nextScheme)://localhost:\(port)/echo")
    }
    if path.hasPrefix("/redirect/") {
        let code = Int(path.dropFirst("/redirect/".count)) ?? 302
        let resolved = fixtureQuery(uri, name: "to") ?? "/echo"
        return (code, resolved.hasPrefix("/") || resolved.contains("://") ? resolved : "/\(resolved)")
    }
    return nil
}

private func fixtureRangeStart(_ header: String) -> Int? {
    guard header.lowercased().hasPrefix("bytes=") else {
        return nil
    }
    let spec = header.dropFirst("bytes=".count)
    guard let dash = spec.firstIndex(of: "-") else {
        return nil
    }
    return Int(spec[..<dash])
}

private func fixtureAuth(
    path: String,
    headerMap: [String: String],
    body: ByteBuffer
) -> (status: Int, headers: [(String, String)], body: String)? {
    switch path {
    case "/auth/basic":
        if headerMap["authorization"] == "Basic dXNlcjpzZWNyZXQ=" {
            return (200, [], "ok")
        }
        return (401, [("www-authenticate", "Basic realm=\"x\", Bearer realm=\"api\"")], "denied")
    case "/auth/bearer":
        if headerMap["authorization"] == "Bearer token-1" {
            return (200, [], "ok")
        }
        return (401, [("www-authenticate", "Bearer realm=\"api\"")], "denied")
    case "/auth/digest":
        if let authorization = headerMap["authorization"], authorization.lowercased().hasPrefix("digest") {
            return (200, [], authorization)
        }
        return (
            401,
            [
                ("www-authenticate", "Digest realm=\"x\", nonce=\"abc\", algorithm=MD5, qop=\"auth\""),
                ("www-authenticate", "Digest realm=\"x\", nonce=\"abc\", algorithm=SHA-256, qop=\"auth\""),
            ],
            "denied"
        )
    case "/auth/digest-stale":
        if let authorization = headerMap["authorization"], authorization.contains("nonce=\"xyz\"") {
            return (200, [], authorization)
        }
        if headerMap["authorization"] != nil {
            return (
                401,
                [("www-authenticate", "Digest realm=\"x\", nonce=\"xyz\", algorithm=SHA-256, qop=\"auth\", stale=true")],
                "stale"
            )
        }
        return (
            401,
            [("www-authenticate", "Digest realm=\"x\", nonce=\"abc\", algorithm=SHA-256, qop=\"auth\"")],
            "denied"
        )
    case "/auth/proxy":
        if headerMap["proxy-authorization"] == "Basic dXNlcjpzZWNyZXQ=" {
            return (200, [], "ok")
        }
        return (407, [("proxy-authenticate", "Basic realm=\"proxy\"")], "denied")
    case "/auth/refresh":
        if let authorization = headerMap["authorization"], authorization == "Bearer fresh" {
            let posted = String(decoding: body.readableBytesView, as: UTF8.self)
            return (200, [], "\(authorization)\n\(posted)")
        }
        return (401, [], "expired")
    case "/auth/refresh-rejected":
        return (401, [], "expired")
    case "/auth/refresh-large":
        return (401, [], String(repeating: "x", count: 1024))
    case "/auth/bearer-scope":
        return (
            401,
            [("www-authenticate", "Bearer realm=\"api\", error=\"insufficient_scope\"")],
            "scope"
        )
    default:
        return nil
    }
}

func fixtureDripFirst() -> ByteBuffer { ByteBuffer(string: "HELLO") }
func fixtureDripRest() -> ByteBuffer { ByteBuffer(string: "WORLD") }

func fixtureMultipartPauseParts() -> (first: ByteBuffer, rest: ByteBuffer) {
    let first = Data("--pause-boundary\r\nContent-Disposition: form-data; name=\"one\"\r\n\r\nfirst\r\n--pause-boundary\r\n".utf8)
    let rest = Data("Content-Disposition: form-data; name=\"two\"\r\n\r\nsecond\r\n--pause-boundary--\r\n".utf8)
    return (ByteBuffer(bytes: first), ByteBuffer(bytes: rest))
}

/// HTTP/1 and HTTP/2 server handler. Both pipelines deliver `HTTPServerRequestPart`.
final class FixtureHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let gates: FixtureGates
    private var method = ""
    private var uri = ""
    private var version = ""
    private var headers: [(String, String)] = []
    private var body = ByteBuffer()
    private var sawHead = false
    private var signaledUpload = false
    private var rejected = false
    private var expectAccept = false

    init(gates: FixtureGates) {
        self.gates = gates
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
            let path = fixturePath(uri)
            if path == "/hold" {
                let hold = gates.hold
                Task { await hold.signal() }
            }
            if path == "/expect-reject" {
                rejected = true
                write(
                    FixtureResponse(
                        informational: false,
                        status: 403,
                        headers: [("x-server", "fixture"), ("content-length", "0")],
                        body: nil,
                        trailers: []
                    ),
                    context: context
                )
            }
            if path == "/expect-accept" {
                expectAccept = true
                let interim = HTTPResponseHead(
                    version: .http1_1,
                    status: .custom(code: 100, reasonPhrase: "Continue")
                )
                context.writeAndFlush(Self.wrapOutboundOut(.head(interim)), promise: nil)
            }
        case .body(var buffer):
            if rejected {
                return
            }
            if fixturePath(uri) == "/upload-gate", !signaledUpload {
                signaledUpload = true
                let upload = gates.upload
                Task { await upload.signal() }
            }
            body.writeBuffer(&buffer)
        case .end:
            guard sawHead, !rejected else {
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
            switch plan {
            case .hold:
                return
            case .response(let response):
                write(response, context: context)
            case .drip:
                writeDrip(context: context)
            case .multipartPause:
                writeMultipartPause(context: context)
            }
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

    private func writeDrip(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "x-server", value: "fixture")
        headers.add(name: "content-type", value: "application/octet-stream")
        headers.add(name: "content-length", value: "10")
        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(Self.wrapOutboundOut(.head(head)), promise: nil)
        context.write(Self.wrapOutboundOut(.body(.byteBuffer(fixtureDripFirst()))), promise: nil)
        context.flush()
        let loop = context.eventLoop
        let channel = context.channel
        Task {
            await gates.drip.signal()
            await gates.dripRelease.wait()
            loop.execute {
                channel.write(HTTPServerResponsePart.body(.byteBuffer(fixtureDripRest())), promise: nil)
                channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
            }
        }
    }

    private func writeMultipartPause(context: ChannelHandlerContext) {
        let parts = fixtureMultipartPauseParts()
        let total = parts.first.readableBytes + parts.rest.readableBytes
        var headers = HTTPHeaders()
        headers.add(name: "x-server", value: "fixture")
        headers.add(name: "content-type", value: "multipart/form-data; boundary=pause-boundary")
        headers.add(name: "content-length", value: String(total))
        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(Self.wrapOutboundOut(.head(head)), promise: nil)
        context.write(Self.wrapOutboundOut(.body(.byteBuffer(parts.first))), promise: nil)
        context.flush()
        let loop = context.eventLoop
        let channel = context.channel
        let rest = parts.rest
        Task {
            await gates.multipart.signal()
            await gates.multipartRelease.wait()
            loop.execute {
                channel.write(HTTPServerResponsePart.body(.byteBuffer(rest)), promise: nil)
                channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
            }
        }
    }
}
