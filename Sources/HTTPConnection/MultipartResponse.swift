//
//  MultipartResponse.swift
//  HTTPConnectionKit
//

import Foundation
import HTTPTypes

/// Parses a `multipart/*` body one part at a time.
public struct MultipartResponse: AsyncSequence, Sendable {
    public struct Part: Sendable {
        public var headerFields: HTTPFields
        public var body: HTTPBody

        public var name: String? {
            dispositionParameter("name")
        }

        public var filename: String? {
            dispositionParameter("filename")
        }

        public var contentType: String? {
            headerFields[.contentType]
        }

        private func dispositionParameter(_ name: String) -> String? {
            guard let disposition = headerFields[.contentDisposition] else {
                return nil
            }
            let needle = "\(name)="
            guard let range = disposition.range(of: needle) else {
                return nil
            }
            var value = disposition[range.upperBound...]
            if value.first == "\"" {
                value.removeFirst()
                if let end = value.firstIndex(of: "\"") {
                    return String(value[..<end]).replacingOccurrences(of: "\\\"", with: "\"")
                }
            }
            if let semicolon = value.firstIndex(of: ";") {
                return String(value[..<semicolon])
            }
            return String(value)
        }
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let source: MultipartParser

        fileprivate init(source: MultipartParser) {
            self.source = source
        }

        public mutating func next() async throws -> Part? {
            try await source.nextPart()
        }
    }

    private let source: MultipartParser

    public init(body: HTTPBody, boundary: String) {
        source = MultipartParser(body: body, boundary: boundary)
    }

    public static func boundary(from contentType: String) -> String? {
        for piece in contentType.split(separator: ";") {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("boundary=") {
                var value = String(trimmed.dropFirst("boundary=".count))
                if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                    value.removeFirst()
                    value.removeLast()
                }
                return value
            }
        }
        return nil
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(source: source)
    }
}

actor MultipartParser {
    private var iterator: HTTPBody.AsyncIterator
    private var buffer = Data()
    private let firstBoundary: Data
    private let delimiter: Data
    private var preambleConsumed = false
    private var finished = false
    private var partComplete = true

    init(body: HTTPBody, boundary: String) {
        iterator = body.makeAsyncIterator()
        let token = Data("--\(boundary)".utf8)
        firstBoundary = token
        delimiter = Data("\r\n".utf8) + token
    }

    func nextPart() async throws -> MultipartResponse.Part? {
        if finished {
            return nil
        }
        if !partComplete {
            while try await nextPartChunk() != nil {}
        }
        if !preambleConsumed {
            try await consumePreamble()
            preambleConsumed = true
        }
        if finished {
            return nil
        }
        partComplete = false
        let headers = try await readHeaders()
        let parser = self
        let partBody = HTTPBody.oneShot {
            try await parser.nextPartChunk()
        }
        return MultipartResponse.Part(headerFields: headers, body: partBody)
    }

    private func consumePreamble() async throws {
        while true {
            if let range = buffer.range(of: firstBoundary) {
                buffer.removeSubrange(..<range.lowerBound)
                try await requireBytes(firstBoundary.count + 2)
                if buffer.starts(with: firstBoundary + Data("--".utf8)) {
                    finished = true
                    return
                }
                if buffer.starts(with: firstBoundary) {
                    buffer.removeSubrange(..<buffer.index(buffer.startIndex, offsetBy: firstBoundary.count))
                    if buffer.starts(with: Data("\r\n".utf8)) {
                        buffer.removeSubrange(..<buffer.index(buffer.startIndex, offsetBy: 2))
                    }
                }
                return
            }
            guard try await pull() else {
                finished = true
                return
            }
        }
    }

    private func readHeaders() async throws -> HTTPFields {
        var fields = HTTPFields()
        while true {
            try await requireBytes(2)
            if let separator = buffer.range(of: Data("\r\n".utf8)) {
                let line = buffer[..<separator.lowerBound]
                buffer.removeSubrange(..<separator.upperBound)
                if line.isEmpty {
                    return fields
                }
                let text = String(decoding: line, as: UTF8.self)
                if let colon = text.firstIndex(of: ":") {
                    let name = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
                    let value = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    if let fieldName = HTTPField.Name(name) {
                        fields.append(HTTPField(name: fieldName, value: value))
                    }
                }
                continue
            }
            guard try await pull() else {
                return fields
            }
        }
    }

    func nextPartChunk() async throws -> Data? {
        if partComplete {
            return nil
        }
        while true {
            if let range = buffer.range(of: delimiter) {
                let chunk = Data(buffer[..<range.lowerBound])
                buffer.removeSubrange(..<range.lowerBound)
                try await finishDelimiter()
                partComplete = true
                return chunk.isEmpty ? nil : chunk
            }
            if buffer.count > delimiter.count {
                let keep = delimiter.count
                let end = buffer.index(buffer.endIndex, offsetBy: -keep)
                let chunk = Data(buffer[..<end])
                buffer.removeSubrange(..<end)
                if !chunk.isEmpty {
                    return chunk
                }
            }
            guard try await pull() else {
                finished = true
                partComplete = true
                let chunk = buffer
                buffer.removeAll()
                return chunk.isEmpty ? nil : chunk
            }
        }
    }

    private func finishDelimiter() async throws {
        try await requireBytes(delimiter.count)
        buffer.removeSubrange(..<buffer.index(buffer.startIndex, offsetBy: delimiter.count))
        if buffer.count < 2 {
            _ = try await pull()
        }
        if buffer.starts(with: Data("--".utf8)) {
            finished = true
        } else if buffer.starts(with: Data("\r\n".utf8)) {
            buffer.removeSubrange(..<buffer.index(buffer.startIndex, offsetBy: 2))
        }
    }

    private func requireBytes(_ count: Int) async throws {
        while buffer.count < count {
            guard try await pull() else {
                return
            }
        }
    }

    private func pull() async throws -> Bool {
        var iterator = iterator
        let chunk = try await iterator.next()
        self.iterator = iterator
        guard let chunk else {
            return false
        }
        buffer.append(chunk)
        return true
    }
}
