//
//  StreamingClientTests.swift
//  HTTPConnectionKitTests
//

import Foundation
import HTTPConnectionKit
import HTTPTypes
import Testing

@Suite("Streaming, multipart, and range")
struct StreamingClientTests {
    @Test(arguments: TestHTTP.allCases)
    func bufferedMultipartRoundTrips(_ version: TestHTTP) async throws {
        try await withLocalClient(version) { client, url, _, _ in
            var form = try MultipartForm(boundary: "wire-boundary")
            form.append(try .field(name: "message", value: "hello"))
            form.append(
                try .file(
                    name: "upload",
                    filename: "a.bin",
                    contentType: "application/octet-stream",
                    data: Data([0, 1, 2, 255])
                )
            )
            let encoded = try await form.encoded()
            var headers = HTTPFields()
            headers[.contentType] = form.contentType
            let response = try await client.request(
                method: .post,
                url: url("/echo"),
                headers: headers,
                body: encoded
            )
            let echo = FixtureEcho(try #require(response.body))
            #expect(echo.body == encoded)
            #expect(Int64(encoded.count) == form.contentLength)
            let parts = try await collectParts(echo.body, boundary: form.boundary)
            #expect(parts.count == 2)
            #expect(parts[0].name == "message")
            #expect(parts[0].bytes == Data("hello".utf8))
            #expect(parts[1].filename == "a.bin")
            #expect(parts[1].bytes == Data([0, 1, 2, 255]))
        }
    }

    @Test(arguments: TestHTTP.allCases)
    func uploadChunksAreWrittenAsTheyArrive(_ version: TestHTTP) async throws {
        try await withLocalClient(version) { client, url, gates, _ in
            let (stream, continuation) = AsyncStream<Data>.makeStream()
            let uploadURL = url("/upload-gate")
            let task = Task {
                try await client.request(
                    method: .post,
                    url: uploadURL,
                    headers: [:],
                    body: stream
                )
            }
            continuation.yield(Data("one".utf8))
            await gates.upload.wait()
            continuation.yield(Data("two".utf8))
            continuation.finish()
            let response = try await task.value
            let echo = FixtureEcho(try #require(response.body))
            #expect(echo.body == Data("onetwo".utf8))
            #expect(echo.fields["header.content-length"] == nil)
            if version == .http1 {
                #expect(echo.fields["header.transfer-encoding"] == "chunked")
            }
        }
    }

    @Test(arguments: TestHTTP.allCases)
    func aKnownLengthStreamSetsContentLength(_ version: TestHTTP) async throws {
        try await withLocalClient(version) { client, url, _, _ in
            let body = HTTPBody.chunks([Data("one".utf8), Data("two".utf8)])
            let response = try await client.request(
                method: .post,
                url: url("/echo"),
                headers: [:],
                body: body
            )
            let echo = FixtureEcho(try #require(response.body))
            #expect(echo.body == Data("onetwo".utf8))
            #expect(echo.fields["header.content-length"] == "6")
        }
    }

    @Test(arguments: TestHTTP.allCases)
    func dripYieldsTheFirstChunkBeforeTheRest(_ version: TestHTTP) async throws {
        try await withLocalClient(version) { client, url, gates, accepts in
            let streamed = try await client.requestStream(method: .get, url: url("/drip"))
            var iterator = streamed.body.makeAsyncIterator()
            let first = try await iterator.next()
            #expect(first == Data("HELLO".utf8))
            await gates.drip.wait()
            if version == .http2 {
                let echo = try await client.request(method: .get, url: url("/echo"), headers: [:], body: nil)
                #expect(echo.head.status.code == 200)
                #expect(accepts.count == 1)
            }
            await gates.dripRelease.signal()
            let second = try await iterator.next()
            #expect(second == Data("WORLD".utf8))
            #expect(try await iterator.next() == nil)
        }
    }

    @Test(arguments: TestHTTP.allCases)
    func cancellingAPausedDownloadStopsTheRead(_ version: TestHTTP) async throws {
        try await withLocalClient(version) { client, url, _, _ in
            let streamed = try await client.requestStream(method: .get, url: url("/drip"))
            let sawFirst = HoldGate()
            let read = Task {
                var iterator = streamed.body.makeAsyncIterator()
                _ = try await iterator.next()
                await sawFirst.signal()
                return try await iterator.next()
            }
            await sawFirst.wait()
            read.cancel()
            #expect(await waitForTask(read, seconds: 2))
        }
    }

    @Test func cancellingExpectContinueDoesNotSendTheBody() async throws {
        var configuration = HTTPConnection.Configuration()
        configuration.timeouts.expectContinue = .seconds(30)
        try await withHTTP1Client(configuration: configuration) { client, server in
            let pulled = PullFlag()
            let body = HTTPBody.oneShot {
                pulled.mark()
                return Data("secret".utf8)
            }
            var headers = HTTPFields()
            headers[HTTPField.Name("expect")!] = "100-continue"
            let url = server.url("/expect-silent")
            let request = Task {
                try await client.request(method: .post, url: url, headers: headers, body: body)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            request.cancel()
            #expect(await waitForTask(request, seconds: 2))
            #expect(!pulled.value)
        }
    }

    @Test(arguments: TestHTTP.allCases)
    func endingAStreamEarlyLetsTheNextRequestSucceed(_ version: TestHTTP) async throws {
        try await withLocalClient(version) { client, url, gates, _ in
            do {
                let streamed = try await client.requestStream(method: .get, url: url("/drip"))
                var iterator = streamed.body.makeAsyncIterator()
                #expect(try await iterator.next() == Data("HELLO".utf8))
                await gates.drip.wait()
            }
            await gates.dripRelease.signal()
            let response = try await client.request(method: .get, url: url("/echo"), headers: [:], body: nil)
            #expect(response.head.status.code == 200)
        }
    }

    @Test(arguments: TestHTTP.allCases)
    func aMultipartFileIsStreamedWithAKnownLength(_ version: TestHTTP) async throws {
        try await withLocalClient(version) { client, url, _, _ in
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let bytes = Data((0..<80).map(UInt8.init))
            try bytes.write(to: fileURL)
            defer { try? FileManager.default.removeItem(at: fileURL) }
            let part = try MultipartForm.Part.file(
                name: "file",
                filename: "file.bin",
                url: fileURL,
                chunkSize: 16
            )
            let form = try MultipartForm(boundary: "file-boundary", parts: [part])
            var headers = HTTPFields()
            headers[.contentType] = form.contentType
            let response = try await client.request(
                method: .post,
                url: url("/echo"),
                headers: headers,
                body: form.stream()
            )
            let echo = FixtureEcho(try #require(response.body))
            let encoded = try await form.encoded()
            #expect(echo.body == encoded)
            #expect(echo.fields["header.content-length"] == String(encoded.count))
            #expect(echo.body.range(of: bytes) != nil)
        }
    }

    @Test(arguments: TestHTTP.allCases)
    func anUnknownPartOmitsContentLength(_ version: TestHTTP) async throws {
        try await withLocalClient(version) { client, url, _, _ in
            let (stream, continuation) = AsyncStream<Data>.makeStream()
            continuation.yield(Data("streamed".utf8))
            continuation.finish()
            let part = try MultipartForm.Part(name: "chunk", body: HTTPBody.sequence(stream))
            let form = try MultipartForm(boundary: "unknown-boundary", parts: [part])
            #expect(form.contentLength == nil)
            var headers = HTTPFields()
            headers[.contentType] = form.contentType
            let response = try await client.request(
                method: .post,
                url: url("/echo"),
                headers: headers,
                body: form.stream()
            )
            let echo = FixtureEcho(try #require(response.body))
            #expect(echo.fields["header.content-length"] == nil)
            #expect(echo.body.range(of: Data("streamed".utf8)) != nil)
        }
    }

    @Test(arguments: TestHTTP.allCases)
    func octetsArePackedIntoChunks(_ version: TestHTTP) async throws {
        let log = ProgressLog()
        var configuration = HTTPConnection.Configuration()
        if version == .http2 {
            configuration.tls.certificateVerification = .none
        }
        try await withLocalClient(version, configuration: configuration) { client, url, _, _ in
            let bytes = Array(UInt8(0)..<UInt8(100))
            let body = try HTTPBody.octets(bytes, chunkSize: 32)
            var headers = HTTPFields()
            headers[.contentType] = "application/octet-stream"
            let response = try await client.request(
                method: .post,
                url: url("/echo"),
                headers: headers,
                body: body,
                options: .init(onProgress: { log.append($0) })
            )
            let echo = FixtureEcho(try #require(response.body))
            #expect(echo.body == Data(bytes))
            #expect(echo.body.count == 100)
            let uploads = log.snapshot().filter { $0.direction == .upload }
            #expect(uploads.count == 4)
            #expect(uploads.last?.completed == 100)
            #expect(uploads.last?.expected == 100)
        }
    }

    @Test(arguments: TestHTTP.allCases)
    func aMultipartResponseYieldsPartsAsTheyArrive(_ version: TestHTTP) async throws {
        try await withLocalClient(version) { client, url, gates, _ in
            let streamed = try await client.requestStream(method: .get, url: url("/multipart-pause"))
            let contentType = try #require(streamed.head.headerFields[.contentType])
            let boundary = try #require(MultipartResponse.boundary(from: contentType))
            let parser = MultipartResponse(body: streamed.body, boundary: boundary)
            var iterator = parser.makeAsyncIterator()
            let first = try #require(try await iterator.next())
            #expect(first.name == "one")
            #expect(try await first.body.collect() == Data("first".utf8))
            await gates.multipart.wait()
            await gates.multipartRelease.signal()
            let second = try #require(try await iterator.next())
            #expect(second.name == "two")
            #expect(try await second.body.collect() == Data("second".utf8))
            #expect(try await iterator.next() == nil)
        }
    }

    @Test(arguments: TestHTTP.allCases)
    func expectContinueAcceptsRejectsAndTimesOut(_ version: TestHTTP) async throws {
        var configuration = HTTPConnection.Configuration()
        configuration.timeouts.expectContinue = .milliseconds(200)
        if version == .http2 {
            configuration.tls.certificateVerification = .none
        }
        try await withLocalClient(version, configuration: configuration) { client, url, _, _ in
            var headers = HTTPFields()
            headers[HTTPField.Name("expect")!] = "100-continue"

            let accepted = try await client.request(
                method: .post,
                url: url("/expect-accept"),
                headers: headers,
                body: Data("accepted".utf8)
            )
            let acceptedEcho = FixtureEcho(try #require(accepted.body))
            #expect(acceptedEcho.body == Data("accepted".utf8))

            let pulled = PullFlag()
            let rejectedBody = HTTPBody.oneShot {
                pulled.mark()
                return Data("secret".utf8)
            }
            let rejected = try await client.request(
                method: .post,
                url: url("/expect-reject"),
                headers: headers,
                body: rejectedBody
            )
            #expect(rejected.head.status.code == 403)
            #expect(!pulled.value)

            let silent = try await client.request(
                method: .post,
                url: url("/expect-silent"),
                headers: headers,
                body: Data("late".utf8)
            )
            let silentEcho = FixtureEcho(try #require(silent.body))
            #expect(silentEcho.body == Data("late".utf8))
        }
    }

    @Test(arguments: TestHTTP.allCases)
    func rangeAndResumeDownload(_ version: TestHTTP) async throws {
        try await withLocalClient(version) { client, url, _, _ in
            var headers = HTTPFields()
            headers[.range] = "bytes=4-"
            let slice = try await client.request(method: .get, url: url("/range"), headers: headers, body: nil)
            #expect(slice.head.status.code == 206)
            #expect(slice.head.headerFields[.contentRange] == "bytes 4-9/10")
            #expect(slice.body == Data("456789".utf8))

            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {
                try? FileManager.default.removeItem(at: fileURL)
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: fileURL.path + ".http-range"))
            }
            try Data("0123".utf8).write(to: fileURL)
            try "etag:\"r1\"".write(
                to: URL(fileURLWithPath: fileURL.path + ".http-range"),
                atomically: true,
                encoding: .utf8
            )
            let resumed = try await client.resumeDownload(from: url("/range"), to: fileURL)
            #expect(resumed.head.status.code == 206)
            #expect(try Data(contentsOf: fileURL) == Data("0123456789".utf8))

            try "etag:\"other\"".write(
                to: URL(fileURLWithPath: fileURL.path + ".http-range"),
                atomically: true,
                encoding: .utf8
            )
            let replaced = try await client.resumeDownload(from: url("/range"), to: fileURL)
            #expect(replaced.head.status.code == 200)
            #expect(try Data(contentsOf: fileURL) == Data("0123456789".utf8))
        }
    }

    @Test(arguments: TestHTTP.allCases)
    func progressReportsTheFirstDripChunk(_ version: TestHTTP) async throws {
        let log = ProgressLog()
        var configuration = HTTPConnection.Configuration()
        if version == .http2 {
            configuration.tls.certificateVerification = .none
        }
        try await withLocalClient(version, configuration: configuration) { client, url, gates, _ in
            let streamed = try await client.requestStream(
                method: .get,
                url: url("/drip"),
                options: .init(onProgress: { log.append($0) })
            )
            var iterator = streamed.body.makeAsyncIterator()
            #expect(try await iterator.next() == Data("HELLO".utf8))
            let first = log.snapshot().filter { $0.direction == .download }
            #expect(first.contains(where: { $0.completed == 5 && $0.expected == 10 }))
            await gates.dripRelease.signal()
            #expect(try await iterator.next() == Data("WORLD".utf8))
            let all = log.snapshot().filter { $0.direction == .download }
            #expect(all.contains(where: { $0.completed == 10 && $0.expected == 10 }))
        }
    }
}

@Suite("HTTP/3 streaming extras")
struct HTTP3StreamingTests {
    @Test func bufferedMultipartAndKnownFileRoundTrip() async throws {
        guard #available(anyAppleOS 26, *) else { return }
        try await withHTTP3Client { client, server in
            var form = try MultipartForm(boundary: "h3-boundary")
            form.append(try .field(name: "message", value: "hello"))
            let encoded = try await form.encoded()
            var headers = HTTPFields()
            headers[.contentType] = form.contentType
            let posted = try await client.request(
                method: .post,
                url: server.url("/echo"),
                headers: headers,
                body: encoded
            )
            #expect(FixtureEcho(try #require(posted.body)).body == encoded)

            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data("h3-file".utf8).write(to: fileURL)
            defer { try? FileManager.default.removeItem(at: fileURL) }
            let part = try MultipartForm.Part.file(name: "file", filename: "a.bin", url: fileURL)
            let fileForm = try MultipartForm(boundary: "h3-file", parts: [part])
            headers[.contentType] = fileForm.contentType
            let streamed = try await client.request(
                method: .post,
                url: server.url("/echo"),
                headers: headers,
                body: fileForm.stream()
            )
            let echo = FixtureEcho(try #require(streamed.body))
            #expect(echo.fields["header.content-length"] == String(try #require(fileForm.contentLength)))
            #expect(echo.body.range(of: Data("h3-file".utf8)) != nil)
        }
    }
}

private struct CollectedPart {
    var name: String?
    var filename: String?
    var bytes: Data
}

private func collectParts(_ data: Data, boundary: String) async throws -> [CollectedPart] {
    let parser = MultipartResponse(body: .data(data), boundary: boundary)
    var parts: [CollectedPart] = []
    for try await part in parser {
        parts.append(
            CollectedPart(name: part.name, filename: part.filename, bytes: try await part.body.collect())
        )
    }
    return parts
}

private final class PullFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var pulled = false

    func mark() {
        lock.lock()
        pulled = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pulled
    }
}
