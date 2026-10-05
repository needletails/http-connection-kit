//
//  ClientTestSupport.swift
//  HTTPConnectionKit
//
//  Created by NeedleTails on 10/5/26.
//

import Foundation
import HTTPConnectionKit
import HTTPTypes
import NIOCore
import NIOHTTP1
import NIOPosix

func uncheckedTLSConfiguration() -> HTTPConnection.Configuration {
    var configuration = HTTPConnection.Configuration()
    configuration.tls.certificateVerification = .none
    return configuration
}

func headerFields(_ pairs: (String, String)...) -> HTTPFields {
    var fields = HTTPFields()
    for (name, value) in pairs {
        fields[HTTPField.Name(name)!] = value
    }
    return fields
}

func responseHeader(_ response: Response, _ name: String) -> String? {
    response.head.headerFields[HTTPField.Name(name)!]
}

@discardableResult
func withClient<T>(
    preferred version: HTTPVersion,
    configuration: HTTPConnection.Configuration = HTTPConnection.Configuration(),
    _ body: (HTTPConnection) async throws -> T
) async throws -> T {
    let client = HTTPConnection(preferred: version, configuration: configuration)
    do {
        let value = try await body(client)
        await client.shutdown()
        return value
    } catch {
        await client.shutdown()
        throw error
    }
}

@discardableResult
func withHTTP1Client<T>(
    preferred version: HTTPVersion = .http1_1,
    configuration: HTTPConnection.Configuration = HTTPConnection.Configuration(),
    _ body: (HTTPConnection, HTTP1FixtureServer) async throws -> T
) async throws -> T {
    let server = try await HTTP1FixtureServer.bind()
    do {
        let value = try await withClient(preferred: version, configuration: configuration) { client in
            try await body(client, server)
        }
        await server.stop()
        return value
    } catch {
        await server.stop()
        throw error
    }
}

@discardableResult
func withTLSClient<T>(
    mode: TLSFixtureServer.Mode,
    preferred version: HTTPVersion,
    configuration: HTTPConnection.Configuration = uncheckedTLSConfiguration(),
    _ body: (HTTPConnection, TLSFixtureServer) async throws -> T
) async throws -> T {
    let server = try await TLSFixtureServer.bind(mode)
    do {
        let value = try await withClient(preferred: version, configuration: configuration) { client in
            try await body(client, server)
        }
        await server.stop()
        return value
    } catch {
        await server.stop()
        throw error
    }
}

@available(anyAppleOS 26, *)
@discardableResult
func withHTTP3Client<T>(
    configuration: HTTPConnection.Configuration = uncheckedTLSConfiguration(),
    _ body: (HTTPConnection, HTTP3FixtureServer) async throws -> T
) async throws -> T {
    var configuration = configuration
    if configuration.channel.quicIdleTimeout.nanoseconds == HTTPConnection.Configuration().channel.quicIdleTimeout.nanoseconds {
        configuration.channel.quicIdleTimeout = .seconds(10)
    }
    let server = try await HTTP3FixtureServer.bind()
    do {
        let value = try await withClient(preferred: .http3, configuration: configuration) { client in
            try await body(client, server)
        }
        await server.stop()
        return value
    } catch {
        await server.stop()
        throw error
    }
}

/// Opens a TCP connection with NIO, independent of `HTTPConnection`, so a public-server test can tell
/// "the network is down" from "the client failed".
func tcpPortOpen(host: String, port: Int) async -> Bool {
    do {
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(3))
            .connect(host: host, port: port)
            .get()
        try? await channel.close().get()
        return true
    } catch {
        return false
    }
}
