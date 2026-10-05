//
//  ZlibInflater.swift
//  HTTPConnectionKit
//

import Foundation
import SwiftGzip

/// Inflates gzip or zlib deflate, enforcing a decompressed-to-compressed size ratio.
///
/// `SwiftGzip` uses the system zlib on Linux and the SDK zlib on Apple platforms.
final class ZlibInflater: @unchecked Sendable {
    enum Format: Sendable {
        case gzip
        case deflate
    }

    private var compressed = Data()
    private var emitted: Int64 = 0
    private var decompressedCount: Int64 = 0
    private let decompressor: GzipDecompressor
    private let ratioLimit: Int

    init(format: Format, ratioLimit: Int) {
        let windowBits: Int32
        switch format {
        case .gzip:
            windowBits = GzipConstants.maxWindowBits + 16
        case .deflate:
            windowBits = GzipConstants.maxWindowBits
        }
        decompressor = GzipDecompressor(wBits: windowBits)
        self.ratioLimit = max(ratioLimit, 1)
    }

    func push(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        compressed.append(data)
        return try decode(allowIncomplete: true)
    }

    func finish() throws -> Data {
        try decode(allowIncomplete: false)
    }

    private func decode(allowIncomplete: Bool) throws -> Data {
        guard !compressed.isEmpty else { return Data() }
        let inflated: Data
        do {
            inflated = try decompressor.unzip(data: compressed)
        } catch {
            if allowIncomplete {
                return Data()
            }
            throw HTTPConnectionError.invalidRequest
        }
        decompressedCount = Int64(inflated.count)
        try checkRatio()
        let start = Int(emitted)
        guard inflated.count > start else { return Data() }
        emitted = Int64(inflated.count)
        return inflated.subdata(in: start..<inflated.count)
    }

    private func checkRatio() throws {
        guard !compressed.isEmpty else { return }
        if decompressedCount > Int64(compressed.count) * Int64(ratioLimit) {
            throw HTTPConnectionError.decompressionLimit
        }
    }
}
