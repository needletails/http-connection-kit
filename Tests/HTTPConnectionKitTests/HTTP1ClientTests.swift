//
//  HTTP1ClientTests.swift
//  HTTPConnectionKit
//
//  Created by NeedleTails on 10/5/26.
//

import Foundation
import HTTPConnectionKit
import HTTPTypes
import Testing

@Suite("HTTP/1 against a local server")
struct HTTP1ClientTests {
    @Test func verbsRoundTrip() async throws {
        let methods: [HTTPRequest.Method] = [
            .get, .post, .put, .patch, .delete, .options, .trace, .query,
            HTTPRequest.Method(rawValue: "PROPFIND")!,
        ]
        try await withHTTP1Client { client, server in
            for method in methods {
                let response = try await client.request(
                    method: method,
                    url: server.url("/echo"),
                    headers: [:],
                    body: nil
                )
                #expect(response.head.status.code == 200)
                #expect(responseHeader(response, "x-method") == method.rawValue)
                #expect(responseHeader(response, "x-server") == "fixture")
                let echo = FixtureEcho(try #require(response.body))
                #expect(echo.fields["method"] == method.rawValue)
                #expect(echo.fields["uri"] == "/echo")
                #expect(echo.body.isEmpty)
            }
        }
    }

    @Test func headHasNoBody() async throws {
        try await withHTTP1Client { client, server in
            let response = try await client.request(
                method: .head,
                url: server.url("/echo?x=1"),
                headers: [:],
                body: nil
            )
            #expect(response.head.status.code == 200)
            #expect(response.body == nil)
            #expect(responseHeader(response, "x-method") == "HEAD")
            #expect(responseHeader(response, "x-uri") == "/echo?x=1")
        }
    }

    @Test func postBodyAndHeadersRoundTrip() async throws {
        let payload = Data("needle tails".utf8)
        try await withHTTP1Client { client, server in
            let response = try await client.request(
                method: .post,
                url: server.url("/echo?q=a%20b"),
                headers: headerFields(("x-token", "secret"), ("host", "example.test")),
                body: payload
            )
            let echo = try #require(response.body.map(FixtureEcho.init))
            #expect(echo.fields["uri"] == "/echo?q=a%20b")
            #expect(echo.fields["header.x-token"] == "secret")
            #expect(echo.fields["header.host"] == "example.test")
            #expect(echo.fields["header.content-length"] == String(payload.count))
            #expect(echo.body == payload)
        }
    }

    @Test func largeBodyRoundTrips() async throws {
        let payload = Data(repeating: 0x61, count: 48_000)
        try await withHTTP1Client { client, server in
            let response = try await client.request(
                method: .put,
                url: server.url("/echo"),
                headers: [:],
                body: payload
            )
            let echo = try #require(response.body.map(FixtureEcho.init))
            #expect(echo.body == payload)
        }
    }

    @Test func emptyResponseBodyIsNil() async throws {
        try await withHTTP1Client { client, server in
            let response = try await client.request(
                method: .get,
                url: server.url("/empty"),
                headers: [:],
                body: nil
            )
            #expect(response.head.status.code == 204)
            #expect(response.body == nil)
        }
    }

    @Test func statusCodeIsPreserved() async throws {
        try await withHTTP1Client { client, server in
            let response = try await client.request(
                method: .get,
                url: server.url("/status/404"),
                headers: [:],
                body: nil
            )
            #expect(response.head.status.code == 404)
            let echo = try #require(response.body.map(FixtureEcho.init))
            #expect(echo.fields["method"] == "GET")
        }
    }

    @Test func informationalResponseIsSkipped() async throws {
        try await withHTTP1Client { client, server in
            let response = try await client.request(
                method: .post,
                url: server.url("/informational"),
                headers: [:],
                body: Data("ignored".utf8)
            )
            #expect(response.head.status.code == 200)
            #expect(response.body == Data("final".utf8))
        }
    }

    @Test func trailersAreAppendedToTheResponse() async throws {
        try await withHTTP1Client { client, server in
            let response = try await client.request(
                method: .get,
                url: server.url("/trailers"),
                headers: [:],
                body: nil
            )
            #expect(response.body == Data("trailed".utf8))
            #expect(responseHeader(response, "x-trailer") == "yes")
        }
    }

    @Test func http1IsNotPooled() async throws {
        try await withHTTP1Client { client, server in
            _ = try await client.request(method: .get, url: server.url("/echo"), headers: [:], body: nil)
            _ = try await client.request(method: .get, url: server.url("/echo"), headers: [:], body: nil)
            #expect(server.accepts.count == 2)
        }
    }

    @Test func anEmptyPathBecomesSlash() async throws {
        try await withHTTP1Client { client, server in
            let response = try await client.request(
                method: .get,
                url: server.url(""),
                headers: [:],
                body: nil
            )
            #expect(responseHeader(response, "x-uri") == "/")
        }
    }

    @Test func http1_0UsesThatRequestVersion() async throws {
        try await withHTTP1Client(preferred: .http1_0) { client, server in
            let response = try await client.request(
                method: .get,
                url: server.url("/echo"),
                headers: [:],
                body: nil
            )
            let echo = try #require(response.body.map(FixtureEcho.init))
            #expect(echo.fields["version"] == "1.0")
        }
    }

    @Test func anHTTP3CapStillUsesCleartextHTTP1() async throws {
        try await withHTTP1Client(preferred: .http3) { client, server in
            let response = try await client.request(
                method: .get,
                url: server.url("/echo"),
                headers: [:],
                body: nil
            )
            #expect(response.head.status.code == 200)
            let echo = try #require(response.body.map(FixtureEcho.init))
            #expect(echo.fields["version"] == "1.1")
            #expect(server.accepts.count == 1)
        }
    }

    @Test func clampedWriteBufferStillServesARequest() async throws {
        var configuration = HTTPConnection.Configuration()
        configuration.channel.writeBufferLowWaterMark = 8_192
        configuration.channel.writeBufferHighWaterMark = 1
        try await withHTTP1Client(configuration: configuration) { client, server in
            let response = try await client.request(
                method: .get,
                url: server.url("/echo"),
                headers: [:],
                body: nil
            )
            #expect(response.head.status.code == 200)
        }
    }

    @Test func shutdownAllowsALaterRequest() async throws {
        let server = try await HTTP1FixtureServer.bind()
        let client = HTTPConnection(preferred: .http1_1)
        _ = try await client.request(method: .get, url: server.url("/echo"), headers: [:], body: nil)
        await client.shutdown()
        let response = try await client.request(method: .get, url: server.url("/echo"), headers: [:], body: nil)
        #expect(response.head.status.code == 200)
        #expect(server.accepts.count == 2)
        await client.shutdown()
        await server.stop()
    }

    @Test func cancellationEndsTheRequestAndTheNextOneOpensANewConnection() async throws {
        let server = try await HTTP1FixtureServer.bind()
        let client = HTTPConnection(preferred: .http1_1)
        let holdURL = server.url("/hold")
        let task = Task {
            try await client.request(method: .get, url: holdURL, headers: [:], body: nil)
        }
        await server.hold.wait()
        task.cancel()
        let finished = await waitForTask(task, seconds: 5)
        #expect(finished)
        #expect(task.isCancelled)
        let response = try await client.request(method: .get, url: server.url("/echo"), headers: [:], body: nil)
        #expect(response.head.status.code == 200)
        #expect(server.accepts.count == 2)
        await client.shutdown()
        await server.stop()
    }
}

func waitForTask(_ task: Task<some Any, any Error>, seconds: Int) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            _ = await task.result
            return true
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return false
        }
        let finished = await group.next() ?? false
        group.cancelAll()
        return finished
    }
}
