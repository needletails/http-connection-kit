//
//  MultipartForm.swift
//  HTTPConnectionKit
//

import Foundation

/// A `multipart/form-data` request body.
public struct MultipartForm: Sendable {
    public struct Part: Sendable {
        public let name: String
        public let filename: String?
        public let contentType: String?
        public let body: HTTPBody

        public init(
            name: String,
            filename: String? = nil,
            contentType: String? = nil,
            body: HTTPBody
        ) throws {
            try Self.validateParameter(name)
            if let filename {
                try Self.validateParameter(filename)
            }
            self.name = name
            self.filename = filename
            self.contentType = contentType
            self.body = body
        }

        public static func field(name: String, value: String) throws -> Self {
            try Self(name: name, body: .data(Data(value.utf8)))
        }

        public static func file(
            name: String,
            filename: String,
            contentType: String = "application/octet-stream",
            data: Data
        ) throws -> Self {
            try Self(
                name: name,
                filename: filename,
                contentType: contentType,
                body: .data(data)
            )
        }

        public static func file(
            name: String,
            filename: String,
            contentType: String = "application/octet-stream",
            url: URL,
            chunkSize: Int = 64 * 1024
        ) throws -> Self {
            try Self(
                name: name,
                filename: filename,
                contentType: contentType,
                body: HTTPBody.file(url, chunkSize: chunkSize)
            )
        }

        private static func validateParameter(_ value: String) throws {
            if value.unicodeScalars.contains(where: { $0 == "\u{000D}" || $0 == "\u{000A}" }) {
                throw HTTPConnectionError.invalidMultipart
            }
        }
    }

    public let boundary: String
    public private(set) var parts: [Part]

    public init(boundary: String = MultipartForm.makeBoundary(), parts: [Part] = []) throws {
        guard !boundary.isEmpty,
              boundary.count <= 70,
              boundary.unicodeScalars.allSatisfy({ $0.isASCII && $0 != "\u{000D}" && $0 != "\u{000A}" })
        else {
            throw HTTPConnectionError.invalidMultipart
        }
        self.boundary = boundary
        self.parts = parts
    }

    public var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    public mutating func append(_ part: Part) {
        parts.append(part)
    }

    /// The exact framed length when every part has a known length.
    public var contentLength: Int64? {
        var total: Int64 = 0
        for part in parts {
            guard let bodyLength = part.body.length else { return nil }
            total += Int64(prefix(for: part).utf8.count) + bodyLength + 2
        }
        total += Int64(("--\(boundary)--\r\n").utf8.count)
        return total
    }

    /// Returns a replayable stream when all of its parts are replayable.
    public func stream() -> HTTPBody {
        let form = self
        let replayable = parts.allSatisfy(\.body.isReplayable)
        if replayable {
            return HTTPBody.multipart(form)
        }
        let iterator = MultipartBodyIterator(form: form)
        return .oneShot(length: contentLength) {
            try await iterator.next()
        }
    }

    /// Collects the form. This is useful for small forms and compatibility with the buffered API.
    public func encoded() async throws -> Data {
        var result = Data()
        for try await chunk in stream() {
            result.append(chunk)
        }
        return result
    }

    fileprivate func prefix(for part: Part) -> String {
        var disposition = "Content-Disposition: form-data; name=\"\(Self.escape(part.name))\""
        if let filename = part.filename {
            disposition += "; filename=\"\(Self.escape(filename))\""
        }
        var prefix = "--\(boundary)\r\n\(disposition)\r\n"
        if let contentType = part.contentType {
            prefix += "Content-Type: \(contentType)\r\n"
        }
        prefix += "\r\n"
        return prefix
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    public static func makeBoundary() -> String {
        "HTTPConnectionKit-\(UUID().uuidString)"
    }
}

private actor MultipartBodyIterator {
    private let form: MultipartForm
    private var partIndex = 0
    private var stage = 0
    private var bodyIterator: HTTPBody.AsyncIterator?

    init(form: MultipartForm) {
        self.form = form
    }

    func next() async throws -> Data? {
        while partIndex < form.parts.count {
            let part = form.parts[partIndex]
            if stage == 0 {
                stage = 1
                bodyIterator = part.body.makeAsyncIterator()
                return Data(form.prefix(for: part).utf8)
            }
            if stage == 1 {
                guard var iterator = bodyIterator else {
                    throw HTTPConnectionError.invalidMultipart
                }
                if let chunk = try await iterator.next() {
                    bodyIterator = iterator
                    return chunk
                }
                bodyIterator = iterator
                stage = 2
            }
            if stage == 2 {
                partIndex += 1
                stage = 0
                bodyIterator = nil
                return Data("\r\n".utf8)
            }
        }
        if stage != 3 {
            stage = 3
            return Data("--\(form.boundary)--\r\n".utf8)
        }
        return nil
    }
}

private extension HTTPBody {
    static func multipart(_ form: MultipartForm) -> HTTPBody {
        HTTPBody(
            length: form.contentLength,
            isReplayable: true
        ) {
            let iterator = MultipartBodyIterator(form: form)
            return BodyIteratorSource(next: {
                return try await iterator.next()
            })
        }
    }
}
