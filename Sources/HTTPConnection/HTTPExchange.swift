//
//  HTTPExchange.swift
//  HTTPConnectionKit
//
//  Created by NeedleTails on 10/5/26.
//

import Foundation
import HTTPTypes
import NIOCore
import NIOHTTP1
import NIOHTTPTypes

extension HTTPConnection {
    /// Writes one HTTP/1 or HTTP/2 request and collects the final response.
    ///
    /// HTTP/2 uses the same parts after `HTTP2FramePayloadToHTTP1ClientCodec`. Informational
    /// `1xx` responses are skipped. The request-line version is HTTP/1.1 on an HTTP/2 stream.
    static func exchangeHTTP1(
        method: HTTPRequest.Method,
        components: RequestComponents,
        headers: HTTPFields,
        body: Data?,
        requestVersion: HTTPVersion,
        inbound: NIOAsyncChannelInboundStream<HTTPClientResponsePart>,
        outbound: NIOAsyncChannelOutboundWriter<HTTPClientRequestPart>
    ) async throws -> Response {
        let head = HTTPRequestHead(
            version: requestVersion,
            method: HTTPMethod(rawValue: method.rawValue),
            uri: components.path,
            headers: http1Headers(components: components, headers: headers, body: body)
        )
        try await outbound.write(.head(head))
        if let body, !body.isEmpty {
            try await outbound.write(.body(.byteBuffer(byteBuffer(body))))
        }
        try await outbound.write(.end(nil))

        var responseHead: HTTPResponseHead?
        var payload = ByteBuffer()
        for try await part in inbound {
            switch part {
            case .head(let received):
                guard !isInformational(received.status.code) else {
                    continue
                }
                responseHead = received
                payload.clear()
            case .body(var buffer):
                guard responseHead != nil else {
                    continue
                }
                payload.writeBuffer(&buffer)
            case .end(let trailers):
                guard let responseHead else {
                    continue
                }
                return try response(head: responseHead, trailers: trailers, payload: payload)
            }
        }
        throw HTTPConnectionError.invalidRequest
    }

    /// Writes one HTTP/3 request and collects the final response.
    ///
    /// `:authority` carries the host. A caller-supplied `Host` field is omitted because HTTP/3
    /// rejects it as a regular header.
    static func exchangeHTTP3(
        method: HTTPRequest.Method,
        components: RequestComponents,
        headers: HTTPFields,
        body: Data?,
        inbound: NIOAsyncChannelInboundStream<HTTPResponsePart>,
        outbound: NIOAsyncChannelOutboundWriter<HTTPRequestPart>
    ) async throws -> Response {
        let request = HTTPRequest(
            method: method,
            scheme: components.scheme,
            authority: components.authority,
            path: components.path,
            headerFields: http3Fields(headers: headers, body: body)
        )
        try await outbound.write(.head(request))
        if let body, !body.isEmpty {
            try await outbound.write(.body(byteBuffer(body)))
        }
        try await outbound.write(.end(nil))

        var responseHead: HTTPResponse?
        var payload = ByteBuffer()
        for try await part in inbound {
            switch part {
            case .head(let received):
                guard !isInformational(UInt(received.status.code)) else {
                    continue
                }
                responseHead = received
                payload.clear()
            case .body(var buffer):
                guard responseHead != nil else {
                    continue
                }
                payload.writeBuffer(&buffer)
            case .end(let trailers):
                guard var responseHead else {
                    continue
                }
                if let trailers {
                    responseHead.headerFields.append(contentsOf: trailers)
                }
                let data = payload.readableBytes == 0 ? nil : Data(payload.readableBytesView)
                return Response(head: responseHead, body: data)
            }
        }
        throw HTTPConnectionError.invalidRequest
    }

    /// HTTP/1 and HTTP/2 headers. Adds `Host` and `Content-Length` when the caller did not.
    private static func http1Headers(components: RequestComponents, headers: HTTPFields, body: Data?) -> HTTPHeaders {
        var nioHeaders = HTTPHeaders()
        nioHeaders.reserveCapacity(headers.count + 2)
        var sawHost = false
        var sawContentLength = false
        for field in headers {
            if field.name.canonicalName == "host" {
                sawHost = true
            } else if field.name == .contentLength {
                sawContentLength = true
            }
            nioHeaders.add(name: field.name.rawName, value: field.value)
        }
        if !sawHost {
            nioHeaders.add(name: "host", value: components.authority)
        }
        if let body, !sawContentLength {
            nioHeaders.add(name: "content-length", value: String(body.count))
        }
        return nioHeaders
    }

    /// HTTP/3 header fields. `Host` is dropped because `:authority` already names the origin.
    private static func http3Fields(headers: HTTPFields, body: Data?) -> HTTPFields {
        var fields = HTTPFields()
        fields.reserveCapacity(headers.count + 1)
        for field in headers where field.name.canonicalName != "host" {
            fields.append(field)
        }
        if let body, fields[.contentLength] == nil {
            fields[.contentLength] = String(body.count)
        }
        return fields
    }

    private static func byteBuffer(_ body: Data) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: body.count)
        buffer.writeBytes(body)
        return buffer
    }

    private static func isInformational(_ code: UInt) -> Bool {
        (100..<200).contains(code)
    }

    /// Turns an HTTP/1 response head, optional trailers, and body into the public response.
    private static func response(head: HTTPResponseHead, trailers: HTTPHeaders?, payload: ByteBuffer) throws -> Response {
        guard head.status.code <= 999 else {
            throw HTTPConnectionError.invalidRequest
        }
        var fields = HTTPFields()
        fields.reserveCapacity(head.headers.count + (trailers?.count ?? 0))
        for header in head.headers {
            guard let name = HTTPField.Name(header.name) else {
                continue
            }
            fields.append(HTTPField(name: name, value: header.value))
        }
        if let trailers {
            for trailer in trailers {
                guard let name = HTTPField.Name(trailer.name) else {
                    continue
                }
                fields.append(HTTPField(name: name, value: trailer.value))
            }
        }
        let status = HTTPResponse.Status(code: Int(head.status.code), reasonPhrase: head.status.reasonPhrase)
        let body = payload.readableBytes == 0 ? nil : Data(payload.readableBytesView)
        return Response(head: HTTPResponse(status: status, headerFields: fields), body: body)
    }
}
