//
//  ConnectionPool.swift
//  HTTPConnectionKit
//
//  Created by NeedleTails on 10/5/26.
//

import Foundation
import NIO
import NIOCore
import NIOHTTP1
import NIOHTTPCompression
import NIOTransportServices

/// One side of the HTTP/3 race. Failures stay in `RaceFailures` because `Error` is not `Sendable`.
private enum TransportAttempt: Sendable {
    case quic(Channel)
    case tcp(Channel, HTTPVersion)
    case quicFailed
    case tcpFailed
}

private enum RaceDecision: Sendable {
    case quic(Channel)
    case tcp(Channel, HTTPVersion, quicFailed: Bool)
    case failed
}

private final class RaceFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var tcp: Error?
    private var quic: Error?

    func storeTCP(_ error: Error) {
        lock.lock()
        tcp = error
        lock.unlock()
    }

    func storeQUIC(_ error: Error) {
        lock.lock()
        quic = error
        lock.unlock()
    }

    var preferred: Error? {
        lock.lock()
        defer { lock.unlock() }
        return tcp ?? quic
    }
}

extension HTTPConnection {
    /// Returns a pooled HTTP/2 or HTTP/3 connection, or opens a new one.
    ///
    /// HTTP/1 connections are not pooled. `executeThenClose` closes them, and a channel can be
    /// wrapped in `NIOAsyncChannel` only once.
    func connection(
        for components: RequestComponents,
        cancelTarget: CancelTarget
    ) async throws -> (channel: Channel, created: Bool, version: HTTPVersion) {
        if let existing = reusableConnection(for: components) {
            return (existing.channel, false, existing.negotiatedVersion)
        }

        let opened: (Channel, HTTPVersion)
        if shouldRaceQUIC(components) {
            if #available(anyAppleOS 26, *) {
                opened = try await raceQUIC(components, cancelTarget: cancelTarget)
            } else {
                opened = try await openTCP(components, cancelTarget: cancelTarget)
            }
        } else {
            opened = try await openTCP(components, cancelTarget: cancelTarget)
        }

        let channel = opened.0
        let negotiated = opened.1
        if negotiated == .http2 || negotiated == .http3 {
            let id = ObjectIdentifier(channel)
            connections[id] = LiveConnection(
                key: ConnectionKey(components: components, version: negotiated),
                channel: channel
            )
            channel.closeFuture.whenComplete { _ in
                Task { await self.forget(id) }
            }
        }
        return (channel, true, negotiated)
    }

    /// Highest active HTTP/2 or HTTP/3 connection for this origin that is still within the cap.
    private func reusableConnection(for components: RequestComponents) -> LiveConnection? {
        let cap = version
        return connections.values
            .filter { connection in
                connection.key.host == components.host
                    && connection.key.port == components.port
                    && connection.key.enableTLS == components.enableTLS
                    && connection.channel.isActive
                    && (connection.negotiatedVersion == .http2 || connection.negotiatedVersion == .http3)
                    && Self.withinCap(connection.negotiatedVersion, cap: cap)
            }
            .max { lhs, rhs in
                let left = lhs.negotiatedVersion
                let right = rhs.negotiatedVersion
                if left.major != right.major {
                    return left.major < right.major
                }
                return left.minor < right.minor
            }
    }

    /// HTTP/3 runs beside TCP only for HTTPS when the cap allows it and this origin has not failed QUIC.
    private func shouldRaceQUIC(_ components: RequestComponents) -> Bool {
        components.enableTLS && version.major >= 3 && !quicDeniedOrigins.contains(Origin(components))
    }

    /// The HTTP/1 request-line version used when the server does not select HTTP/2.
    private var http1RequestVersion: HTTPVersion {
        version == .http1_0 ? .http1_0 : .http1_1
    }

    private static func withinCap(_ negotiated: HTTPVersion, cap: HTTPVersion) -> Bool {
        if negotiated.major != cap.major {
            return negotiated.major < cap.major
        }
        return negotiated.minor <= cap.minor
    }

    private func forget(_ id: ObjectIdentifier) {
        connections.removeValue(forKey: id)
    }

    /// Waits for the QUIC handshake to succeed or fail. TCP is already connecting.
    ///
    /// A completed QUIC handshake wins and the TCP connection is closed. A failed QUIC handshake
    /// leaves the TCP connection, which has already selected HTTP/2 or HTTP/1.1. That origin then
    /// stays on TCP for the life of this client.
    @available(anyAppleOS 26, *)
    private func raceQUIC(
        _ components: RequestComponents,
        cancelTarget: CancelTarget
    ) async throws -> (Channel, HTTPVersion) {
        let failures = RaceFailures()
        let decision = await withTaskGroup(of: TransportAttempt.self) { group in
            group.addTask {
                do {
                    let channel = try await self.openQUIC(components, cancelTarget: cancelTarget)
                    return .quic(channel)
                } catch is CancellationError {
                    return .quicFailed
                } catch {
                    failures.storeQUIC(error)
                    return .quicFailed
                }
            }
            group.addTask {
                do {
                    let opened = try await self.openTCP(components, cancelTarget: cancelTarget)
                    return .tcp(opened.0, opened.1)
                } catch is CancellationError {
                    return .tcpFailed
                } catch {
                    failures.storeTCP(error)
                    return .tcpFailed
                }
            }

            var quic: Channel?
            var tcp: (Channel, HTTPVersion)?
            var quicFailed = false
            var tcpFailed = false
            while let attempt = await group.next() {
                switch attempt {
                case .quic(let channel):
                    quic = channel
                case .tcp(let channel, let negotiated):
                    tcp = (channel, negotiated)
                case .quicFailed:
                    quicFailed = true
                case .tcpFailed:
                    tcpFailed = true
                }
                if quic != nil || (quicFailed && (tcp != nil || tcpFailed)) {
                    break
                }
            }
            group.cancelAll()
            while let attempt = await group.next() {
                switch attempt {
                case .quic(let channel):
                    Self.discard(channel)
                case .tcp(let channel, _):
                    Self.discard(channel)
                case .quicFailed, .tcpFailed:
                    break
                }
            }

            if let quic {
                if let tcp {
                    Self.discard(tcp.0)
                }
                return RaceDecision.quic(quic)
            }
            if quicFailed, let tcp {
                return .tcp(tcp.0, tcp.1, quicFailed: true)
            }
            return .failed
        }

        switch decision {
        case .quic(let channel):
            return (channel, .http3)
        case .tcp(let channel, let negotiated, let quicFailed):
            if quicFailed {
                quicDeniedOrigins.insert(Origin(components))
            }
            return (channel, negotiated)
        case .failed:
            if Task.isCancelled {
                throw CancellationError()
            }
            throw failures.preferred ?? HTTPConnectionError.invalidRequest
        }
    }

    /// Opens a QUIC connection. The returned channel is the HTTP/3 connection, not the UDP socket.
    @available(anyAppleOS 26, *)
    private func openQUIC(
        _ components: RequestComponents,
        cancelTarget: CancelTarget
    ) async throws -> Channel {
        let udp: Channel
        let channelOptions = configuration.channel
        let tls = configuration.tls
        let reuse = Self.socketEnabled(channelOptions.reuseLocalEndpoint)
        let udpBuffer = SocketOptionValue(channelOptions.udpBufferBytes)
        #if canImport(Network)
        let connected = NIOTSDatagramConnectionBootstrap(group: NIOTSEventLoopGroup.singleton)
            .connectTimeout(Self.timeAmount(channelOptions.connectTimeout))
            .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
            .channelOption(NIOTSChannelOptions.allowLocalEndpointReuse, value: channelOptions.reuseLocalEndpoint)
            .channelOption(NIOTSChannelOptions.maximumReceiveLength, value: channelOptions.maximumReceiveLength)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try Self.installQUICHandler(
                        on: channel,
                        connectedDatagramBytes: true,
                        tls: tls,
                        quicIdleTimeout: channelOptions.quicIdleTimeout
                    )
                }
            }
            .connect(host: components.host, port: components.port)
        #else
        let connected = DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelOption(.socketOption(.so_reuseaddr), value: reuse)
            .channelOption(.socketOption(.so_rcvbuf), value: udpBuffer)
            .channelOption(.socketOption(.so_sndbuf), value: udpBuffer)
            .channelOption(
                .recvAllocator,
                value: FixedSizeRecvByteBufferAllocator(capacity: channelOptions.maximumReceiveLength)
            )
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try Self.installQUICHandler(
                        on: channel,
                        connectedDatagramBytes: false,
                        tls: tls,
                        quicIdleTimeout: channelOptions.quicIdleTimeout
                    )
                }
            }
            .connect(host: components.host, port: components.port)
        #endif
        udp = try await Self.resolveChannel(connected)
        do {
            let connection = try await Self.openHTTP3Connection(on: udp, serverHostname: components.host)
            if cancelTarget.watch(connection) {
                throw CancellationError()
            }
            return connection
        } catch {
            Self.discard(udp)
            throw error
        }
    }

    /// Opens a TCP connection and reads the protocol ALPN selected.
    ///
    /// Cleartext has no ALPN handshake, so it is HTTP/1. HTTPS offers `h2` and `http/1.1` when the
    /// cap is HTTP/2 or HTTP/3.
    private func openTCP(
        _ components: RequestComponents,
        cancelTarget: CancelTarget
    ) async throws -> (Channel, HTTPVersion) {
        let offerHTTP2 = components.enableTLS && version.major >= 2
        let http1 = http1RequestVersion
        let decompressionLimit: NIOHTTPDecompression.DecompressionLimit? =
            configuration.decompressResponses
            ? .ratio(max(configuration.decompressionRatioLimit, 1))
            : nil
        let negotiation = offerHTTP2 ? NegotiationSlot(http1: http1, decompressionLimit: decompressionLimit) : nil
        let channelOptions = configuration.channel
        let tls = configuration.tls
        let connectTimeout = Self.timeAmount(channelOptions.connectTimeout)
        let writeBuffer = Self.writeBufferWaterMark(channelOptions)
        let noDelay = Self.socketEnabled(channelOptions.tcpNoDelay)
        let keepAlive = Self.socketEnabled(channelOptions.keepAlive)
        let reuse = Self.socketEnabled(channelOptions.reuseLocalEndpoint)
        let channel: Channel
        #if canImport(Network)
        var bootstrap = NIOTSConnectionBootstrap(group: NIOTSEventLoopGroup.singleton)
            .connectTimeout(connectTimeout)
            .channelOption(.tcpOption(.tcp_nodelay), value: noDelay)
            .channelOption(.socketOption(.so_keepalive), value: keepAlive)
            .channelOption(.allowRemoteHalfClosure, value: true)
            .channelOption(.writeBufferWaterMark, value: writeBuffer)
            .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
            .channelOption(NIOTSChannelOptions.allowLocalEndpointReuse, value: channelOptions.reuseLocalEndpoint)
            .channelOption(NIOTSChannelOptions.maximumReceiveLength, value: channelOptions.maximumReceiveLength)
            .channelInitializer { channel in
                Self.installTCPHandlers(
                    on: channel,
                    serverHostname: components.host,
                    enableTLS: components.enableTLS,
                    negotiateTLSInPipeline: false,
                    tls: tls,
                    negotiation: negotiation,
                    decompressionLimit: decompressionLimit
                )
            }
        if components.enableTLS {
            bootstrap = bootstrap.tlsOptions(
                Self.nwTLSOptions(serverHostname: components.host, offeringHTTP2: offerHTTP2, tls: tls)
            )
        }
        channel = try await Self.resolveChannel(bootstrap.connect(host: components.host, port: components.port))
        #else
        channel = try await Self.resolveChannel(
            ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .channelOption(.socketOption(.so_reuseaddr), value: reuse)
                .channelOption(.tcpOption(.tcp_nodelay), value: noDelay)
                .channelOption(.socketOption(.so_keepalive), value: keepAlive)
                .channelOption(.allowRemoteHalfClosure, value: true)
                .channelOption(.writeBufferWaterMark, value: writeBuffer)
                .connectTimeout(connectTimeout)
                .channelInitializer { channel in
                    Self.installTCPHandlers(
                        on: channel,
                        serverHostname: components.host,
                        enableTLS: components.enableTLS,
                        negotiateTLSInPipeline: true,
                        tls: tls,
                        negotiation: negotiation,
                        decompressionLimit: decompressionLimit
                    )
                }
                .connect(host: components.host, port: components.port)
        )
        #endif

        do {
            let negotiated: HTTPVersion
            if let negotiation {
                guard let result = negotiation.result() else {
                    throw HTTPConnectionError.invalidRequest
                }
                negotiated = try await Self.resolve(result) {
                    Self.discard(channel)
                }
            } else {
                negotiated = http1
            }
            if cancelTarget.watch(channel) {
                throw CancellationError()
            }
            return (channel, negotiated)
        } catch {
            Self.discard(channel)
            throw error
        }
    }

    private static func timeAmount(_ interval: Configuration.Interval) -> TimeAmount {
        .nanoseconds(interval.nanoseconds)
    }

    private static func writeBufferWaterMark(
        _ channel: Configuration.Channel
    ) -> ChannelOptions.Types.WriteBufferWaterMark {
        let low = channel.writeBufferLowWaterMark
        let high = max(channel.writeBufferHighWaterMark, low)
        return ChannelOptions.Types.WriteBufferWaterMark(low: low, high: high)
    }

    private static func socketEnabled(_ enabled: Bool) -> SocketOptionValue {
        SocketOptionValue(enabled ? 1 : 0)
    }
}
