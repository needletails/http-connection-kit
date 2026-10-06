//
//  HTTP2ClientTests.swift
//  HTTPConnectionKit
//
//  Created by NeedleTails on 10/5/26.
//

import Foundation
import HTTPConnectionKit
import HTTPTypes
import Testing

@Suite("HTTP/2 against a local TLS server")
struct HTTP2ClientTests {
    @Test func getPostAndHead() async throws {
        try await withTLSClient(mode: .http2, preferred: .http2) { client, server in
            let get = try await client.request(method: .get, url: server.url("/echo"), headers: [:], body: nil)
            #expect(get.head.status.code == 200)
            #expect(responseHeader(get, "x-method") == "GET")
            let echo = FixtureEcho(try #require(get.body))
            #expect(echo.fields["uri"] == "/echo")

            let payload = Data("http2".utf8)
            let post = try await client.request(
                method: .post,
                url: server.url("/echo?q=1"),
                headers: headerFields(("x-token", "secret")),
                body: payload
            )
            let posted = FixtureEcho(try #require(post.body))
            #expect(posted.fields["header.x-token"] == "secret")
            #expect(posted.fields["header.content-length"] == "5")
            #expect(posted.body == payload)

            let head = try await client.request(
                method: .head,
                url: server.url("/echo"),
                headers: [:],
                body: nil
            )
            #expect(head.head.status.code == 200)
            #expect(head.body == nil)
            #expect(server.accepts.count == 1)
        }
    }

    @Test func pooledConnectionServesASecondRequest() async throws {
        try await withTLSClient(mode: .http2, preferred: .http2) { client, server in
            _ = try await client.request(method: .get, url: server.url("/echo"), headers: [:], body: nil)
            _ = try await client.request(method: .delete, url: server.url("/echo"), headers: [:], body: nil)
            #expect(server.accepts.count == 1)
        }
    }

    @Test func anExpiredIdleConnectionIsNotReused() async throws {
        var configuration = uncheckedTLSConfiguration()
        configuration.pool.idleTimeout = .milliseconds(1)
        try await withTLSClient(mode: .http2, preferred: .http2, configuration: configuration) { client, server in
            _ = try await client.request(method: .get, url: server.url("/echo"))
            try await Task.sleep(nanoseconds: 5_000_000)
            _ = try await client.request(method: .get, url: server.url("/echo"))
            #expect(server.accepts.count == 2)
        }
    }

    @Test func anHTTP3CapReusesTheNegotiatedHTTP2Connection() async throws {
        var configuration = uncheckedTLSConfiguration()
        configuration.channel.quicIdleTimeout = .seconds(3)
        try await withTLSClient(mode: .http2, preferred: .http3, configuration: configuration) { client, server in
            let first = try await client.request(method: .get, url: server.url("/status/201"), headers: [:], body: nil)
            let second = try await client.request(method: .get, url: server.url("/echo"), headers: [:], body: nil)
            #expect(first.head.status.code == 201)
            #expect(second.head.status.code == 200)
            #expect(server.accepts.count == 1)
        }
    }

    @Test func tls13AndALowerWriteBufferStillComplete() async throws {
        var configuration = uncheckedTLSConfiguration()
        configuration.tls.minimumVersion = .tlsv13
        configuration.tls.maximumVersion = .tlsv13
        configuration.channel.writeBufferLowWaterMark = 32
        configuration.channel.writeBufferHighWaterMark = 64
        try await withTLSClient(mode: .http2, preferred: .http2, configuration: configuration) { client, server in
            let response = try await client.request(
                method: .patch,
                url: server.url("/echo"),
                headers: [:],
                body: Data("patched".utf8)
            )
            #expect(response.head.status.code == 200)
            #expect(FixtureEcho(try #require(response.body)).body == Data("patched".utf8))
        }
    }

    @Test func aClientIdentityIsPresentedWhenRequested() async throws {
        let server = try await TLSFixtureServer.bind(.http2, requireClientCertificate: true)
        let material = LocalTLSMaterial.shared
        var configuration = uncheckedTLSConfiguration()
        configuration.tls.clientIdentity = .init(
            certificateChain: material.clientCertificateChain.map { .certificate($0) },
            privateKey: .privateKey(material.clientPrivateKey)
        )
        configuration.protocols = .prefer(.http2, fallback: [.http1_1])
        let client = HTTPConnection(configuration: configuration)
        do {
            let response = try await client.request(method: .get, url: server.url("/echo"))
            #expect(response.head.status.code == 200)
            await client.shutdown()
            await server.stop()
        } catch {
            await client.shutdown()
            await server.stop()
            throw error
        }
    }

    @Test func fullCertificateVerificationRejectsTheSelfSignedServer() async throws {
        var configuration = HTTPConnection.Configuration()
        configuration.tls.certificateVerification = .fullVerification
        configuration.timeouts.connect = .seconds(3)
        try await withTLSClient(mode: .http2, preferred: .http2, configuration: configuration) { client, server in
            await #expect(throws: Error.self) {
                try await client.request(method: .get, url: server.url("/echo"), headers: [:], body: nil)
            }
            return ()
        }
    }

    @Test func informationalResponsesAndTrailers() async throws {
        try await withTLSClient(mode: .http2, preferred: .http2) { client, server in
            let informational = try await client.request(
                method: .post,
                url: server.url("/informational"),
                headers: [:],
                body: Data("body".utf8)
            )
            #expect(informational.head.status.code == 200)
            #expect(informational.body == Data("final".utf8))

            let trailed = try await client.request(
                method: .get,
                url: server.url("/trailers"),
                headers: [:],
                body: nil
            )
            #expect(trailed.body == Data("trailed".utf8))
            #expect(responseHeader(trailed, "x-trailer") == "yes")
        }
    }

    @Test func cancellingAStreamLeavesTheConnectionUsable() async throws {
        let server = try await TLSFixtureServer.bind(.http2)
        var configuration = uncheckedTLSConfiguration()
        configuration.protocols = .prefer(.http2, fallback: [.http1_1])
        let client = HTTPConnection(configuration: configuration)
        let holdURL = server.url("/hold")
        let task = Task {
            try await client.request(method: .get, url: holdURL, headers: [:], body: nil)
        }
        await server.hold.wait()
        task.cancel()
        #expect(await waitForTask(task, seconds: 5))
        let response = try await client.request(method: .get, url: server.url("/echo"), headers: [:], body: nil)
        #expect(response.head.status.code == 200)
        #expect(server.accepts.count == 1)
        await client.shutdown()
        await server.stop()
    }

    @Test func http1OverTLS() async throws {
        try await withTLSClient(mode: .http1, preferred: .http1_1) { client, server in
            let response = try await client.request(
                method: .post,
                url: server.url("/echo"),
                headers: headerFields(("x-token", "tls")),
                body: Data("one".utf8)
            )
            let echo = FixtureEcho(try #require(response.body))
            #expect(echo.fields["version"] == "1.1")
            #expect(echo.fields["header.x-token"] == "tls")
            #expect(echo.body == Data("one".utf8))
            _ = try await client.request(method: .get, url: server.url("/echo"), headers: [:], body: nil)
            #expect(server.accepts.count == 2)
        }
    }
}
