//
//  PublicServerTests.swift
//  HTTPConnectionKit
//
//  Created by NeedleTails on 10/5/26.
//

import Foundation
import HTTPConnectionKit
import NIOHTTP1
import Testing

/// Requests against hosts on the public internet.
///
/// The test fails with a clear message when that host's TCP port is closed. HTTP/3 records a warning
/// and still passes when the handshake falls back to TCP; the local QUIC server covers that path.
@Suite("Public HTTPS servers")
struct PublicServerTests {
    @Test func exampleDomainOverTLS13() async throws {
        try await requireTCP(host: "example.com")
        var configuration = HTTPConnection.Configuration()
        configuration.tls.minimumVersion = .tlsv13
        try await withClient(preferred: .http2, configuration: configuration) { client in
            let response = try await client.request(
                method: .get,
                url: URL(string: "https://example.com/")!,
                headers: [:],
                body: nil
            )
            #expect(response.head.status.code == 200)
            let page = String(decoding: try #require(response.body), as: UTF8.self)
            #expect(page.contains("Example Domain"))
        }
    }

    @Test func cloudflareTraceUsesHTTP1WhenThatIsTheCap() async throws {
        let body = try await cloudflareTrace(preferred: .http1_1)
        #expect(traceField("http", in: body) == "http/1.1")
    }

    @Test func cloudflareTraceUsesHTTP2WhenThatIsTheCap() async throws {
        let body = try await cloudflareTrace(preferred: .http2)
        #expect(traceField("http", in: body) == "http/2")
    }

    @Test func cloudflareTraceUsesHTTP3WhenQUICConnects() async throws {
        let body = try await cloudflareTrace(preferred: .http3, quicIdleTimeout: .seconds(8))
        let http = traceField("http", in: body)
        if http == "http/2" {
            Issue.record("QUIC did not connect; the client used TCP", severity: .warning)
        }
        #expect(http == "http/3" || http == "http/2")
    }

    private func cloudflareTrace(
        preferred version: HTTPVersion,
        quicIdleTimeout: HTTPConnection.Configuration.Interval? = nil
    ) async throws -> String {
        try await requireTCP(host: "cloudflare.com")
        var configuration = HTTPConnection.Configuration()
        configuration.tls.minimumVersion = .tlsv13
        if let quicIdleTimeout {
            configuration.channel.quicIdleTimeout = quicIdleTimeout
        }
        return try await withClient(preferred: version, configuration: configuration) { client in
            let response = try await client.request(
                method: .get,
                url: URL(string: "https://cloudflare.com/cdn-cgi/trace")!,
                headers: [:],
                body: nil
            )
            #expect(response.head.status.code == 200)
            return String(decoding: try #require(response.body), as: UTF8.self)
        }
    }

    private func requireTCP(host: String) async throws {
        try #require(await tcpPortOpen(host: host, port: 443), "\(host):443 is not reachable")
    }

    private func traceField(_ name: String, in body: String) -> String? {
        for line in body.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0] == Substring(name) {
                return String(parts[1])
            }
        }
        return nil
    }
}
