//
//  ConnectionModels.swift
//  HTTPConnectionKit
//
//  Created by NeedleTails on 10/5/26.
//

import NIOCore
import NIOHTTP1

/// The parts of a URL the transport needs. The path includes the query string.
struct RequestComponents: Sendable {
    var scheme: String
    var host: String
    var port: Int
    var path: String
    var authority: String
    var enableTLS: Bool
}

/// Identity of one pooled connection. The version is the protocol the handshake selected.
struct ConnectionKey: Hashable, Sendable {
    var host: String
    var port: Int
    var enableTLS: Bool
    var major: Int
    var minor: Int

    init(components: RequestComponents, version: HTTPVersion) {
        self.host = components.host
        self.port = components.port
        self.enableTLS = components.enableTLS
        self.major = version.major
        self.minor = version.minor
    }
}

/// An open multiplexed connection kept for later requests.
struct LiveConnection: Sendable {
    var key: ConnectionKey
    var channel: Channel

    var negotiatedVersion: HTTPVersion {
        HTTPVersion(major: key.major, minor: key.minor)
    }
}

/// An origin whose QUIC handshake failed while TCP succeeded.
struct Origin: Hashable, Sendable {
    var host: String
    var port: Int
    var enableTLS: Bool

    init(_ components: RequestComponents) {
        self.host = components.host
        self.port = components.port
        self.enableTLS = components.enableTLS
    }
}
