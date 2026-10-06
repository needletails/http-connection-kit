//
//  HTTP3Transport.swift
//  HTTPConnectionKit
//
//  Created by NeedleTails on 10/5/26.
//

import Foundation
import Logging
import NIOCore
import NIOHTTPTypes
@_spi(PackageInternal) import NIOHTTP3
import NIOQUIC
#if os(Android)
import X509
#endif

/// NIOTS connected datagrams are `ByteBuffer`. QUIC reads and writes `AddressedEnvelope`.
///
/// The remote address is read when a datagram arrives. A connected socket cannot migrate, so this
/// adapter does not forward preferred-address or connection-migration packets.
final class ConnectedDatagramEnvelopeAdapter: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = AddressedEnvelope<ByteBuffer>
    typealias OutboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard let remoteAddress = context.channel.remoteAddress else {
            context.fireErrorCaught(HTTPConnectionError.invalidRequest)
            return
        }
        let buffer = Self.unwrapInboundIn(data)
        context.fireChannelRead(Self.wrapInboundOut(AddressedEnvelope(remoteAddress: remoteAddress, data: buffer)))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let envelope = Self.unwrapOutboundIn(data)
        context.write(Self.wrapOutboundOut(envelope.data), promise: promise)
    }
}

@available(anyAppleOS 26, *)
final class HTTP3RequestBox: @unchecked Sendable {
    let request: NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>

    init(_ request: NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>) {
        self.request = request
    }
}

@available(anyAppleOS 26, *)
extension HTTPConnection {
    /// Places QUIC on a datagram channel. TLS is performed by QUIC, not by a separate TLS handler.
    static func installQUICHandler(
        on channel: Channel,
        connectedDatagramBytes: Bool,
        tls: Configuration.TLS,
        quicIdleTimeout: Configuration.Interval
    ) throws {
        if connectedDatagramBytes {
            try channel.pipeline.syncOperations.addHandler(ConnectedDatagramEnvelopeAdapter())
        }
        let peerVerification = tls.certificateVerification.quic
        let verifier = try Self.makeVerifier(peerVerification: peerVerification, eventLoop: channel.eventLoop)
        let configuration = QUICConfiguration.client(
            verificationConfiguration: .x509Certificates(trustRootsFilePath: nil),
            applicationProtocols: ["h3"],
            maxIdleTimeout: .nanoseconds(quicIdleTimeout.nanoseconds),
            initialMaxData: 16_777_216,
            initialMaxStreamDataBidiLocal: 1_048_576,
            initialMaxStreamDataBidiRemote: 1_048_576,
            initialMaxStreamDataUni: 1_048_576,
            initialMaxStreamsBidi: 100,
            initialMaxStreamsUni: 8,
            peerCertificateVerification: peerVerification
        )
        let quicHandler = QUICHandler(
            channel: channel,
            quicConfiguration: configuration,
            asyncVerifier: verifier,
            authenticator: nil,
            logger: Logger(label: "http-connection-kit.quic"),
            inboundConnectionInitializer: { connection, _ in
                connection.eventLoop.makeSucceededVoidFuture()
            },
            inboundStreamInitializer: { stream in
                stream.close()
            },
            noMoreConnections: {}
        )
        try channel.pipeline.syncOperations.addHandler(quicHandler)
    }

    /// Builds the QUIC certificate verifier.
    ///
    /// SwiftCertificates looks for a PEM bundle under `/etc/ssl`. Android ships its trust anchors as
    /// one PEM file per CA in a directory, which is the store NIOSSL already uses for TCP.
    static func makeVerifier(
        peerVerification: NIOQUIC.CertificateVerification,
        eventLoop: any EventLoop
    ) throws -> AsyncVerifier {
        #if os(Android)
        if !AndroidSystemTrustRoots.certificates.isEmpty,
           let verifier = try? AsyncVerifier(
               trustRoots: AndroidSystemTrustRoots.certificates,
               certificateVerification: peerVerification,
               eventLoop: eventLoop
           )
        {
            return verifier
        }
        #endif
        return AsyncVerifier(certificateVerification: peerVerification, eventLoop: eventLoop)
    }

    /// Opens one HTTP/3 request stream.
    ///
    /// The stream is wrapped inside `createRequestStream` so its first bytes are not missed.
    /// Cancelling the request closes the stream and leaves the QUIC connection in the pool.
    static func openHTTP3Request(
        on connection: Channel,
        cancelTarget: CancelTarget
    ) async throws -> NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart> {
        try await connection.eventLoop.flatSubmit {
            let request: EventLoopFuture<NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>>
            do {
                let handler = try connection.pipeline.syncOperations.handler(
                    type: HTTP3ConnectionHandler<QUICStreamCreator>.self
                )
                request = handler.createRequestStream { parameters in
                    parameters.channel.eventLoop.makeCompletedFuture {
                        let stream = try NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>(
                            wrappingChannelSynchronously: parameters.channel,
                            configuration: .init(isOutboundHalfClosureEnabled: true)
                        )
                        cancelTarget.set(stream.channel)
                        return stream
                    }
                }
            } catch {
                request = connection.eventLoop.makeFailedFuture(error)
            }
            return request
        }.get()
    }

    /// Completes the QUIC handshake and returns the HTTP/3 connection channel, not the UDP socket.
    ///
    /// `QUICHandler` cannot be read off the event loop: its `Sendable` conformance is unavailable.
    /// The lookup and `createOutboundConnection` stay inside `flatSubmit`.
    static func openHTTP3Connection(on udp: Channel, serverHostname: String) async throws -> Channel {
        guard let remoteAddress = udp.remoteAddress else {
            throw HTTPConnectionError.invalidRequest
        }
        let opened = udp.eventLoop.flatSubmit { () -> EventLoopFuture<(any Channel, QUICStreamCreator)> in
            do {
                let quicHandler = try udp.pipeline.syncOperations.handler(
                    type: QUICHandler<QUICStreamChannels>.self
                )
                return quicHandler.createOutboundConnection(
                    serverName: serverHostname,
                    remoteAddress: remoteAddress,
                    connectionInitializer: { connectionChannel, streamCreator in
                        connectionChannel.eventLoop.makeCompletedFuture {
                            let handler = HTTP3ConnectionHandler<QUICStreamCreator>.client(
                                eventLoop: connectionChannel.eventLoop,
                                configuration: .defaults,
                                settings: .init(maximumFieldSectionSize: 80 * 1024),
                                streamCreator: streamCreator,
                                logger: Logger(label: "http-connection-kit.http3"),
                                inboundPushStreamInitializer: { parameters in
                                    parameters.channel.close()
                                }
                            )
                            try connectionChannel.pipeline.syncOperations.addHandler(handler)
                        }
                    },
                    inboundStreamInitializer: { streamChannel in
                        streamChannel.parent?.pipeline.handler(type: HTTP3ConnectionHandler<QUICStreamCreator>.self)
                            .flatMap { handler in
                                handler.inboundStreamReceived(streamChannel)
                            } ?? streamChannel.eventLoop.makeFailedFuture(HTTPConnectionError.invalidRequest)
                    }
                )
            } catch {
                return udp.eventLoop.makeFailedFuture(error)
            }
        }
        return try await Self.resolveChannel(opened.map { $0.0 })
    }
}

#if os(Android)
/// Trust anchors from Android's system CA directory.
///
/// `CertificateStore.systemTrustRoots` only reads a single PEM bundle under `/etc/ssl`. One
/// unreadable file must not drop the rest, and a failure to load them must not stop QUIC from opening.
enum AndroidSystemTrustRoots {
    static let certificates: [Certificate] = load()

    private static func load() -> [Certificate] {
        let directories = [
            "/apex/com.android.conscrypt/cacerts",
            "/system/etc/security/cacerts",
        ]
        let fileManager = FileManager.default
        guard let directory = directories.first(where: { fileManager.fileExists(atPath: $0) }),
              let names = try? fileManager.contentsOfDirectory(atPath: directory)
        else {
            return []
        }
        var certificates: [Certificate] = []
        for name in names {
            let path = directory + "/" + name
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let start = text.range(of: "-----BEGIN CERTIFICATE-----"),
                  let end = text.range(of: "-----END CERTIFICATE-----"),
                  start.lowerBound < end.lowerBound
            else {
                continue
            }
            let block = String(text[start.lowerBound..<end.upperBound])
            if let certificate = try? Certificate(pemEncoded: block) {
                certificates.append(certificate)
            }
        }
        return certificates
    }
}
#endif
