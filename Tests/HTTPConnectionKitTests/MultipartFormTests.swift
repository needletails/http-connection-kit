//
//  MultipartFormTests.swift
//  HTTPConnectionKitTests
//

import Foundation
import HTTPConnectionKit
import Testing

@Suite("Multipart forms")
struct MultipartFormTests {
    @Test func framingAndBinaryFile() async throws {
        var form = try MultipartForm(boundary: "test-boundary")
        form.append(try .field(name: "message", value: "hello"))
        form.append(
            try .file(
                name: "upload",
                filename: "a\"b.bin",
                contentType: "application/octet-stream",
                data: Data([0, 1, 2, 255])
            )
        )

        let body = try await form.encoded()
        let prefix = String(decoding: body.dropLast(4), as: UTF8.self)
        #expect(form.contentType == "multipart/form-data; boundary=test-boundary")
        #expect(Int64(body.count) == form.contentLength)
        #expect(prefix.contains("--test-boundary\r\n"))
        #expect(prefix.contains("name=\"message\"\r\n\r\nhello\r\n"))
        #expect(prefix.contains("name=\"upload\"; filename=\"a\\\"b.bin\""))
        #expect(prefix.contains("Content-Type: application/octet-stream\r\n\r\n"))
        #expect(body.suffix(19) == Data("--test-boundary--\r\n".utf8))
        #expect(body.range(of: Data([0, 1, 2, 255])) != nil)
    }

    @Test func rejectsHeaderInjection() throws {
        #expect(throws: HTTPConnectionError.invalidMultipart) {
            try MultipartForm.Part.field(name: "bad\r\nx: y", value: "value")
        }
    }

    @Test func fileIsReadInChunks() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data((0..<100).map(UInt8.init))
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let part = try MultipartForm.Part.file(
            name: "file",
            filename: "file.bin",
            url: url,
            chunkSize: 16
        )
        let form = try MultipartForm(boundary: "file-boundary", parts: [part])
        var chunks: [Data] = []
        for try await chunk in form.stream() {
            chunks.append(chunk)
        }
        let encoded = try await form.encoded()
        #expect(chunks.contains(where: { $0.count == 16 }))
        #expect(chunks.reduce(into: Data(), { $0.append($1) }) == encoded)
    }
}
