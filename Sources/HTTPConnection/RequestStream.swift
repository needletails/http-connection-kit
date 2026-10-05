//
//  RequestStream.swift
//  HTTPConnectionKit
//
//  Created by NeedleTails on 10/5/26.
//

import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOHTTPCompression

/// Holds the HTTP/2 stream channel created inside the multiplexer initializer.
///
/// The initializer runs on the stream event loop. The connection event loop reads it only after
/// that initializer has finished.
final class PreparedHTTP1Request: @unchecked Sendable {
    var channel: NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>?
}

final class HTTP1RequestBox: @unchecked Sendable {
    let request: NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>

    init(_ request: NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>) {
        self.request = request
    }
}

extension HTTPConnection {
    /// Wraps the HTTP/1 connection as the single request channel.
    ///
    /// Closing this channel closes the connection. Half-closure lets the request finish while the
    /// response is still being read.
    static func openHTTP1Request(
        on connection: Channel,
        cancelTarget: CancelTarget
    ) async throws -> NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart> {
        try await connection.eventLoop.flatSubmit {
            connection.eventLoop.makeCompletedFuture {
                let request = try NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>(
                    wrappingChannelSynchronously: connection,
                    configuration: .init(isOutboundHalfClosureEnabled: true)
                )
                cancelTarget.set(request.channel)
                return request
            }
        }.get()
    }

    /// Opens one HTTP/2 stream and wraps it as an HTTP/1 request channel.
    ///
    /// The stream is wrapped inside the multiplexer initializer so the first bytes are not missed.
    /// Cancelling the request closes the stream and leaves the connection in the pool.
    static func openHTTP2Request(
        on connection: Channel,
        enableTLS: Bool,
        cancelTarget: CancelTarget,
        decompressionLimit: NIOHTTPDecompression.DecompressionLimit? = nil
    ) async throws -> NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart> {
        let httpProtocol: HTTP2FramePayloadToHTTP1ClientCodec.HTTPProtocol = enableTLS ? .https : .http
        let prepared = PreparedHTTP1Request()
        return try await connection.eventLoop.flatSubmit {
            let opened: EventLoopFuture<NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>>
            do {
                let handler = try connection.pipeline.syncOperations.handler(type: NIOHTTP2Handler.self)
                let multiplexer = try handler.syncMultiplexer()
                let channelPromise = connection.eventLoop.makePromise(of: Channel.self)
                multiplexer.createStreamChannel(promise: channelPromise) { stream in
                    stream.eventLoop.makeCompletedFuture {
                        try stream.pipeline.syncOperations.addHandler(
                            HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: httpProtocol)
                        )
                        if let decompressionLimit {
                            try stream.pipeline.syncOperations.addHandler(
                                NIOHTTPResponseDecompressor(limit: decompressionLimit)
                            )
                        }
                        prepared.channel = try NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>(
                            wrappingChannelSynchronously: stream,
                            configuration: .init(isOutboundHalfClosureEnabled: true)
                        )
                        if let channel = prepared.channel {
                            cancelTarget.set(channel.channel)
                        }
                    }
                }
                opened = channelPromise.futureResult.flatMapThrowing { _ in
                    guard let channel = prepared.channel else {
                        throw HTTPConnectionError.invalidRequest
                    }
                    return channel
                }
            } catch {
                opened = connection.eventLoop.makeFailedFuture(error)
            }
            return opened
        }.get()
    }
}
