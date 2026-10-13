//
//  HTTP2PeerState.swift
//  HTTPConnectionKit
//
//  Created by NeedleTails on 10/13/26.
//

import Foundation
import NIOCore
import NIOHTTP2

/// What the HTTP/2 peer has told us about one connection.
///
/// `NIOHTTP2Handler` queues streams opened past the peer's `SETTINGS_MAX_CONCURRENT_STREAMS` and
/// fails streams opened after a GOAWAY. The pool reads this so it opens another connection
/// instead of queueing behind a saturated one or handing out a retiring one.
final class HTTP2PeerState: @unchecked Sendable {
    private let lock = NSLock()
    private var _maxConcurrentStreams: Int?
    private var _goAwayReceived = false

    /// The peer's advertised concurrent-stream limit. Nil until the first SETTINGS arrives, which
    /// RFC 9113 treats as unlimited.
    var maxConcurrentStreams: Int? {
        lock.lock()
        defer { lock.unlock() }
        return _maxConcurrentStreams
    }

    /// Set once the peer sends GOAWAY. Streams opened after this fail.
    var goAwayReceived: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _goAwayReceived
    }

    func update(maxConcurrentStreams: Int) {
        lock.lock()
        _maxConcurrentStreams = maxConcurrentStreams
        lock.unlock()
    }

    func markGoAway() {
        lock.lock()
        _goAwayReceived = true
        lock.unlock()
    }
}

/// Records connection-level SETTINGS and GOAWAY frames into an `HTTP2PeerState`.
///
/// `NIOHTTP2Handler` forwards root-stream frames down the connection pipeline after applying
/// them, so this sits directly behind it and reads them without changing their handling.
final class HTTP2PeerStateObserver: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame
    typealias InboundOut = HTTP2Frame

    private let state: HTTP2PeerState

    init(state: HTTP2PeerState) {
        self.state = state
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        if frame.streamID == .rootStream {
            switch frame.payload {
            case .settings(.settings(let settings)):
                if let limit = settings.last(where: { $0.parameter == .maxConcurrentStreams }) {
                    state.update(maxConcurrentStreams: limit.value)
                }
            case .goAway:
                state.markGoAway()
            default:
                break
            }
        }
        context.fireChannelRead(data)
    }
}
