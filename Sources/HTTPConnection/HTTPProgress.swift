//
//  HTTPProgress.swift
//  HTTPConnectionKit
//

import HTTPTypes

/// Byte counts reported after a chunk is written or produced.
public struct HTTPProgress: Sendable, Equatable {
    public enum Direction: Sendable, Equatable {
        case upload
        case download
    }

    public var direction: Direction
    public var completed: Int64
    public var expected: Int64?

    public init(direction: Direction, completed: Int64, expected: Int64?) {
        self.direction = direction
        self.completed = completed
        self.expected = expected
    }
}

/// A response whose body is pulled from the socket one chunk at a time.
public struct StreamingResponse: Sendable {
    public var head: HTTPResponse
    public var body: HTTPBody
    private let trailerBox: TrailerBox
    /// The pump that feeds `body`; nil for responses assembled without a socket.
    let lifetime: StreamLifetime?

    init(head: HTTPResponse, body: HTTPBody, trailerBox: TrailerBox, lifetime: StreamLifetime? = nil) {
        self.head = head
        self.body = body
        self.trailerBox = trailerBox
        self.lifetime = lifetime
    }

    /// Trailers after the body has been fully consumed.
    public func trailers() async -> HTTPFields {
        await trailerBox.value()
    }
}

final class ProgressCounter: @unchecked Sendable {
    var value: Int64 = 0
}

/// Owns the pump task behind a streaming body.
final class StreamLifetime: @unchecked Sendable {
    private let task: Task<Void, Never>

    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }

    /// Resolves when the pump has finished, whether the stream completed, failed, or was cancelled.
    func finished() async {
        await task.value
    }

    deinit {
        cancel()
    }
}

actor TrailerBox {
    private var fields = HTTPFields()
    private var ready = false
    private var waiter: CheckedContinuation<HTTPFields, Never>?

    func set(_ fields: HTTPFields) {
        self.fields = fields
        ready = true
        waiter?.resume(returning: fields)
        waiter = nil
    }

    func value() async -> HTTPFields {
        if ready {
            return fields
        }
        return await withCheckedContinuation { waiter = $0 }
    }
}
