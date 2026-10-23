//
//  AddressFilterTests.swift
//  HTTPConnectionKit
//

import Foundation
import HTTPConnectionKit
import NIOCore
import Testing

@Suite("Address filter")
struct AddressFilterTests {
    static let blocked: [String] = [
        // IPv4 special-purpose ranges.
        "0.0.0.0", "0.1.2.3", "10.0.0.1", "10.255.255.255", "100.64.0.1", "100.127.255.254",
        "127.0.0.1", "127.255.255.254", "169.254.169.254", "172.16.0.1", "172.31.255.255",
        "192.0.0.1", "192.0.2.1", "192.31.196.1", "192.52.193.1", "192.88.99.1", "192.168.0.1",
        "192.175.48.1", "198.18.0.1", "198.19.255.255", "198.51.100.1", "203.0.113.1", "224.0.0.1",
        "239.255.255.255", "240.0.0.1", "255.255.255.255",
        // IPv6 special-purpose ranges.
        "::", "::1", "::ffff:127.0.0.1", "::ffff:10.0.0.1", "::ffff:169.254.169.254",
        "64:ff9b::7f00:1", "64:ff9b::a00:1", "64:ff9b:1::1", "100::1", "2001::1", "2001:2::1",
        "2001:db8::1", "2002:808:808::1", "2620:4f:8000::1", "3fff::1", "5f00::1", "fc00::1",
        "fd12:3456::1", "fe80::1", "fec0::1", "ff02::1",
    ]

    static let allowed: [String] = [
        "1.1.1.1", "8.8.8.8", "93.184.216.34", "172.32.0.1", "172.15.255.255", "192.169.0.1",
        "100.128.0.1", "198.20.0.1", "2606:4700:4700::1111", "2a00:1450:4001::200e",
        "::ffff:8.8.8.8", "64:ff9b::808:808",
    ]

    @Test(arguments: blocked)
    func publicInternetOnlyRefusesSpecialPurposeAddresses(_ ip: String) throws {
        let address = try SocketAddress(ipAddress: ip, port: 443)
        #expect(!HTTPConnection.Configuration.AddressFilter.publicInternetOnly.allows(address))
    }

    @Test(arguments: allowed)
    func publicInternetOnlyAllowsPublicAddresses(_ ip: String) throws {
        let address = try SocketAddress(ipAddress: ip, port: 443)
        #expect(HTTPConnection.Configuration.AddressFilter.publicInternetOnly.allows(address))
    }

    @Test func publicInternetOnlyRefusesUnixDomainSockets() throws {
        let address = try SocketAddress(unixDomainSocketPath: "/tmp/hck-filter.sock")
        #expect(!HTTPConnection.Configuration.AddressFilter.publicInternetOnly.allows(address))
    }

    @Test func refusedLiteralAddressNeverConnects() async throws {
        var configuration = HTTPConnection.Configuration()
        configuration.addressFilter = .publicInternetOnly
        try await withHTTP1Client(configuration: configuration) { client, server in
            await #expect(throws: HTTPConnectionError.addressNotAllowed) {
                _ = try await client.request(method: .get, url: server.url("/echo"), headers: [:], body: nil)
            }
            #expect(server.accepts.count == 0)
        }
    }

    @Test func refusedHostnameNeverConnects() async throws {
        var configuration = HTTPConnection.Configuration()
        configuration.addressFilter = .publicInternetOnly
        try await withHTTP1Client(configuration: configuration) { client, server in
            let url = URL(string: "http://localhost:\(server.port)/echo")!
            await #expect(throws: HTTPConnectionError.addressNotAllowed) {
                _ = try await client.request(method: .get, url: url, headers: [:], body: nil)
            }
            #expect(server.accepts.count == 0)
        }
    }

    @Test func anyRefusedAddressFailsTheWholeHost() async throws {
        // `localhost` resolves to 127.0.0.1 and usually ::1; refusing only ::1 must still refuse the host.
        var configuration = HTTPConnection.Configuration()
        configuration.addressFilter = .init { $0.ipAddress != "::1" }
        guard Self.localhostHasIPv6() else { return }
        try await withHTTP1Client(configuration: configuration) { client, server in
            let url = URL(string: "http://localhost:\(server.port)/echo")!
            await #expect(throws: HTTPConnectionError.addressNotAllowed) {
                _ = try await client.request(method: .get, url: url, headers: [:], body: nil)
            }
            #expect(server.accepts.count == 0)
        }
    }

    @Test func allowedHostnameConnectsThroughPinnedAddresses() async throws {
        var configuration = HTTPConnection.Configuration()
        configuration.addressFilter = Self.loopbackOnly
        try await withHTTP1Client(configuration: configuration) { client, server in
            let url = URL(string: "http://localhost:\(server.port)/echo")!
            let response = try await client.request(method: .get, url: url, headers: [:], body: nil)
            #expect(response.head.status.code == 200)
            #expect(server.accepts.count == 1)
        }
    }

    @Test func filterIsCheckedAgainOnEveryRedirect() async throws {
        let origin = try await HTTP1FixtureServer.bind()
        let target = try await HTTP1FixtureServer.bind()
        var configuration = HTTPConnection.Configuration()
        let originPort = origin.port
        configuration.addressFilter = .init { $0.port == originPort }
        do {
            try await withClient(preferred: .http1_1, configuration: configuration) { client in
                let url = origin.url("/redirect/302?to=http://127.0.0.1:\(target.port)/echo")
                await #expect(throws: HTTPConnectionError.addressNotAllowed) {
                    _ = try await client.request(method: .get, url: url, headers: [:], body: nil)
                }
            }
            #expect(origin.accepts.count == 1)
            #expect(target.accepts.count == 0)
        } catch {
            await origin.stop()
            await target.stop()
            throw error
        }
        await origin.stop()
        await target.stop()
    }

    @Test func pinnedTLSStillNegotiatesHTTP2() async throws {
        var configuration = uncheckedTLSConfiguration()
        configuration.addressFilter = Self.loopbackOnly
        try await withTLSClient(mode: .http2, preferred: .http2, configuration: configuration) { client, server in
            let response = try await client.request(method: .get, url: server.url("/echo"), headers: [:], body: nil)
            #expect(response.head.status.code == 200)
            #expect(server.http2Connections.active.count == 1)
        }
    }

    @Test func refusedAddressIsNotTriedOverTLS() async throws {
        var configuration = uncheckedTLSConfiguration()
        configuration.addressFilter = .publicInternetOnly
        try await withTLSClient(mode: .http2, preferred: .http2, configuration: configuration) { client, server in
            await #expect(throws: HTTPConnectionError.addressNotAllowed) {
                _ = try await client.request(method: .get, url: server.url("/echo"), headers: [:], body: nil)
            }
            #expect(server.accepts.count == 0)
        }
    }

    @Test func refusedAddressIsNotTriedOverQUIC() async throws {
        guard #available(anyAppleOS 26, *) else { return }
        var configuration = uncheckedTLSConfiguration()
        configuration.addressFilter = .publicInternetOnly
        try await withHTTP3Client(configuration: configuration) { client, server in
            await #expect(throws: HTTPConnectionError.addressNotAllowed) {
                _ = try await client.request(method: .get, url: server.url("/echo"), headers: [:], body: nil)
            }
            #expect(server.accepts.count == 0)
        }
    }

    @Test func allowedAddressStillUsesQUIC() async throws {
        guard #available(anyAppleOS 26, *) else { return }
        var configuration = uncheckedTLSConfiguration()
        configuration.addressFilter = Self.loopbackOnly
        try await withHTTP3Client(configuration: configuration) { client, server in
            let response = try await client.request(method: .get, url: server.url("/echo"), headers: [:], body: nil)
            #expect(response.head.status.code == 200)
            #expect(server.accepts.count == 1)
        }
    }

    static let loopbackOnly = HTTPConnection.Configuration.AddressFilter { address in
        address.ipAddress == "127.0.0.1" || address.ipAddress == "::1"
    }

    static func localhostHasIPv6() -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_INET6
        var result: UnsafeMutablePointer<addrinfo>?
        defer { if let result { freeaddrinfo(result) } }
        return getaddrinfo("localhost", nil, &hints, &result) == 0 && result != nil
    }
}
