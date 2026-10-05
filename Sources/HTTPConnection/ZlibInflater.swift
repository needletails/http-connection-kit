//
//  ZlibInflater.swift
//  HTTPConnectionKit
//

import Foundation
import zlib

/// Inflates gzip or zlib deflate, enforcing a decompressed-to-compressed size ratio.
final class ZlibInflater: @unchecked Sendable {
    enum Format: Sendable {
        case gzip
        case deflate
    }

    private var stream = z_stream()
    private var started = false
    private var finished = false
    private var compressedCount: Int64 = 0
    private var decompressedCount: Int64 = 0
    private let format: Format
    private let ratioLimit: Int

    init(format: Format, ratioLimit: Int) {
        self.format = format
        self.ratioLimit = max(ratioLimit, 1)
    }

    deinit {
        if started {
            inflateEnd(&stream)
        }
    }

    func push(_ data: Data) throws -> Data {
        try startIfNeeded()
        compressedCount += Int64(data.count)
        return try inflate(data, finish: false)
    }

    func finish() throws -> Data {
        try startIfNeeded()
        return try inflate(Data(), finish: true)
    }

    private func startIfNeeded() throws {
        guard !started else { return }
        let windowBits: Int32 = format == .gzip ? (16 + MAX_WBITS) : MAX_WBITS
        let status = inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            throw HTTPConnectionError.invalidRequest
        }
        started = true
    }

    private func inflate(_ data: Data, finish: Bool) throws -> Data {
        if finished {
            return Data()
        }
        var output = Data()
        var input = data
        try input.withUnsafeMutableBytes { raw in
            if let base = raw.bindMemory(to: Bytef.self).baseAddress {
                stream.next_in = base
                stream.avail_in = uInt(raw.count)
            } else {
                stream.next_in = nil
                stream.avail_in = 0
            }
            repeat {
                var buffer = [UInt8](repeating: 0, count: 16 * 1024)
                let produced: Int = try buffer.withUnsafeMutableBytes { out in
                    stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(out.count)
                    let status = zlib.inflate(&stream, finish ? Z_FINISH : Z_SYNC_FLUSH)
                    let count = out.count - Int(stream.avail_out)
                    if status == Z_STREAM_END {
                        finished = true
                    } else if status != Z_OK && status != Z_BUF_ERROR {
                        throw HTTPConnectionError.invalidRequest
                    }
                    return count
                }
                if produced > 0 {
                    output.append(contentsOf: buffer.prefix(produced))
                    decompressedCount += Int64(produced)
                    try checkRatio()
                }
                if finished || stream.avail_out > 0 && stream.avail_in == 0 {
                    break
                }
            } while true
        }
        return output
    }

    private func checkRatio() throws {
        guard compressedCount > 0 else { return }
        if decompressedCount > compressedCount * Int64(ratioLimit) {
            throw HTTPConnectionError.decompressionLimit
        }
    }
}
