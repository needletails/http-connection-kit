//
//  HTTP3ClientTests.swift
//  HTTPConnectionKit
//
//  Created by NeedleTails on 10/5/26.
//

import Foundation
import HTTPConnectionKit
import HTTPTypes
import Testing

@Suite("HTTP/3 against a local QUIC server", .serialized)
struct HTTP3ClientTests {
    @Test func getAndPost() async throws {
        guard #available(anyAppleOS 26, *) else { return }
        try await withHTTP3Client { client, server in
            let get = try await client.request(
                method: .get,
                url: server.url("/echo?q=1"),
                headers: headerFields(("x-token", "quic")),
                body: nil
            )
            #expect(get.head.status.code == 200)
            let echo = FixtureEcho(try #require(get.body))
            #expect(echo.fields["scheme"] == "https")
            #expect(echo.fields["authority"] == "127.0.0.1:\(server.port)")
            #expect(echo.fields["uri"] == "/echo?q=1")
            #expect(echo.fields["header.x-token"] == "quic")
            #expect(echo.fields["header.host"] == nil)

            let payload = Data("quic-body".utf8)
            let post = try await client.request(
                method: .post,
                url: server.url("/echo"),
                headers: headerFields(("host", "example.test")),
                body: payload
            )
            let posted = FixtureEcho(try #require(post.body))
            #expect(posted.fields["header.host"] == nil)
            #expect(posted.fields["header.content-length"] == String(payload.count))
            #expect(posted.body == payload)
            #expect(server.accepts.count == 1)
        }
    }

    @Test func pooledConnectionServesLaterRequests() async throws {
        guard #available(anyAppleOS 26, *) else { return }
        try await withHTTP3Client { client, server in
            for method in [HTTPRequest.Method.put, .patch, .delete, .options] {
                let response = try await client.request(
                    method: method,
                    url: server.url("/echo"),
                    headers: [:],
                    body: method == .put ? Data("stored".utf8) : nil
                )
                #expect(responseHeader(response, "x-method") == method.rawValue)
            }
            #expect(server.accepts.count == 1)
        }
    }

    @Test func headEmptyStatusInformationalAndTrailers() async throws {
        guard #available(anyAppleOS 26, *) else { return }
        try await withHTTP3Client { client, server in
            let head = try await client.request(method: .head, url: server.url("/echo"), headers: [:], body: nil)
            #expect(head.body == nil)
            #expect(responseHeader(head, "x-method") == "HEAD")

            let empty = try await client.request(method: .get, url: server.url("/empty"), headers: [:], body: nil)
            #expect(empty.head.status.code == 204)
            #expect(empty.body == nil)

            let missing = try await client.request(method: .get, url: server.url("/status/404"), headers: [:], body: nil)
            #expect(missing.head.status.code == 404)

            let informational = try await client.request(
                method: .post,
                url: server.url("/informational"),
                headers: [:],
                body: Data("x".utf8)
            )
            #expect(informational.head.status.code == 200)
            #expect(informational.body == Data("final".utf8))

            let trailed = try await client.request(method: .get, url: server.url("/trailers"), headers: [:], body: nil)
            #expect(trailed.body == Data("trailed".utf8))
            #expect(responseHeader(trailed, "x-trailer") == "yes")
        }
    }

    @Test func aFailedRequestDoesNotPreventALaterHTTP3Request() async throws {
        guard #available(anyAppleOS 26, *) else { return }
        var configuration = uncheckedTLSConfiguration()
        configuration.timeouts.connect = .milliseconds(400)
        configuration.channel.quicIdleTimeout = .seconds(2)
        try await withClient(preferred: .http3, configuration: configuration) { client in
            await #expect(throws: Error.self) {
                try await client.request(
                    method: .get,
                    url: URL(string: "https://127.0.0.1:1/echo")!,
                    headers: [:],
                    body: nil
                )
            }
            return ()
        }
        try await withHTTP3Client { client, server in
            let response = try await client.request(method: .get, url: server.url("/echo"), headers: [:], body: nil)
            #expect(response.head.status.code == 200)
        }
    }

    @Test func cancellingAStreamLeavesTheConnectionUsable() async throws {
        guard #available(anyAppleOS 26, *) else { return }
        let server = try await HTTP3FixtureServer.bind()
        var configuration = uncheckedTLSConfiguration()
        configuration.channel.quicIdleTimeout = .seconds(10)
        configuration.protocols = .default
        let client = HTTPConnection(configuration: configuration)
        let holdURL = server.url("/hold")
        let task = Task {
            try await client.request(method: .get, url: holdURL, headers: [:], body: nil)
        }
        let hold = server.hold
        let arrived = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await hold.wait()
                return true
            }
            group.addTask {
                _ = await task.result
                return false
            }
            let arrived = await group.next() ?? false
            group.cancelAll()
            return arrived
        }
        #expect(arrived)
        task.cancel()
        #expect(await waitForTask(task, seconds: 5))
        let response = try await client.request(method: .get, url: server.url("/echo"), headers: [:], body: nil)
        #expect(response.head.status.code == 200)
        #expect(server.accepts.count == 1)
        await client.shutdown()
        await server.stop()
    }
}
