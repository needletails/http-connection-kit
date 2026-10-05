//
//  HTTPBody.swift
//  HTTPConnectionKit
//

import Foundation

/// A lazily produced HTTP body.
///
/// Iterating a body applies backpressure: the producer is asked for one chunk only when the
/// consumer calls `next()`. Bodies created from data, chunks, files, or octets can be iterated
/// more than once. A body created with `oneShot` can be consumed only once.
public struct HTTPBody: AsyncSequence, Sendable {
    public typealias Element = Data

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let source: BodyIteratorSource
        private let onCancel: @Sendable () -> Void

        fileprivate init(source: BodyIteratorSource, onCancel: @escaping @Sendable () -> Void) {
            self.source = source
            self.onCancel = onCancel
        }

        public mutating func next() async throws -> Data? {
            let source = source
            let onCancel = onCancel
            return try await withTaskCancellationHandler {
                try await source.next()
            } onCancel: {
                onCancel()
            }
        }
    }

    /// The body length when it is known without consuming the body.
    public let length: Int64?
    /// Whether a redirect or authentication retry can create another iterator.
    public let isReplayable: Bool

    private let factory: @Sendable () -> BodyIteratorSource
    private let lifetime: StreamLifetime?
    private let onCancel: @Sendable () -> Void

    init(
        length: Int64?,
        isReplayable: Bool,
        lifetime: StreamLifetime? = nil,
        factory: @escaping @Sendable () -> BodyIteratorSource
    ) {
        self.length = length
        self.isReplayable = isReplayable
        self.lifetime = lifetime
        self.onCancel = { lifetime?.cancel() }
        self.factory = factory
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(source: factory(), onCancel: onCancel)
    }

    /// Collects every chunk. Prefer iterating when the body may be large.
    public func collect() async throws -> Data {
        try await collect(upTo: Int.max)
    }

    /// Collects at most `limit` bytes.
    public func collect(upTo limit: Int) async throws -> Data {
        guard limit >= 0 else {
            throw HTTPConnectionError.invalidRequest
        }
        var data = Data()
        for try await chunk in self {
            guard chunk.count <= limit - data.count else {
                throw HTTPConnectionError.responseTooLarge
            }
            data.append(chunk)
        }
        return data
    }

    /// Creates a replayable one-chunk body.
    public static func data(_ data: Data) -> Self {
        Self(length: Int64(data.count), isReplayable: true) {
            BodyIteratorSource(chunks: data.isEmpty ? [] : [data])
        }
    }

    /// Creates a replayable body from already separated chunks.
    public static func chunks(_ chunks: [Data]) -> Self {
        let length = chunks.reduce(into: Int64(0)) { $0 += Int64($1.count) }
        return Self(length: length, isReplayable: true) {
            BodyIteratorSource(chunks: chunks)
        }
    }

    /// Reads a file lazily in fixed-size chunks.
    public static func file(_ url: URL, chunkSize: Int = 64 * 1024) throws -> Self {
        guard chunkSize > 0 else {
            throw HTTPConnectionError.invalidRequest
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw HTTPConnectionError.invalidRequest
        }
        return Self(length: number.int64Value, isReplayable: true) {
            BodyIteratorSource(file: url, chunkSize: chunkSize)
        }
    }

    /// Packs octets into chunks instead of writing one byte at a time.
    public static func octets<S: Sequence & Sendable>(
        _ octets: S,
        chunkSize: Int = 64 * 1024
    ) throws -> Self where S.Element == UInt8 {
        guard chunkSize > 0 else {
            throw HTTPConnectionError.invalidRequest
        }
        let bytes = Array(octets)
        var chunks: [Data] = []
        chunks.reserveCapacity((bytes.count + chunkSize - 1) / chunkSize)
        var offset = 0
        while offset < bytes.count {
            let end = Swift.min(offset + chunkSize, bytes.count)
            chunks.append(Data(bytes[offset..<end]))
            offset = end
        }
        return .chunks(chunks)
    }

    /// Creates a body that can be consumed once.
    public static func oneShot(
        length: Int64? = nil,
        next: @escaping @Sendable () async throws -> Data?
    ) -> Self {
        oneShot(length: length, lifetime: nil, next: next)
    }

    static func oneShot(
        length: Int64? = nil,
        lifetime: StreamLifetime?,
        next: @escaping @Sendable () async throws -> Data?
    ) -> Self {
        let gate = OneShotBodyGate(next: next)
        return Self(length: length, isReplayable: false, lifetime: lifetime) {
            gate.take()
        }
    }

    public static func sequence<S: AsyncSequence & Sendable>(_ sequence: S) -> Self where S.Element == Data {
        let reader = SequenceReader(sequence)
        return .oneShot {
            try await reader.next()
        }
    }
}

final class SequenceReader<S: AsyncSequence>: @unchecked Sendable where S.Element == Data {
    private var iterator: S.AsyncIterator

    init(_ sequence: S) {
        iterator = sequence.makeAsyncIterator()
    }

    nonisolated(nonsending) func next() async throws -> Data? {
        try await iterator.next(isolation: #isolation)
    }
}

actor BodyIteratorSource {
    private enum Storage {
        case chunks([Data], Int)
        case file(URL, Int, FileHandle?)
        case closure(@Sendable () async throws -> Data?)
        case failed
    }

    private var storage: Storage

    init(chunks: [Data]) {
        storage = .chunks(chunks, 0)
    }

    init(file: URL, chunkSize: Int) {
        storage = .file(file, chunkSize, nil)
    }

    init(next: @escaping @Sendable () async throws -> Data?) {
        storage = .closure(next)
    }

    init(failed: Void = ()) {
        storage = .failed
    }

    func next() async throws -> Data? {
        switch storage {
        case .chunks(let chunks, let index):
            guard index < chunks.count else { return nil }
            storage = .chunks(chunks, index + 1)
            return chunks[index]
        case .file(let url, let chunkSize, let existing):
            let handle = try existing ?? FileHandle(forReadingFrom: url)
            let data = try handle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty {
                try handle.close()
                storage = .chunks([], 0)
                return nil
            }
            storage = .file(url, chunkSize, handle)
            return data
        case .closure(let next):
            return try await next()
        case .failed:
            throw HTTPConnectionError.bodyAlreadyConsumed
        }
    }
}

private final class OneShotBodyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var nextClosure: (@Sendable () async throws -> Data?)?

    init(next: @escaping @Sendable () async throws -> Data?) {
        nextClosure = next
    }

    func take() -> BodyIteratorSource {
        lock.lock()
        let closure = nextClosure
        nextClosure = nil
        lock.unlock()
        guard let closure else {
            return BodyIteratorSource()
        }
        return BodyIteratorSource(next: closure)
    }
}
