//
//  HTTPExchange.swift
//  HTTPConnectionKit
//

import Foundation
import HTTPTypes
import NIOCore
import NIOHTTP1
import NIOHTTPTypes

struct ExchangeContext: Sendable {
    var method: HTTPRequest.Method
    var components: RequestComponents
    var headers: HTTPFields
    var body: HTTPBody?
    var requestVersion: HTTPVersion
    var expectContinueTimeout: HTTPConnection.Configuration.Interval
    var onProgress: (@Sendable (HTTPProgress) -> Void)?
    var usesHTTP1Chunked: Bool
}

actor InboundMailbox<Part: Sendable> {
    private var queued: [Part] = []
    private var consumer: CheckedContinuation<Part?, Error>?
    private var producer: CheckedContinuation<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false
    private var failure: Error?
    private var generation = 0

    func yield(_ part: Part) async {
        if finished || failure != nil {
            return
        }
        if let consumer {
            cancelTimeout()
            generation += 1
            self.consumer = nil
            consumer.resume(returning: part)
            return
        }
        queued.append(part)
        await withCheckedContinuation { continuation in
            if finished || failure != nil {
                continuation.resume()
                return
            }
            producer = continuation
        }
    }

    func finish() {
        cancelTimeout()
        finished = true
        generation += 1
        consumer?.resume(returning: nil)
        consumer = nil
        producer?.resume()
        producer = nil
    }

    func fail(_ error: Error) {
        cancelTimeout()
        if failure == nil {
            failure = error
        }
        generation += 1
        consumer?.resume(throwing: error)
        consumer = nil
        producer?.resume()
        producer = nil
    }

    func next(timeoutNanoseconds: UInt64? = nil) async throws -> Part? {
        if let failure {
            throw failure
        }
        if !queued.isEmpty {
            let part = queued.removeFirst()
            producer?.resume()
            producer = nil
            return part
        }
        if finished {
            return nil
        }
        generation += 1
        let captured = generation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                consumer = continuation
                guard let timeoutNanoseconds else {
                    return
                }
                timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: max(timeoutNanoseconds, 1))
                    } catch {
                        return
                    }
                    self.expire(generation: captured)
                }
            }
        } onCancel: {
            Task { await self.cancelWait(generation: captured) }
        }
    }

    private func cancelTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func cancelWait(generation captured: Int) {
        guard generation == captured, consumer != nil else {
            return
        }
        fail(CancellationError())
    }

    private func expire(generation captured: Int) {
        timeoutTask = nil
        guard self.generation == captured, let consumer else {
            return
        }
        generation += 1
        self.consumer = nil
        consumer.resume(returning: nil)
    }
}

extension HTTPConnection {
    static func writeHTTP1Request(
        _ context: ExchangeContext,
        outbound: NIOAsyncChannelOutboundWriter<HTTPClientRequestPart>
    ) async throws {
        let headers = http1Headers(
            components: context.components,
            headers: context.headers,
            length: context.body?.length,
            chunkUnknown: context.usesHTTP1Chunked
        )
        let head = HTTPRequestHead(
            version: context.requestVersion,
            method: HTTPMethod(rawValue: context.method.rawValue),
            uri: context.components.path,
            headers: headers
        )
        try await outbound.write(.head(head))
        try await writeBody(context.body, outbound: outbound, progress: context.onProgress)
        try await outbound.write(.end(nil))
    }

    static func http3Request(_ context: ExchangeContext) -> HTTPRequest {
        HTTPRequest(
            method: context.method,
            scheme: context.components.scheme,
            authority: context.components.authority,
            path: context.components.path,
            headerFields: http3Fields(headers: context.headers, length: context.body?.length)
        )
    }

    static func writeHTTP3Request(
        _ context: ExchangeContext,
        outbound: NIOAsyncChannelOutboundWriter<HTTPRequestPart>
    ) async throws {
        try await outbound.write(.head(http3Request(context)))
        try await writeHTTP3Body(context.body, outbound: outbound, progress: context.onProgress)
        try await outbound.write(.end(nil))
    }

    /// Writes a bodyless HTTP/3 request and its FIN in one turn on the stream's event loop.
    ///
    /// The HEADERS bytes stay in the QUIC buffer until the FIN is attached, so the server receives
    /// one complete STREAM frame.
    static func writeEmptyHTTP3Request(
        on channel: Channel,
        context: ExchangeContext
    ) async throws {
        let head = HTTPRequestPart.head(http3Request(context))
        try await channel.eventLoop.flatSubmit { () -> EventLoopFuture<Void> in
            let promise = channel.eventLoop.makePromise(of: Void.self)
            channel.write(head, promise: nil)
            channel.write(HTTPRequestPart.end(nil), promise: promise)
            channel.flush()
            return promise.futureResult
        }.get()
    }

    private static func writeBody(
        _ body: HTTPBody?,
        outbound: NIOAsyncChannelOutboundWriter<HTTPClientRequestPart>,
        progress: (@Sendable (HTTPProgress) -> Void)?
    ) async throws {
        guard let body else { return }
        var completed: Int64 = 0
        for try await chunk in body {
            guard !chunk.isEmpty else { continue }
            try await outbound.write(.body(.byteBuffer(byteBuffer(chunk))))
            completed += Int64(chunk.count)
            progress?(HTTPProgress(direction: .upload, completed: completed, expected: body.length))
        }
    }

    private static func writeHTTP3Body(
        _ body: HTTPBody?,
        outbound: NIOAsyncChannelOutboundWriter<HTTPRequestPart>,
        progress: (@Sendable (HTTPProgress) -> Void)?
    ) async throws {
        guard let body else { return }
        var completed: Int64 = 0
        for try await chunk in body {
            guard !chunk.isEmpty else { continue }
            try await outbound.write(.body(byteBuffer(chunk)))
            completed += Int64(chunk.count)
            progress?(HTTPProgress(direction: .upload, completed: completed, expected: body.length))
        }
    }

    static func collectHTTP1(
        inboundNext: () async throws -> HTTPClientResponsePart?,
        firstHead: HTTPResponseHead?,
        progress: (@Sendable (HTTPProgress) -> Void)?,
        expected: Int64?,
        maximumBodySize: Int
    ) async throws -> Response {
        var responseHead = firstHead
        var payload = ByteBuffer()
        var completed: Int64 = 0
        while let part = try await inboundNext() {
            switch part {
            case .head(let received):
                guard !isInformational(received.status.code) else { continue }
                responseHead = received
                payload.clear()
                completed = 0
            case .body(var buffer):
                guard responseHead != nil else { continue }
                let count = buffer.readableBytes
                guard count <= maximumBodySize - payload.readableBytes else {
                    throw HTTPConnectionError.responseTooLarge
                }
                payload.writeBuffer(&buffer)
                completed += Int64(count)
                progress?(HTTPProgress(direction: .download, completed: completed, expected: expected ?? contentLength(responseHead)))
            case .end(let trailers):
                guard let responseHead else { continue }
                return try response(head: responseHead, trailers: trailers, payload: payload)
            }
        }
        throw HTTPConnectionError.invalidRequest
    }

    static func collectHTTP3(
        inbound: NIOAsyncChannelInboundStream<HTTPResponsePart>,
        progress: (@Sendable (HTTPProgress) -> Void)?,
        maximumBodySize: Int
    ) async throws -> Response {
        var responseHead: HTTPResponse?
        var payload = ByteBuffer()
        var completed: Int64 = 0
        for try await part in inbound {
            switch part {
            case .head(let received):
                guard !isInformational(UInt(received.status.code)) else { continue }
                responseHead = received
                payload.clear()
                completed = 0
            case .body(var buffer):
                guard responseHead != nil else { continue }
                let count = buffer.readableBytes
                guard count <= maximumBodySize - payload.readableBytes else {
                    throw HTTPConnectionError.responseTooLarge
                }
                payload.writeBuffer(&buffer)
                completed += Int64(count)
                progress?(HTTPProgress(
                    direction: .download,
                    completed: completed,
                    expected: contentLength(responseHead)
                ))
            case .end(let trailers):
                guard var responseHead else { continue }
                if let trailers {
                    responseHead.headerFields.append(contentsOf: trailers)
                }
                let data = payload.readableBytes == 0 ? nil : Data(payload.readableBytesView)
                return Response(head: responseHead, body: data)
            }
        }
        throw HTTPConnectionError.invalidRequest
    }

    static func http1Headers(
        components: RequestComponents,
        headers: HTTPFields,
        length: Int64?,
        chunkUnknown: Bool
    ) -> HTTPHeaders {
        var nioHeaders = HTTPHeaders()
        nioHeaders.reserveCapacity(headers.count + 3)
        var sawHost = false
        var sawContentLength = false
        var sawTransferEncoding = false
        for field in headers {
            if field.name.canonicalName == "host" {
                sawHost = true
            } else if field.name == .contentLength {
                sawContentLength = true
            } else if field.name == .transferEncoding {
                sawTransferEncoding = true
            }
            nioHeaders.add(name: field.name.rawName, value: field.value)
        }
        if !sawHost {
            nioHeaders.add(name: "host", value: components.authority)
        }
        if let length, !sawContentLength {
            nioHeaders.add(name: "content-length", value: String(length))
        } else if chunkUnknown, length == nil, !sawContentLength, !sawTransferEncoding {
            nioHeaders.add(name: "transfer-encoding", value: "chunked")
        }
        return nioHeaders
    }

    static func http3Fields(headers: HTTPFields, length: Int64?) -> HTTPFields {
        var fields = HTTPFields()
        fields.reserveCapacity(headers.count + 1)
        for field in headers where field.name.canonicalName != "host" {
            fields.append(field)
        }
        if let length, fields[.contentLength] == nil {
            fields[.contentLength] = String(length)
        }
        return fields
    }

    static func writeHTTP1Body(
        _ body: HTTPBody?,
        outbound: NIOAsyncChannelOutboundWriter<HTTPClientRequestPart>,
        progress: (@Sendable (HTTPProgress) -> Void)?
    ) async throws {
        try await writeBody(body, outbound: outbound, progress: progress)
    }

    static func byteBuffer(_ body: Data) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: body.count)
        buffer.writeBytes(body)
        return buffer
    }

    static func isInformational(_ code: UInt) -> Bool {
        (100..<200).contains(code)
    }

    static func contentLength(_ head: HTTPResponseHead?) -> Int64? {
        guard let value = head?.headers["content-length"].first, let length = Int64(value) else {
            return nil
        }
        return length
    }

    static func contentLength(_ head: HTTPResponse?) -> Int64? {
        guard let value = head?.headerFields[.contentLength], let length = Int64(value) else {
            return nil
        }
        return length
    }

    static func expectedDownload(_ head: HTTPResponse) -> Int64? {
        if let range = head.headerFields[.contentRange],
           let slash = range.lastIndex(of: "/"),
           let total = Int64(range[range.index(after: slash)...]),
           total >= 0
        {
            return total
        }
        if let length = head.headerFields[.contentLength], let value = Int64(length) {
            return value
        }
        return nil
    }

    static func response(head: HTTPResponseHead, trailers: HTTPHeaders?, payload: ByteBuffer) throws -> Response {
        try Response(head: httpResponse(head: head, trailers: trailers), body: payload.readableBytes == 0 ? nil : Data(payload.readableBytesView))
    }

    static func httpResponse(head: HTTPResponseHead, trailers: HTTPHeaders? = nil) throws -> HTTPResponse {
        guard head.status.code <= 999 else {
            throw HTTPConnectionError.invalidRequest
        }
        var fields = HTTPFields()
        fields.reserveCapacity(head.headers.count + (trailers?.count ?? 0))
        for header in head.headers {
            guard let name = HTTPField.Name(header.name) else { continue }
            fields.append(HTTPField(name: name, value: header.value))
        }
        if let trailers {
            for trailer in trailers {
                guard let name = HTTPField.Name(trailer.name) else { continue }
                fields.append(HTTPField(name: name, value: trailer.value))
            }
        }
        let status = HTTPResponse.Status(code: Int(head.status.code), reasonPhrase: head.status.reasonPhrase)
        return HTTPResponse(status: status, headerFields: fields)
    }
}
