//
//  ChannelLifetime.swift
//  HTTPConnectionKit
//
//  Created by NeedleTails on 10/5/26.
//

import Foundation
import NIOCore

/// The channels a cancelled request should close.
///
/// A cancel that arrives before the channel exists still closes the channel passed to a later
/// `watch` or `set`. Replacing the target with `set` drops the previous channels from this list.
final class CancelTarget: @unchecked Sendable {
    private struct Target {
        var channel: Channel
        var closesParent: Bool
    }

    private let lock = NSLock()
    private var targets: [Target] = []
    private var cancelled = false

    /// Records a connection channel. Returns whether cancellation already won.
    ///
    /// Connection channels close their parent too, so a QUIC connection also releases its UDP socket.
    @discardableResult
    func watch(_ channel: Channel) -> Bool {
        lock.lock()
        targets.append(Target(channel: channel, closesParent: true))
        let cancelled = self.cancelled
        lock.unlock()
        if cancelled {
            Self.discard(channel, closesParent: true)
        }
        return cancelled
    }

    /// Replaces every recorded channel with this one.
    ///
    /// Request streams pass `closesParent: false` so cancelling the stream leaves the shared
    /// connection open. A newly created connection passes `closesParent: true`.
    func set(_ channel: Channel, closesParent: Bool = false) {
        lock.lock()
        targets = [Target(channel: channel, closesParent: closesParent)]
        let cancelled = self.cancelled
        lock.unlock()
        if cancelled {
            Self.discard(channel, closesParent: closesParent)
        }
    }

    /// Closes every channel recorded so far and remembers that later channels should close too.
    func close() {
        lock.lock()
        cancelled = true
        let targets = self.targets
        lock.unlock()
        for target in targets {
            Self.discard(target.channel, closesParent: target.closesParent)
        }
    }

    private static func discard(_ channel: Channel, closesParent: Bool) {
        channel.close(promise: nil)
        if closesParent, let parent = channel.parent {
            parent.close(promise: nil)
        }
    }
}

/// Set when a connect task is cancelled before its channel exists, so a late success still closes.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

extension HTTPConnection {
    /// Quiesces the connection, closes it, and closes a parent UDP socket when this channel has one.
    static func closeConnection(_ channel: Channel) async {
        channel.triggerUserOutboundEvent(ChannelShouldQuiesceEvent(), promise: nil)
        try? await channel.close().get()
        if let parent = channel.parent {
            try? await parent.close().get()
        }
    }

    /// Closes a channel that lost a race or was abandoned, including its UDP parent.
    static func discard(_ channel: Channel) {
        channel.close(promise: nil)
        channel.parent?.close(promise: nil)
    }

    /// Waits for a connect future and closes the channel if the task is cancelled first.
    ///
    /// `EventLoopFuture.get()` ignores cancellation. A cancelled wait returns immediately, and a
    /// channel that connects afterward is closed here.
    static func resolveChannel(_ future: EventLoopFuture<Channel>) async throws -> Channel {
        let flag = CancelFlag()
        future.whenComplete { result in
            guard case .success(let channel) = result, flag.isCancelled else {
                return
            }
            Self.discard(channel)
        }
        return try await withTaskCancellationHandler {
            let channel = try await future.getAbandoningOnCancel()
            if flag.isCancelled {
                Self.discard(channel)
                throw CancellationError()
            }
            return channel
        } onCancel: {
            flag.cancel()
        }
    }

    /// Waits for a future and runs `onCancel` when the task stops waiting.
    static func resolve<Value: Sendable>(
        _ future: EventLoopFuture<Value>,
        onCancel: @escaping @Sendable () -> Void
    ) async throws -> Value {
        let flag = CancelFlag()
        return try await withTaskCancellationHandler {
            let value = try await future.getAbandoningOnCancel()
            if flag.isCancelled {
                onCancel()
                throw CancellationError()
            }
            return value
        } onCancel: {
            flag.cancel()
            onCancel()
        }
    }
}
