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

#if !canImport(Network)
/// Every Linux QUIC channel shares this loop.
///
/// SwiftNetwork updates a stream's send offset on that channel's event loop. One loop keeps a
/// HEADERS block and its FIN on the same stream when several connections are open.
package enum HTTP3EventLoop {
    package static let shared = MultiThreadedEventLoopGroup(numberOfThreads: 1)
}
#endif

/// One side of the HTTP/3 race.
private enum TransportAttempt: Sendable {
    case quic(Channel)
    case tcp(Channel, HTTPVersion)
    case quicFailed
    case tcpFailed
}

/// What the race hands back. A QUIC connection is already in the pool when it wins, because the
/// shared attempt registers it before waking its waiters.
private enum RaceDecision: Sendable {
    case quic(Channel)
    case tcp(Channel, HTTPVersion)
    case failed
}

/// Holds the race errors because `Error` is not `Sendable` across the task group.
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
    ///
    /// Requests that arrive while a connection to the same origin is being opened wait for that
    /// open instead of starting their own, when the origin may produce a multiplexed connection.
    /// A waiter that finds nothing to reuse afterwards opens its own connection.
    func connection(
        for components: RequestComponents,
        cancelTarget: CancelTarget
    ) async throws -> (channel: Channel, created: Bool, version: HTTPVersion) {
        if let existing = reusableConnection(for: components) {
            return (existing.channel, false, existing.negotiatedVersion)
        }

        let origin = Origin(components)
        let coalesce = mayMultiplex(components)
        if coalesce, let pending = pendingOpens[origin] {
            try await pending.value()
            if let existing = reusableConnection(for: components) {
                return (existing.channel, false, existing.negotiatedVersion)
            }
        }

        let opening = SharedOutcome<Void>()
        if coalesce {
            pendingOpens[origin] = opening
        }
        defer {
            if coalesce, pendingOpens[origin] === opening {
                pendingOpens.removeValue(forKey: origin)
            }
            opening.fulfill(.success(()))
        }

        let http2Peer = HTTP2PeerState()
        let opened: (Channel, HTTPVersion)
        var pooledByAttempt = false
        if configuration.protocols.requiredVersion == .http3 {
            if #available(anyAppleOS 26, *) {
                opened = (
                    try await openQUIC(components, cancelTarget: cancelTarget),
                    .http3
                )
            } else {
                throw HTTPConnectionError.unimplemented
            }
        } else if shouldRaceQUIC(components) {
            if #available(anyAppleOS 26, *) {
                let raced = try await raceQUIC(components, http2Peer: http2Peer, cancelTarget: cancelTarget)
                opened = (raced.channel, raced.version)
                pooledByAttempt = raced.pooled
            } else {
                opened = try await openTCP(components, http2Peer: http2Peer, cancelTarget: cancelTarget)
            }
        } else {
            opened = try await openTCP(components, http2Peer: http2Peer, cancelTarget: cancelTarget)
        }

        let channel = opened.0
        let negotiated = opened.1
        if let required = configuration.protocols.requiredVersion,
           negotiated != required.nio
        {
            await Self.closeConnection(channel)
            throw HTTPConnectionError.protocolNegotiationFailed
        }
        if pooledByAttempt {
            // Shared with every other waiter on the attempt, so it is never this request's to close.
            return (channel, false, negotiated)
        }
        if negotiated == .http2 || negotiated == .http3 {
            register(channel, components: components, version: negotiated, http2Peer: http2Peer)
        } else if components.enableTLS {
            singleStreamOrigins.insert(origin)
        }
        return (channel, true, negotiated)
    }

    /// Adds a multiplexed connection to the pool. Registering the same channel twice is a no-op.
    func register(
        _ channel: Channel,
        components: RequestComponents,
        version negotiated: HTTPVersion,
        http2Peer: HTTP2PeerState?
    ) {
        let id = ObjectIdentifier(channel)
        guard connections[id] == nil else {
            return
        }
        connections[id] = LiveConnection(
            key: ConnectionKey(components: components, version: negotiated),
            channel: channel,
            lastUsedNanoseconds: DispatchTime.now().uptimeNanoseconds,
            http2Peer: negotiated == .http2 ? http2Peer : nil
        )
        channel.closeFuture.whenComplete { _ in
            Task { await self.forget(id) }
        }
    }

    /// Whether opening a connection to this origin can produce one that later requests share.
    ///
    /// Cleartext and an HTTP/1 cap never do. A TLS origin that already selected HTTP/1 is
    /// remembered so its requests stop waiting on each other.
    private func mayMultiplex(_ components: RequestComponents) -> Bool {
        components.enableTLS
            && version.major >= 2
            && !singleStreamOrigins.contains(Origin(components))
    }

    /// Highest active HTTP/2 or HTTP/3 connection for this origin that is still within the cap
    /// and can take another stream.
    private func reusableConnection(for components: RequestComponents) -> LiveConnection? {
        let cap = version
        let now = DispatchTime.now().uptimeNanoseconds
        let idleLimit = configuration.pool.idleTimeout.map { UInt64(max($0.httpConnectionNanoseconds, 0)) }
        let expired = connections.filter { _, connection in
            guard connection.activeStreams == 0 else {
                return false
            }
            if connection.isRetiring {
                return true
            }
            guard let idleLimit else {
                return false
            }
            return now >= connection.lastUsedNanoseconds && now - connection.lastUsedNanoseconds >= idleLimit
        }
        for (id, connection) in expired {
            connections.removeValue(forKey: id)
            Self.discard(connection.channel)
        }
        guard let selected = connections
            .filter({ _, connection in
                connection.key.host == components.host
                    && connection.key.port == components.port
                    && connection.key.enableTLS == components.enableTLS
                    && connection.canAcceptStream
                    && connection.channel.isActive
                    && (connection.negotiatedVersion == .http2 || connection.negotiatedVersion == .http3)
                    && Self.withinCap(connection.negotiatedVersion, cap: cap)
            })
            .max(by: { lhs, rhs in
                let left = lhs.value.negotiatedVersion
                let right = rhs.value.negotiatedVersion
                if left.major != right.major {
                    return left.major < right.major
                }
                return left.minor < right.minor
            })
        else {
            return nil
        }
        connections[selected.key]?.lastUsedNanoseconds = now
        return selected.value
    }

    /// HTTP/3 runs beside TCP only for HTTPS when the cap allows it, no lower version is required,
    /// and this origin has not failed QUIC.
    private func shouldRaceQUIC(_ components: RequestComponents) -> Bool {
        components.enableTLS
            && version.major >= 3
            && configuration.protocols.requiredVersion == nil
            && configuration.tls.clientIdentity == nil
            && configuration.tls.trustRoots.usesSystemDefault
            && !quicDeniedOrigins.contains(Origin(components))
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

    /// Records a request stream opened on a pooled HTTP/2 or HTTP/3 connection.
    func streamOpened(on id: ObjectIdentifier) {
        connections[id]?.activeStreams += 1
    }

    /// Records a request stream that finished. A draining or GOAWAY'd connection closes with its last stream.
    func streamClosed(on id: ObjectIdentifier) {
        guard var connection = connections[id] else {
            return
        }
        connection.activeStreams = max(connection.activeStreams - 1, 0)
        connections[id] = connection
        if connection.isRetiring, connection.activeStreams == 0 {
            connections.removeValue(forKey: id)
            Self.discard(connection.channel)
        }
    }

    /// Stops handing out a connection whose request hit its deadline.
    ///
    /// Streams already open on it keep running. A newly created connection that failed is already
    /// closed by its `CancelTarget`, so this only removes the pool entry.
    func drain(_ id: ObjectIdentifier) {
        guard var connection = connections[id] else {
            return
        }
        if connection.activeStreams == 0 {
            connections.removeValue(forKey: id)
            Self.discard(connection.channel)
            return
        }
        connection.isDraining = true
        connections[id] = connection
    }

    /// Returns the first transport that is ready. TCP is already connecting.
    ///
    /// The QUIC handshake is one shared attempt per origin and is not waited for past the TCP
    /// connection. When TCP is ready first the request uses it and the attempt keeps running; the
    /// pool adopts the HTTP/3 connection when the handshake completes, so the next request
    /// upgrades. When QUIC completes first the TCP connect is cancelled. A failed handshake denies
    /// the origin until the network path changes.
    @available(anyAppleOS 26, *)
    private func raceQUIC(
        _ components: RequestComponents,
        http2Peer: HTTP2PeerState,
        cancelTarget: CancelTarget
    ) async throws -> (channel: Channel, version: HTTPVersion, pooled: Bool) {
        let attempt = quicAttempt(for: components)
        let failures = RaceFailures()
        let decision = await withTaskGroup(of: TransportAttempt.self) { group in
            group.addTask {
                do {
                    return .quic(try await attempt.outcome.value())
                } catch is CancellationError {
                    return .quicFailed
                } catch {
                    failures.storeQUIC(error)
                    return .quicFailed
                }
            }
            group.addTask {
                do {
                    let opened = try await self.openTCP(components, http2Peer: http2Peer, cancelTarget: cancelTarget)
                    return .tcp(opened.0, opened.1)
                } catch is CancellationError {
                    return .tcpFailed
                } catch {
                    failures.storeTCP(error)
                    return .tcpFailed
                }
            }

            var decision = RaceDecision.failed
            var quicFailed = false
            var tcpFailed = false
            while let next = await group.next() {
                switch next {
                case .quic(let channel):
                    decision = .quic(channel)
                case .tcp(let channel, let negotiated):
                    decision = .tcp(channel, negotiated)
                case .quicFailed:
                    quicFailed = true
                case .tcpFailed:
                    tcpFailed = true
                }
                if case .failed = decision, !(quicFailed && tcpFailed) {
                    continue
                }
                break
            }
            // Cancelling the QUIC waiter stops this request from waiting; the attempt itself continues.
            group.cancelAll()
            while let next = await group.next() {
                switch next {
                case .tcp(let channel, _):
                    Self.discard(channel)
                case .quic, .quicFailed, .tcpFailed:
                    // A QUIC connection that lands here is already pooled by its attempt.
                    break
                }
            }
            return decision
        }

        switch decision {
        case .quic(let channel):
            return (channel, .http3, true)
        case .tcp(let channel, let negotiated):
            return (channel, negotiated, false)
        case .failed:
            if Task.isCancelled {
                throw CancellationError()
            }
            throw failures.preferred ?? HTTPConnectionError.invalidRequest
        }
    }

    /// The QUIC handshake in flight for this origin, started if there is none.
    ///
    /// The attempt belongs to the client, not to the request that started it. Only `shutdown()`
    /// cancels it, so a request that gives up on waiting leaves the handshake running.
    @available(anyAppleOS 26, *)
    private func quicAttempt(for components: RequestComponents) -> QUICAttempt {
        let origin = Origin(components)
        if let existing = quicAttempts[origin] {
            return existing
        }
        var attempt = QUICAttempt()
        let outcome = attempt.outcome
        attempt.task = Task {
            let target = CancelTarget()
            let result: Result<Channel, any Error>
            do {
                let channel = try await withTaskCancellationHandler {
                    try await self.openQUIC(components, cancelTarget: target)
                } onCancel: {
                    target.close()
                }
                result = .success(channel)
            } catch {
                result = .failure(error)
            }
            // The task inherits the actor, so this is a direct call once the handshake has settled.
            self.quicAttemptFinished(outcome, origin: origin, components: components, result: result)
        }
        quicAttempts[origin] = attempt
        return attempt
    }

    /// Pools a completed handshake or denies the origin, then wakes the attempt's waiters.
    ///
    /// The connection is registered before the waiters wake so a request that receives it finds
    /// it in the pool and never treats it as its own to close.
    private func quicAttemptFinished(
        _ outcome: SharedOutcome<Channel>,
        origin: Origin,
        components: RequestComponents,
        result: Result<Channel, any Error>
    ) {
        let current = quicAttempts[origin]?.outcome === outcome
        if current {
            quicAttempts.removeValue(forKey: origin)
        }
        switch result {
        case .success(let channel):
            guard current else {
                // shutdown() dropped this attempt while the handshake was finishing.
                Self.discard(channel)
                outcome.fulfill(.failure(CancellationError()))
                return
            }
            register(channel, components: components, version: .http3, http2Peer: nil)
        case .failure(let error):
            if current, !(error is CancellationError) {
                denyQUIC(for: origin)
            }
        }
        outcome.fulfill(result)
    }

    /// Opens a QUIC connection. The returned channel is the HTTP/3 connection, not the UDP socket.
    @available(anyAppleOS 26, *)
    private func openQUIC(
        _ components: RequestComponents,
        cancelTarget: CancelTarget
    ) async throws -> Channel {
        #if os(Android)
        // The QUIC loop is shared with in-process servers. Reading the CA directory inside the
        // channel initializer stalls every datagram on that loop.
        _ = AndroidSystemTrustRoots.certificates
        #endif
        let channelOptions = configuration.channel
        let tls = configuration.tls
        let reuse = Self.socketEnabled(channelOptions.reuseLocalEndpoint)
        let udpBuffer = SocketOptionValue(channelOptions.udpBufferBytes)
        let pinned = try await allowedAddresses(for: components)
        // Both datagram bootstraps only expose a future-returning `connect`. `NIOTSDatagramConnectionBootstrap`
        // has no async overload, and NIOPosix's async overload is `.get()` underneath. `resolveChannel`
        // is used instead of `.get()` so a cancelled request stops waiting and closes a late channel.
        #if canImport(Network)
        let datagramBootstrap = NIOTSDatagramConnectionBootstrap(group: NIOTSEventLoopGroup.singleton)
            .connectTimeout(Self.timeAmount(configuration.timeouts.connect))
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
        let connected = if let address = pinned?.first {
            datagramBootstrap.connect(to: address)
        } else {
            datagramBootstrap.connect(host: components.host, port: components.port)
        }
        #else
        // `DatagramBootstrap.connect(host:port:)` resolves with a blocking `getaddrinfo` on the
        // caller, which here is a cooperative-pool thread. An IP literal never asks netd.
        // Hostnames resolve on the NIO thread pool instead.
        let host = components.host
        let port = components.port
        let address: SocketAddress
        if let first = pinned?.first {
            address = first
        } else if let literal = Self.literalAddress(host: host, port: port) {
            address = literal
        } else {
            address = try await NIOThreadPool.singleton.runIfActive {
                try SocketAddress.makeAddressResolvingHost(host, port: port)
            }
        }
        let connected = DatagramBootstrap(group: HTTP3EventLoop.shared)
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
            .connect(to: address)
        #endif
        let udp = try await Self.resolveChannel(connected)
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
        http2Peer: HTTP2PeerState,
        cancelTarget: CancelTarget
    ) async throws -> (Channel, HTTPVersion) {
        let offerHTTP2 = components.enableTLS && version.major >= 2
        let http1 = http1RequestVersion
        let decompressionLimit: NIOHTTPDecompression.DecompressionLimit? =
            configuration.decompression.isEnabled
            ? .ratio(configuration.decompression.ratioLimit)
            : nil
        let negotiation = offerHTTP2
            ? NegotiationSlot(http1: http1, decompressionLimit: decompressionLimit, http2Peer: http2Peer)
            : nil
        let channelOptions = configuration.channel
        let tls = configuration.tls
        let connectTimeout = Self.timeAmount(configuration.timeouts.connect)
        let writeBuffer = Self.writeBufferWaterMark(channelOptions)
        let noDelay = Self.socketEnabled(channelOptions.tcpNoDelay)
        let keepAlive = Self.socketEnabled(channelOptions.keepAlive)
        let reuse = Self.socketEnabled(channelOptions.reuseLocalEndpoint)
        let pinned = try await allowedAddresses(for: components)
        let posixBootstrap = {
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
        }
        let channel: Channel
        #if canImport(Network)
        // Network.framework resolves names itself, so filtered connections use NIOPosix and NIOSSL.
        if let pinned {
            channel = try await Self.resolveChannel(Self.connect(posixBootstrap(), to: pinned, components))
        } else if tls.clientIdentity != nil || !tls.trustRoots.usesSystemDefault {
            channel = try await Self.resolveChannel(
                posixBootstrap().connect(host: components.host, port: components.port)
            )
        } else {
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
        }
        #else
        let bootstrap = posixBootstrap()
        // Android routes `getaddrinfo`, including `127.0.0.1`, through netd. A parallel test
        // run fills that queue and the request deadline fires before the socket exists.
        // Hostnames still use Happy Eyeballs.
        let connecting: EventLoopFuture<Channel>
        if let pinned {
            connecting = Self.connect(bootstrap, to: pinned, components)
        } else if let address = Self.literalAddress(host: components.host, port: components.port) {
            connecting = bootstrap.connect(to: address)
        } else {
            connecting = bootstrap.connect(host: components.host, port: components.port)
        }
        channel = try await Self.resolveChannel(connecting)
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

    private static func timeAmount(_ interval: Duration) -> TimeAmount {
        .nanoseconds(interval.httpConnectionNanoseconds)
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

    /// `nil` when `host` is a name and still needs DNS.
    private static func literalAddress(host: String, port: Int) -> SocketAddress? {
        try? SocketAddress(ipAddress: host, port: port)
    }

    /// The addresses a filtered connection may use, or `nil` when no filter is configured.
    ///
    /// Resolves once, refuses the whole host when any address is refused, and returns the checked
    /// addresses so the connection is made to exactly those (a later DNS answer can't swap them).
    private func allowedAddresses(for components: RequestComponents) async throws -> [SocketAddress]? {
        guard let filter = configuration.addressFilter else { return nil }
        let candidates: [SocketAddress]
        if let literal = Self.literalAddress(host: components.host, port: components.port) {
            candidates = [literal]
        } else {
            let resolver = NIORandomizedDNSResolver(loop: MultiThreadedEventLoopGroup.singleton.next())
            let ipv4 = resolver.initiateAQuery(host: components.host, port: components.port)
            let ipv6 = resolver.initiateAAAAQuery(host: components.host, port: components.port)
            candidates = try await ipv6.get() + ipv4.get()
        }
        guard !candidates.isEmpty else { throw HTTPConnectionError.invalidRequest }
        guard candidates.allSatisfy(filter.allows) else { throw HTTPConnectionError.addressNotAllowed }
        return candidates
    }

    /// Connects to checked addresses only, keeping Happy Eyeballs across them.
    private static func connect(
        _ bootstrap: ClientBootstrap,
        to addresses: [SocketAddress],
        _ components: RequestComponents
    ) -> EventLoopFuture<Channel> {
        if addresses.count == 1 {
            return bootstrap.connect(to: addresses[0])
        }
        return bootstrap
            .resolver(PinnedResolver(addresses, loop: MultiThreadedEventLoopGroup.singleton.next()))
            .connect(host: components.host, port: components.port)
    }
}

/// Answers DNS queries with addresses that were already checked, so Happy Eyeballs can't reach others.
private final class PinnedResolver: Resolver, Sendable {
    private let ipv4: [SocketAddress]
    private let ipv6: [SocketAddress]
    private let loop: any EventLoop

    init(_ addresses: [SocketAddress], loop: any EventLoop) {
        self.ipv4 = addresses.filter { $0.protocol == .inet }
        self.ipv6 = addresses.filter { $0.protocol == .inet6 }
        self.loop = loop
    }

    func initiateAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        loop.makeSucceededFuture(ipv4)
    }

    func initiateAAAAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        loop.makeSucceededFuture(ipv6)
    }

    func cancelQueries() {}
}
