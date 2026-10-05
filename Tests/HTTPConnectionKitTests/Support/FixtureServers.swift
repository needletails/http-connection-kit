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

/// HTTPS server that speaks only HTTP/1.1 or only HTTP/2.
final class TLSFixtureServer {
    enum Mode: Sendable {
        case http1
        case http2
    }

    let port: Int
    let accepts: AcceptCounter
    let gates: FixtureGates
    private let channel: any Channel

    var hold: HoldGate { gates.hold }

    static func bind(_ mode: Mode) async throws -> TLSFixtureServer {
        let material = LocalTLSMaterial.shared
        var tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: material.certificateChain.map { .certificate($0) },
            privateKey: .privateKey(material.privateKey)
        )
        tls.minimumTLSVersion = .tlsv12
        tls.applicationProtocols = mode == .http2 ? ["h2"] : ["http/1.1"]
        let context = try NIOSSLContext(configuration: tls)
        let accepts = AcceptCounter()
        let gates = FixtureGates()

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
                    }
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return try TLSFixtureServer(channel: channel, accepts: accepts, gates: gates)
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
        URL(string: "https://127.0.0.1:\(port)\(path)")!
    }

    func stop() async {
        try? await channel.close().get()
    }
}
