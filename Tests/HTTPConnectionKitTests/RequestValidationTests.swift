//
//  RequestValidationTests.swift
//  HTTPConnectionKit
//
//  Created by NeedleTails on 10/5/26.
//

import Foundation
import HTTPConnectionKit
import HTTPTypes
import Testing

@Suite("Request validation and configuration")
struct RequestValidationTests {
    @Test func configurationDefaultsMatchTheClient() {
        let configuration = HTTPConnection.Configuration()
        #expect(configuration.protocols == .default)
        #expect(configuration.tls.minimumVersion == .tlsv12)
        #expect(configuration.tls.certificateVerification == .fullVerification)
        #expect(configuration.timeouts.connect == .seconds(10))
        #expect(configuration.channel.tcpNoDelay)
        #expect(configuration.channel.keepAlive)
        #expect(configuration.channel.reuseLocalEndpoint)
        #expect(configuration.channel.writeBufferLowWaterMark == 32 * 1024)
        #expect(configuration.channel.writeBufferHighWaterMark == 256 * 1024)
        #expect(configuration.channel.maximumReceiveLength == 65_535)
        #expect(configuration.channel.udpBufferBytes == 1 << 21)
        #expect(configuration.channel.quicIdleTimeout == .seconds(30))
        #expect(configuration.redirects == .follow(maximum: 8))
        #expect(configuration.decompression == .enabled(ratioLimit: 100))
        #expect(configuration.timeouts.expectContinue == .seconds(1))
        #expect(configuration.authentication == nil)
        #expect(configuration.authenticationRefreshWindow.maximumAttempts == 5)
        #expect(configuration.maximumBufferedBodySize == 64 * 1024 * 1024)
        #expect(configuration.timeouts.request == .seconds(60))
    }

    @Test func requestDefaultsNeedOnlyAMethodAndURL() async throws {
        try await withHTTP1Client { client, server in
            let response = try await client.request(method: .get, url: server.url("/echo"))
            #expect(response.head.status.code == 200)
        }
    }

    @Test func anHTTPRequestRoundTrips() async throws {
        try await withHTTP1Client { client, server in
            let url = server.url("/echo")
            let request = HTTPRequest(
                method: .get,
                scheme: "http",
                authority: "\(url.host!):\(url.port!)",
                path: "/echo"
            )
            let response = try await client.request(request)
            #expect(response.head.status.code == 200)
        }
    }

    @Test func anHTTPRequestRequiresAnAuthority() async {
        var configuration = HTTPConnection.Configuration()
        configuration.protocols = .prefer(.http1_1, fallback: [])
        let client = HTTPConnection(configuration: configuration)
        let request = HTTPRequest(method: .get, scheme: "http", authority: nil, path: "/")
        await #expect(throws: HTTPConnectionError.invalidRequest) {
            try await client.request(request)
        }
        await client.shutdown()
    }

    @Test func connectIsRejectedBeforeAConnectionOpens() async {
        await #expect(throws: HTTPConnectionError.unimplemented) {
            try await withClient(preferred: .http1_1) { client in
                try await client.request(
                    method: .connect,
                    url: URL(string: "https://example.com/")!,
                    headers: [:],
                    body: nil
                )
            }
        }
    }

    @Test func unsupportedSchemesAreRejected() async {
        await #expect(throws: HTTPConnectionError.invalidRequest) {
            try await withClient(preferred: .http1_1) { client in
                try await client.request(
                    method: .get,
                    url: URL(string: "ftp://example.com/file")!,
                    headers: [:],
                    body: nil
                )
            }
        }
    }

    @Test func aURLWithoutAHostIsRejected() async {
        await #expect(throws: HTTPConnectionError.invalidRequest) {
            try await withClient(preferred: .http1_1) { client in
                try await client.request(
                    method: .get,
                    url: URL(string: "http:///missing-host")!,
                    headers: [:],
                    body: nil
                )
            }
        }
    }

    @Test func aClosedPortFailsTheRequest() async throws {
        var configuration = HTTPConnection.Configuration()
        configuration.timeouts.connect = .milliseconds(500)
        try await withClient(preferred: .http1_1, configuration: configuration) { client in
            await #expect(throws: Error.self) {
                try await client.request(
                    method: .get,
                    url: URL(string: "http://127.0.0.1:1/")!,
                    headers: [:],
                    body: nil
                )
            }
            return ()
        }
    }

    @Test func invalidConfigurationRelationshipsAreReported() {
        var configuration = HTTPConnection.Configuration()
        configuration.tls.minimumVersion = .tlsv13
        configuration.tls.maximumVersion = .tlsv12
        #expect(throws: HTTPConnection.Configuration.ValidationError.invalidTLSVersionRange) {
            try configuration.validate()
        }

        configuration = HTTPConnection.Configuration()
        configuration.protocols = .prefer(.http3, fallback: [.http1_1])
        #expect(throws: HTTPConnection.Configuration.ValidationError.invalidProtocolFallback) {
            try configuration.validate()
        }

        configuration = HTTPConnection.Configuration()
        configuration.decompression = .enabled(ratioLimit: 0)
        #expect(throws: HTTPConnection.Configuration.ValidationError.invalidDecompressionRatio) {
            try configuration.validate()
        }
    }

    @Test func aRequiredProtocolRejectsAFallback() async throws {
        let server = try await HTTP1FixtureServer.bind()
        var configuration = HTTPConnection.Configuration()
        configuration.protocols = .require(.http2)
        let client = HTTPConnection(configuration: configuration)
        await #expect(throws: HTTPConnectionError.protocolNegotiationFailed) {
            try await client.request(method: .get, url: server.url("/echo"))
        }
        await client.shutdown()
        await server.stop()
    }
}
