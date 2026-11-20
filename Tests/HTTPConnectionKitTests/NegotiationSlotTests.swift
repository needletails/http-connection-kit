//
//  NegotiationSlotTests.swift
//  HTTPConnectionKit
//

import NIO
import NIOHTTP1
import NIOTLS
import Testing
@testable import HTTPConnection

@Suite("ALPN negotiation slot")
struct NegotiationSlotTests {
    /// NIO's Happy Eyeballs opens a second connection when the first takes longer than 250 ms,
    /// and runs the channel initializer on each. The slot kept only the last handler, so a slow
    /// first connection that won was answered with the closed loser's failure, and every request
    /// to a distant host failed with `ChannelError.inappropriateOperationForState`.
    @Test func answersForTheChannelThatConnected() throws {
        let slot = NegotiationSlot(http1: .http1_1, http2Peer: HTTP2PeerState())
        let winner = EmbeddedChannel()
        let loser = EmbeddedChannel()
        try slot.install(on: winner).wait()
        try slot.install(on: loser).wait()

        // Happy Eyeballs closes the candidates that lost.
        _ = try? loser.finish()

        let negotiated = try #require(slot.result(for: winner))
        winner.pipeline.fireUserInboundEventTriggered(TLSUserEvent.handshakeCompleted(negotiatedProtocol: nil))
        winner.embeddedEventLoop.run()
        #expect(try negotiated.wait() == .http1_1)
        _ = try? winner.finish()
    }

    @Test func hasNoAnswerForAChannelItNeverSaw() throws {
        let slot = NegotiationSlot(http1: .http1_1, http2Peer: HTTP2PeerState())
        let installed = EmbeddedChannel()
        try slot.install(on: installed).wait()
        #expect(slot.result(for: EmbeddedChannel()) == nil)
        _ = try? installed.finish()
    }
}
