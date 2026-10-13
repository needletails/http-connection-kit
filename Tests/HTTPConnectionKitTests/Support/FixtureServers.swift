//
//  FixtureServers.swift
//  HTTPConnectionKit
//
//  Created by NeedleTails on 10/5/26.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOPosix
import NIOSSL

/// Cleartext HTTP/1.1 server on 127.0.0.1.
final class HTTP1FixtureServer {
    let port: Int
    let accepts: AcceptCounter
    let gates: FixtureGates
    private let channel: any Channel

    var hold: HoldGate { gates.hold }

    static func bind() async throws -> HTTP1FixtureServer {
        let accepts = AcceptCounter()
        let gates = FixtureGates()
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.tcpOption(.tcp_nodelay), value: 1)
            .childChannelOption(.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    accepts.increment()
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(FixtureHTTPHandler(gates: gates))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return try HTTP1FixtureServer(channel: channel, accepts: accepts, gates: gates)
    }

    private init(channel: any Channel, accepts: AcceptCounter, gates: FixtureGates) throws {
        guard let port = channel.localAddress?.port else {
            throw FixtureServerError.missingPort
        }
        self.channel = channel
        self.port = port
        self.accepts = accepts
        self.gates = gates
    }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    func stop() async {
        try? await channel.close().get()
    }
}

/// The HTTP/2 connection channels a fixture server has accepted.
final class HTTP2ConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [any Channel] = []

    func add(_ channel: any Channel) {
        lock.lock()
        channels.append(channel)
        lock.unlock()
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.remove(channel)
        }
    }

    private func remove(_ channel: any Channel) {
        lock.lock()
        channels.removeAll { $0 === channel }
        lock.unlock()
    }

    var active: [any Channel] {
        lock.lock()
        defer { lock.unlock() }
        return channels
    }
}

/// Completes a promise when the peer acknowledges a PING sent after a GOAWAY.
///
/// Frames on one connection are processed in order, so the ack proves the client has handled
/// every frame written before the PING.
final class PingAckObserver: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame
    typealias InboundOut = HTTP2Frame

    private var pending: [EventLoopPromise<Void>] = []

    func register(_ promise: EventLoopPromise<Void>) {
        pending.append(promise)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        if frame.streamID == .rootStream, case .ping(_, ack: true) = frame.payload {
            let acked = pending
            pending.removeAll()
            for promise in acked {
                promise.succeed(())
            }
        }
        context.fireChannelRead(data)
    }
}

/// HTTPS server that speaks only HTTP/1.1 or only HTTP/2.
final class TLSFixtureServer {
    enum Mode: Sendable {
        case http1
        case http2
    }

    let port: Int
    let accepts: AcceptCounter
    let gates: FixtureGates
    let http2Connections: HTTP2ConnectionRegistry
    private let channel: any Channel

    var hold: HoldGate { gates.hold }

    /// Sends GOAWAY on every open HTTP/2 connection and returns once each client has processed it.
    func sendGoAway() async throws {
        for connection in http2Connections.active {
            try await connection.eventLoop.flatSubmit { () -> EventLoopFuture<Void> in
                do {
                    let observer = try connection.pipeline.syncOperations.handler(type: PingAckObserver.self)
                    let promise = connection.eventLoop.makePromise(of: Void.self)
                    observer.register(promise)
                    connection.write(
                        HTTP2Frame(
                            streamID: .rootStream,
                            payload: .goAway(lastStreamID: .maxID, errorCode: .noError, opaqueData: nil)
                        ),
                        promise: nil
                    )
                    connection.writeAndFlush(
                        HTTP2Frame(streamID: .rootStream, payload: .ping(HTTP2PingData(withInteger: 1), ack: false)),
                        promise: nil
                    )
                    return promise.futureResult
                } catch {
                    return connection.eventLoop.makeFailedFuture(error)
                }
            }.get()
        }
    }

    static func bind(
        _ mode: Mode,
        requireClientCertificate: Bool = false,
        maxConcurrentStreams: Int? = nil
    ) async throws -> TLSFixtureServer {
        let material = LocalTLSMaterial.shared
        var tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: material.certificateChain.map { .certificate($0) },
            privateKey: .privateKey(material.privateKey)
        )
        tls.minimumTLSVersion = .tlsv12
        tls.applicationProtocols = mode == .http2 ? ["h2"] : ["http/1.1"]
        if requireClientCertificate {
            tls.trustRoots = .certificates(material.trustRoots)
            tls.certificateVerification = .noHostnameVerification
        }
        let context = try NIOSSLContext(configuration: tls)
        let accepts = AcceptCounter()
        let gates = FixtureGates()
        let registry = HTTP2ConnectionRegistry()

        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.tcpOption(.tcp_nodelay), value: 1)
            .childChannelOption(.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    accepts.increment()
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
                    switch mode {
                    case .http1:
                        try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                        try channel.pipeline.syncOperations.addHandler(FixtureHTTPHandler(gates: gates))
                    case .http2:
                        var connection = NIOHTTP2Handler.ConnectionConfiguration()
                        connection.targetWindowSize = 1_048_576
                        if let maxConcurrentStreams {
                            connection.initialSettings = [
                                HTTP2Setting(parameter: .maxConcurrentStreams, value: maxConcurrentStreams),
                                HTTP2Setting(parameter: .maxHeaderListSize, value: 80 * 1024),
                            ]
                        }
                        var stream = NIOHTTP2Handler.StreamConfiguration()
                        stream.targetWindowSize = 1_048_576
                        _ = try channel.pipeline.syncOperations.configureHTTP2Pipeline(
                            mode: .server,
                            connectionConfiguration: connection,
                            streamConfiguration: stream,
                            inboundStreamInitializer: { streamChannel in
                                streamChannel.eventLoop.makeCompletedFuture {
                                    try streamChannel.pipeline.syncOperations.addHandler(
                                        HTTP2FramePayloadToHTTP1ServerCodec()
                                    )
                                    try streamChannel.pipeline.syncOperations.addHandler(
                                        FixtureHTTPHandler(gates: gates)
                                    )
                                }
                            }
                        )
                        try channel.pipeline.syncOperations.addHandler(PingAckObserver())
                        registry.add(channel)
                    }
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return try TLSFixtureServer(channel: channel, accepts: accepts, gates: gates, registry: registry)
    }

    private init(
        channel: any Channel,
        accepts: AcceptCounter,
        gates: FixtureGates,
        registry: HTTP2ConnectionRegistry
    ) throws {
        guard let port = channel.localAddress?.port else {
            throw FixtureServerError.missingPort
        }
        self.channel = channel
        self.port = port
        self.accepts = accepts
        self.gates = gates
        self.http2Connections = registry
    }

    func url(_ path: String) -> URL {
        URL(string: "https://127.0.0.1:\(port)\(path)")!
    }

    func stop() async {
        try? await channel.close().get()
    }
}
