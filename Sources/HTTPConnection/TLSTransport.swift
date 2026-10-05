//
//  TLSTransport.swift
//  HTTPConnectionKit
//
//  Created by NeedleTails on 10/5/26.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOTLS
import NIOSSL
import NIOHTTPCompression
#if canImport(Network)
import Network
import Security
#endif

/// Holds the ALPN handler. Its `Sendable` conformance is unavailable, so it stays inside this box.
final class NegotiationSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: NIOTypedApplicationProtocolNegotiationHandler<HTTPVersion>?
    private let http1: HTTPVersion
    private let decompressionLimit: NIOHTTPDecompression.DecompressionLimit?

    init(http1: HTTPVersion, decompressionLimit: NIOHTTPDecompression.DecompressionLimit? = nil) {
        self.http1 = http1
        self.decompressionLimit = decompressionLimit
    }

    /// Adds the negotiation handler on the channel's event loop and keeps it after ALPN completes.
    func install(on channel: Channel) -> EventLoopFuture<Void> {
        let http1 = self.http1
        let decompressionLimit = self.decompressionLimit
        return channel.eventLoop.makeCompletedFuture {
            let handler = HTTPConnection.protocolNegotiationHandler(
                http1: http1,
                decompressionLimit: decompressionLimit
            )
            self.lock.lock()
            self.handler = handler
            self.lock.unlock()
            try channel.pipeline.syncOperations.addHandler(handler)
        }
    }

    /// The protocol selected by ALPN. Nil until `install` has stored the handler.
    func result() -> EventLoopFuture<HTTPVersion>? {
        lock.lock()
        defer { lock.unlock() }
        return handler?.protocolNegotiationResult
    }
}

extension HTTPConnection {
    /// Installs HTTP/2 when ALPN selects `h2`, and HTTP/1 for every other result.
    ///
    /// A missing ALPN token is HTTP/1. Servers that do not negotiate still speak HTTP/1.1.
    static func protocolNegotiationHandler(
        http1: HTTPVersion,
        decompressionLimit: NIOHTTPDecompression.DecompressionLimit?
    ) -> NIOTypedApplicationProtocolNegotiationHandler<HTTPVersion> {
        NIOTypedApplicationProtocolNegotiationHandler { result, channel in
            let negotiated: HTTPVersion
            switch result {
            case .negotiated(let name) where name == "h2":
                negotiated = .http2
            default:
                negotiated = http1
            }
            let configured: EventLoopFuture<Void>
            if negotiated == .http2 {
                configured = Self.installHTTP2Handlers(on: channel, enableTLS: true)
            } else {
                configured = Self.installHTTP1Handlers(on: channel, decompressionLimit: decompressionLimit)
            }
            return configured.map { negotiated }
        }
    }

    /// Adds NIOSSL when this process terminates TLS, then either the ALPN handler or HTTP/1.
    ///
    /// Network.framework terminates TLS outside the pipeline, so `negotiateTLSInPipeline` is false
    /// there and only the application handlers are added.
    static func installTCPHandlers(
        on channel: Channel,
        serverHostname: String,
        enableTLS: Bool,
        negotiateTLSInPipeline: Bool,
        tls: Configuration.TLS,
        negotiation: NegotiationSlot?,
        decompressionLimit: NIOHTTPDecompression.DecompressionLimit? = nil
    ) -> EventLoopFuture<Void> {
        let prepared: EventLoopFuture<Void>
        if negotiateTLSInPipeline && enableTLS {
            let protocols = Self.alpnProtocols(offeringHTTP2: negotiation != nil)
            prepared = channel.eventLoop.makeCompletedFuture {
                var configuration = TLSConfiguration.makeClientConfiguration()
                configuration.minimumTLSVersion = tls.minimumVersion.niossl
                configuration.certificateVerification = tls.certificateVerification.niossl
                configuration.applicationProtocols = protocols
                let context = try NIOSSLContext(configuration: configuration)
                let handler = try NIOSSLClientHandler(
                    context: context,
                    serverHostname: Self.sniServerName(serverHostname)
                )
                try channel.pipeline.syncOperations.addHandler(handler)
            }
        } else {
            prepared = channel.eventLoop.makeSucceededVoidFuture()
        }

        return prepared.flatMap {
            if let negotiation {
                return negotiation.install(on: channel)
            }
            return Self.installHTTP1Handlers(on: channel, decompressionLimit: decompressionLimit)
        }
    }

    /// HTTP/1 client codecs. Used directly when HTTP/2 is not offered, and after ALPN falls back.
    static func installHTTP1Handlers(
        on channel: Channel,
        decompressionLimit: NIOHTTPDecompression.DecompressionLimit? = nil
    ) -> EventLoopFuture<Void> {
        channel.pipeline.addHTTPClientHandlers(
            enableOutboundHeaderValidation: true,
            encoderConfiguration: HTTPRequestEncoder.Configuration(),
            decoderLimitConfiguration: NIOHTTPDecoderLimitConfiguration()
        ).flatMap { _ in
            guard let decompressionLimit else {
                return channel.eventLoop.makeSucceededVoidFuture()
            }
            do {
                try channel.pipeline.syncOperations.addHandler(
                    NIOHTTPResponseDecompressor(limit: decompressionLimit)
                )
                return channel.eventLoop.makeSucceededVoidFuture()
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }
    }

    /// Client HTTP/2 pipeline. Inbound streams are translated back to HTTP/1 parts.
    static func installHTTP2Handlers(on channel: Channel, enableTLS: Bool) -> EventLoopFuture<Void> {
        var connection = NIOHTTP2Handler.ConnectionConfiguration()
        connection.initialSettings = [
            HTTP2Setting(parameter: .maxConcurrentStreams, value: 100),
            HTTP2Setting(parameter: .maxHeaderListSize, value: 80 * 1024),
            HTTP2Setting(parameter: .enablePush, value: 0),
            HTTP2Setting(parameter: .initialWindowSize, value: 1_048_576),
            HTTP2Setting(parameter: .maxFrameSize, value: 65_535),
        ]
        connection.targetWindowSize = 1_048_576
        var stream = NIOHTTP2Handler.StreamConfiguration()
        stream.targetWindowSize = 1_048_576
        let httpProtocol: HTTP2FramePayloadToHTTP1ClientCodec.HTTPProtocol = enableTLS ? .https : .http
        return channel.configureHTTP2Pipeline(
            mode: .client,
            connectionConfiguration: connection,
            streamConfiguration: stream,
            inboundStreamInitializer: { streamChannel in
                streamChannel.eventLoop.makeCompletedFuture {
                    try streamChannel.pipeline.syncOperations.addHandler(
                        HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: httpProtocol)
                    )
                }
            }
        ).map { _ in () }
    }

    /// SNI carries a hostname. An IP literal is not a legal server name, and NIOSSL rejects it.
    static func sniServerName(_ host: String) -> String? {
        if (try? SocketAddress(ipAddress: host, port: 0)) != nil {
            return nil
        }
        return host
    }

    /// ALPN tokens for one TCP handshake. HTTP/2 is offered ahead of HTTP/1.1 when the cap allows it.
    static func alpnProtocols(offeringHTTP2: Bool) -> [String] {
        offeringHTTP2 ? ["h2", "http/1.1"] : ["http/1.1"]
    }

    #if canImport(Network)
    /// Network.framework TLS options. ALPN and the certificate policy come from the client configuration.
    static func nwTLSOptions(
        serverHostname: String,
        offeringHTTP2: Bool,
        tls: Configuration.TLS
    ) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, tls.minimumVersion.nw)
        sec_protocol_options_set_tls_server_name(security, serverHostname)
        for alpn in Self.alpnProtocols(offeringHTTP2: offeringHTTP2) {
            alpn.withCString { name in
                sec_protocol_options_add_tls_application_protocol(security, name)
            }
        }
        switch tls.certificateVerification {
        case .fullVerification:
            break
        case .noHostnameVerification:
            sec_protocol_options_set_verify_block(security, { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                let policy = SecPolicyCreateSSL(true, nil)
                SecTrustSetPolicies(secTrust, policy)
                complete(SecTrustEvaluateWithError(secTrust, nil))
            }, DispatchQueue.global())
        case .none:
            sec_protocol_options_set_verify_block(security, { _, _, complete in
                complete(true)
            }, DispatchQueue.global())
        }
        return options
    }
    #endif
}
