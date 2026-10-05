//
//  HTTP3FixtureServer.swift
//  HTTPConnectionKit
//
//  Created by NeedleTails on 10/5/26.
//

import Foundation
import HTTPTypes
import Logging
import NIOCore
import NIOHTTPTypes
import NIOPosix
@_spi(PackageInternal) import NIOHTTP3
import NIOQUIC

/// HTTP/3 server on a UDP socket. TCP is not listening, so a client that prefers HTTP/3 can only succeed on QUIC.
@available(anyAppleOS 26, *)
final class HTTP3FixtureServer {
    let port: Int
    let accepts: AcceptCounter
    let hold: HoldGate
    private let channel: any Channel

    static func bind() async throws -> HTTP3FixtureServer {
        let material = LocalTLSMaterial.shared
        let configuration = QUICConfiguration.server(
            serverName: "127.0.0.1",
            authenticationConfiguration: .x509Certificates(
                certificateChainFilePath: material.certificatePath,
                privateKeyFilePath: material.keyPath
            ),
            applicationProtocols: ["h3"],
            maxIdleTimeout: .seconds(30),
            initialMaxData: 16_777_216,
            initialMaxStreamDataBidiLocal: 1_048_576,
            initialMaxStreamDataBidiRemote: 1_048_576,
            initialMaxStreamDataUni: 1_048_576,
            initialMaxStreamsBidi: 100,
            initialMaxStreamsUni: 8
        )
        let authenticator = try Authenticator(
            certificateFilePath: material.certificatePath,
            privateKeyFilePath: material.keyPath
        )
        var mutableLogger = Logger(label: "http-connection-kit.http3-fixture")
        mutableLogger.logLevel = .error
        let logger = mutableLogger
        let accepts = AcceptCounter()
        let hold = HoldGate()

        let channel = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = QUICHandler(
                        channel: channel,
                        quicConfiguration: configuration,
                        asyncVerifier: nil,
                        authenticator: authenticator,
                        logger: logger,
                        inboundConnectionInitializer: { connection, streamCreator in
                            accepts.increment()
                            return connection.eventLoop.makeCompletedFuture {
                                let http3 = HTTP3ConnectionHandler<QUICStreamCreator>.server(
                                    eventLoop: connection.eventLoop,
                                    configuration: .defaults,
                                    settings: .init(maximumFieldSectionSize: 80 * 1024),
                                    streamCreator: streamCreator,
                                    logger: logger,
                                    inboundRequestStreamInitializer: { parameters in
                                        parameters.channel.eventLoop.makeCompletedFuture {
                                            let stream = try NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>(
                                                wrappingChannelSynchronously: parameters.channel,
                                                configuration: .init(isOutboundHalfClosureEnabled: true)
                                            )
                                            Task {
                                                try? await HTTP3FixtureResponder.respond(on: stream, hold: hold)
                                            }
                                        }
                                    }
                                )
                                try connection.pipeline.syncOperations.addHandler(http3)
                            }
                        },
                        inboundStreamInitializer: { stream in
                            guard let parent = stream.parent else {
                                return stream.eventLoop.makeFailedFuture(FixtureServerError.missingParent)
                            }
                            return parent.pipeline.handler(
                                type: HTTP3ConnectionHandler<QUICStreamCreator>.self
                            ).flatMap { handler in
                                handler.inboundStreamReceived(stream)
                            }
                        },
                        noMoreConnections: {}
                    )
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        guard let port = channel.localAddress?.port else {
            throw FixtureServerError.missingPort
        }
        return HTTP3FixtureServer(port: port, accepts: accepts, hold: hold, channel: channel)
    }

    private init(port: Int, accepts: AcceptCounter, hold: HoldGate, channel: any Channel) {
        self.port = port
        self.accepts = accepts
        self.hold = hold
        self.channel = channel
    }

    func url(_ path: String) -> URL {
        URL(string: "https://127.0.0.1:\(port)\(path)")!
    }

    func stop() async {
        try? await channel.close().get()
    }
}

@available(anyAppleOS 26, *)
enum HTTP3FixtureResponder {
    static func respond(
        on stream: NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>,
        hold: HoldGate
    ) async throws {
        try await stream.executeThenClose { inbound, outbound in
            var method = ""
            var uri = "/"
            var scheme: String?
            var authority: String?
            var headers: [(String, String)] = []
            var body = ByteBuffer()
            var sawHead = false

            for try await part in inbound {
                switch part {
                case .head(let request):
                    sawHead = true
                    method = request.method.rawValue
                    uri = request.path ?? "/"
                    scheme = request.scheme
                    authority = request.authority
                    headers = request.headerFields.map { ($0.name.canonicalName, $0.value) }
                    if fixturePath(uri) == "/hold" {
                        await hold.signal()
                    }
                case .body(var buffer):
                    body.writeBuffer(&buffer)
                case .end:
                    break
                }
            }
            guard sawHead else {
                return
            }

            let plan = fixturePlan(
                method: method,
                uri: uri,
                version: nil,
                scheme: scheme,
                authority: authority,
                headers: headers,
                body: body
            )
            guard case .response(let response) = plan else {
                return
            }
            if response.informational {
                try await outbound.write(.head(HTTPResponse(status: .init(code: 100))))
            }

            var fields = HTTPFields()
            for (name, value) in response.headers {
                if let fieldName = HTTPField.Name(name) {
                    fields[fieldName] = value
                }
            }
            let head = HTTPResponse(
                status: .init(code: response.status),
                headerFields: fields
            )
            try await outbound.write(.head(head))
            if let payload = response.body, payload.readableBytes > 0 {
                try await outbound.write(.body(payload))
            }
            if response.trailers.isEmpty {
                try await outbound.write(.end(nil))
            } else {
                var trailers = HTTPFields()
                for (name, value) in response.trailers {
                    if let fieldName = HTTPField.Name(name) {
                        trailers[fieldName] = value
                    }
                }
                try await outbound.write(.end(trailers))
            }
        }
    }
}
