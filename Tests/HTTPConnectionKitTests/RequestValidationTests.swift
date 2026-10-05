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
        #expect(configuration.tls.minimumVersion == .tlsv12)
        #expect(configuration.tls.certificateVerification == .fullVerification)
        #expect(configuration.channel.connectTimeout.nanoseconds == 10_000_000_000)
        #expect(configuration.channel.tcpNoDelay)
        #expect(configuration.channel.keepAlive)
        #expect(configuration.channel.reuseLocalEndpoint)
        #expect(configuration.channel.writeBufferLowWaterMark == 32 * 1024)
        #expect(configuration.channel.writeBufferHighWaterMark == 256 * 1024)
        #expect(configuration.channel.maximumReceiveLength == 65_535)
        #expect(configuration.channel.udpBufferBytes == 1 << 21)
        #expect(configuration.channel.quicIdleTimeout.nanoseconds == 30_000_000_000)
        #expect(configuration.followRedirects)
        #expect(configuration.maximumRedirects == 8)
        #expect(configuration.decompressResponses)
        #expect(configuration.decompressionRatioLimit == 100)
        #expect(configuration.expectContinueTimeout.nanoseconds == 1_000_000_000)
        #expect(configuration.authentication == nil)
        #expect(configuration.proxyAuthentication == nil)
        #expect(configuration.authenticationRefreshWindow.maximumAttempts == 5)
        #expect(configuration.maximumBufferedBodySize == 64 * 1024 * 1024)
        #expect(configuration.requestTimeout?.nanoseconds == 60_000_000_000)
        #expect(configuration.onProgress == nil)
        #expect(HTTPConnection.Configuration.Interval.seconds(2).nanoseconds == 2_000_000_000)
        #expect(HTTPConnection.Configuration.Interval.milliseconds(5).nanoseconds == 5_000_000)
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
        let client = HTTPConnection(preferred: .http1_1)
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
        configuration.channel.connectTimeout = .milliseconds(500)
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
}
