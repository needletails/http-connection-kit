//
//  HTTPConnectionConfiguration.swift
//  HTTPConnectionKit
//
//  Created by NeedleTails on 10/5/26.
//

import Foundation
import NIOHTTP1
import NIOQUIC
import NIOSSL
#if canImport(Network)
import Network
import Security
#endif

extension HTTPConnection {
    /// Behavior that belongs to one request rather than every request sent by a connection.
    public struct RequestOptions: Sendable {
        /// Nil uses `Configuration.timeouts.request`.
        public var timeout: Duration?
        /// Receives upload and download progress for this request only.
        public var onProgress: (@Sendable (HTTPProgress) -> Void)?

        public init(
            timeout: Duration? = nil,
            onProgress: (@Sendable (HTTPProgress) -> Void)? = nil
        ) {
            self.timeout = timeout
            self.onProgress = onProgress
        }
    }

    /// Channel and TLS settings for every connection this client opens.
    ///
    /// Protocol selection stays with the preferred version and the handshake. These settings change
    /// how that connection is established.
    public struct Configuration: Sendable {
        public var protocols: ProtocolPolicy
        public var tls: TLS
        public var channel: Channel
        public var timeouts: Timeouts
        public var redirects: RedirectPolicy
        public var decompression: DecompressionPolicy
        public var pool: Pool
        public var cookieJar: CookieJar
        public var authentication: (any HTTPAuthenticationProvider)?
        public var authenticationRefreshWindow: HTTPAuthenticationRefreshWindow
        public var maximumBufferedBodySize: Int

        public init(
            protocols: ProtocolPolicy = .default,
            tls: TLS = TLS(),
            channel: Channel = Channel(),
            timeouts: Timeouts = Timeouts(),
            redirects: RedirectPolicy = .follow(maximum: 8),
            decompression: DecompressionPolicy = .enabled(ratioLimit: 100),
            pool: Pool = Pool(),
            cookieJar: CookieJar = CookieJar(),
            authentication: (any HTTPAuthenticationProvider)? = nil,
            authenticationRefreshWindow: HTTPAuthenticationRefreshWindow = HTTPAuthenticationRefreshWindow(),
            maximumBufferedBodySize: Int = 64 * 1024 * 1024
        ) {
            self.protocols = protocols
            self.tls = tls
            self.channel = channel
            self.timeouts = timeouts
            self.redirects = redirects
            self.decompression = decompression
            self.pool = pool
            self.cookieJar = cookieJar
            self.authentication = authentication
            self.authenticationRefreshWindow = authenticationRefreshWindow
            self.maximumBufferedBodySize = maximumBufferedBodySize
        }

        public enum ProtocolVersion: Sendable, Equatable {
            case http1_0
            case http1_1
            case http2
            case http3
        }

        public enum ProtocolPolicy: Sendable, Equatable {
            case prefer(ProtocolVersion, fallback: [ProtocolVersion])
            case require(ProtocolVersion)

            public static let `default`: Self = .prefer(.http3, fallback: [.http2, .http1_1])
        }

        public struct Timeouts: Sendable, Equatable {
            public var connect: Duration
            public var request: Duration?
            public var expectContinue: Duration

            public init(
                connect: Duration = .seconds(10),
                request: Duration? = .seconds(60),
                expectContinue: Duration = .seconds(1)
            ) {
                self.connect = connect
                self.request = request
                self.expectContinue = expectContinue
            }
        }

        public enum RedirectPolicy: Sendable, Equatable {
            case disabled
            case follow(maximum: Int)
        }

        public enum DecompressionPolicy: Sendable, Equatable {
            case disabled
            case enabled(ratioLimit: Int)
        }

        public struct Pool: Sendable, Equatable {
            public var idleTimeout: Duration?

            public init(idleTimeout: Duration? = nil) {
                self.idleTimeout = idleTimeout
            }
        }

        /// TLS bounds and certificate checking for TCP and QUIC.
        public struct TLS: Sendable {
            /// Lowest TLS version offered on TCP. QUIC always uses TLS 1.3.
            public var minimumVersion: Version
            /// Highest TLS version offered on TCP. Nil uses the transport default.
            public var maximumVersion: Version?
            /// How the peer certificate is checked on TCP and QUIC.
            public var certificateVerification: CertificateVerification
            /// Additional trust roots. Custom roots use the NIOSSL TCP transport.
            public var trustRoots: TrustRoots
            /// Certificate and private key presented to servers requesting mutual TLS.
            ///
            /// Client identities use the NIOSSL TCP transport. QUIC client identities are not
            /// currently supported.
            public var clientIdentity: ClientIdentity?

            public init(
                minimumVersion: Version = .tlsv12,
                maximumVersion: Version? = nil,
                certificateVerification: CertificateVerification = .fullVerification,
                trustRoots: TrustRoots = .systemDefault,
                clientIdentity: ClientIdentity? = nil
            ) {
                self.minimumVersion = minimumVersion
                self.maximumVersion = maximumVersion
                self.certificateVerification = certificateVerification
                self.trustRoots = trustRoots
                self.clientIdentity = clientIdentity
            }

            public struct TrustRoots: Sendable {
                package var certificates: [NIOSSLCertificate]?

                private init(certificates: [NIOSSLCertificate]?) {
                    self.certificates = certificates
                }

                public static let systemDefault = Self(certificates: nil)

                public static func pem(_ data: Data) throws -> Self {
                    Self(certificates: try NIOSSLCertificate.fromPEMBytes(Array(data)))
                }

                public static func pemFile(_ path: String) throws -> Self {
                    Self(certificates: try NIOSSLCertificate.fromPEMFile(path))
                }

                package var usesSystemDefault: Bool {
                    certificates == nil
                }
            }

            public struct ClientIdentity: Sendable {
                public var certificateChain: [NIOSSLCertificateSource]
                public var privateKey: NIOSSLPrivateKeySource

                public init(
                    certificateChain: [NIOSSLCertificateSource],
                    privateKey: NIOSSLPrivateKeySource
                ) {
                    self.certificateChain = certificateChain
                    self.privateKey = privateKey
                }

                /// Loads a PEM file containing the client certificate chain and private key.
                public static func pemFile(_ path: String) throws -> Self {
                    let certificates = try NIOSSLCertificate.fromPEMFile(path)
                        .map(NIOSSLCertificateSource.certificate)
                    let privateKey = try NIOSSLPrivateKey(file: path, format: .pem)
                    return Self(
                        certificateChain: certificates,
                        privateKey: .privateKey(privateKey)
                    )
                }

                /// Loads a PEM certificate chain and private key without exposing NIOSSL source types.
                public static func pem(certificateChain: Data, privateKey: Data) throws -> Self {
                    let certificates = try NIOSSLCertificate.fromPEMBytes(Array(certificateChain))
                        .map(NIOSSLCertificateSource.certificate)
                    let privateKey = try NIOSSLPrivateKey(bytes: Array(privateKey), format: .pem)
                    return Self(
                        certificateChain: certificates,
                        privateKey: .privateKey(privateKey)
                    )
                }
            }

            /// TLS versions this client is willing to offer on TCP.
            public enum Version: Sendable {
                case tlsv12
                case tlsv13
            }

            /// Peer-certificate policy shared by the TCP and QUIC stacks.
            public enum CertificateVerification: Sendable {
                /// Trust store and hostname must both match.
                case fullVerification
                /// Trust store must match. The hostname is not compared to the certificate.
                case noHostnameVerification
                /// The peer certificate is not checked.
                case none
            }
        }

        /// Socket and buffer settings applied when a connection is opened.
        public struct Channel: Sendable {
            /// Sends application writes without waiting to fill a segment.
            public var tcpNoDelay: Bool
            /// Asks the kernel to probe an idle TCP connection.
            public var keepAlive: Bool
            /// Allows another socket to bind the local address after this one closes.
            public var reuseLocalEndpoint: Bool
            /// Outbound write buffer resumes at this size.
            public var writeBufferLowWaterMark: Int
            /// Outbound writes wait once the buffer reaches this size.
            public var writeBufferHighWaterMark: Int
            /// Largest datagram accepted on a connection. QUIC drops packets larger than this. The default is 65535.
            public var maximumReceiveLength: Int
            /// Send and receive buffer size for the UDP socket under a QUIC connection.
            public var udpBufferBytes: Int
            /// Closes a QUIC connection that receives nothing for this long.
            public var quicIdleTimeout: Duration

            public init(
                tcpNoDelay: Bool = true,
                keepAlive: Bool = true,
                reuseLocalEndpoint: Bool = true,
                writeBufferLowWaterMark: Int = 32 * 1024,
                writeBufferHighWaterMark: Int = 256 * 1024,
                maximumReceiveLength: Int = 65_535,
                udpBufferBytes: Int = 1 << 21,
                quicIdleTimeout: Duration = .seconds(30)
            ) {
                self.tcpNoDelay = tcpNoDelay
                self.keepAlive = keepAlive
                self.reuseLocalEndpoint = reuseLocalEndpoint
                self.writeBufferLowWaterMark = writeBufferLowWaterMark
                self.writeBufferHighWaterMark = writeBufferHighWaterMark
                self.maximumReceiveLength = maximumReceiveLength
                self.udpBufferBytes = udpBufferBytes
                self.quicIdleTimeout = quicIdleTimeout
            }
        }
    }
}

extension HTTPConnection.Configuration {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidProtocolFallback
        case invalidTLSVersionRange
        case invalidTimeout
        case invalidRedirectLimit
        case invalidDecompressionRatio
        case invalidBufferedBodySize
        case invalidWriteBufferWaterMarks
        case invalidReceiveBufferSize
        case unsupportedHTTP3TLSConfiguration
    }

    /// Checks relationships and ranges that cannot be represented by individual property types.
    public func validate() throws(ValidationError) {
        if case .prefer(let preferred, let fallback) = protocols {
            let expected: [ProtocolVersion]
            switch preferred {
            case .http3:
                expected = [.http2, .http1_1]
            case .http2:
                expected = [.http1_1]
            case .http1_1, .http1_0:
                expected = []
            }
            guard fallback == expected else {
                throw .invalidProtocolFallback
            }
        }
        if let maximum = tls.maximumVersion, tls.minimumVersion.rank > maximum.rank {
            throw .invalidTLSVersionRange
        }
        if protocols.requiredVersion == .http3,
           tls.clientIdentity != nil || !tls.trustRoots.usesSystemDefault
        {
            throw .unsupportedHTTP3TLSConfiguration
        }
        guard timeouts.connect.isPositive,
              timeouts.request?.isPositive ?? true,
              timeouts.expectContinue.isPositive,
              channel.quicIdleTimeout.isPositive,
              pool.idleTimeout?.isPositive ?? true
        else {
            throw .invalidTimeout
        }
        if case .follow(let maximum) = redirects, maximum < 0 {
            throw .invalidRedirectLimit
        }
        if case .enabled(let ratioLimit) = decompression, ratioLimit < 1 {
            throw .invalidDecompressionRatio
        }
        guard maximumBufferedBodySize >= 0 else {
            throw .invalidBufferedBodySize
        }
        guard channel.writeBufferLowWaterMark >= 0,
              channel.writeBufferHighWaterMark >= channel.writeBufferLowWaterMark
        else {
            throw .invalidWriteBufferWaterMarks
        }
        guard channel.maximumReceiveLength > 0, channel.udpBufferBytes > 0 else {
            throw .invalidReceiveBufferSize
        }
    }
}

extension HTTPConnection.Configuration.ProtocolVersion {
    var rank: Int {
        switch self {
        case .http1_0: 10
        case .http1_1: 11
        case .http2: 20
        case .http3: 30
        }
    }

    var nio: HTTPVersion {
        switch self {
        case .http1_0: .http1_0
        case .http1_1: .http1_1
        case .http2: .http2
        case .http3: .http3
        }
    }
}

extension HTTPConnection.Configuration.ProtocolPolicy {
    var preferredVersion: HTTPConnection.Configuration.ProtocolVersion {
        switch self {
        case .prefer(let version, _), .require(let version):
            version
        }
    }

    var requiredVersion: HTTPConnection.Configuration.ProtocolVersion? {
        if case .require(let version) = self { version } else { nil }
    }
}

extension HTTPConnection.Configuration.RedirectPolicy {
    var follows: Bool {
        if case .follow = self { true } else { false }
    }

    var maximum: Int {
        if case .follow(let maximum) = self { maximum } else { 0 }
    }
}

extension HTTPConnection.Configuration.DecompressionPolicy {
    var isEnabled: Bool {
        if case .enabled = self { true } else { false }
    }

    var ratioLimit: Int {
        if case .enabled(let ratioLimit) = self { ratioLimit } else { 1 }
    }
}

extension HTTPConnection.Configuration.TLS.Version {
    var rank: Int {
        switch self {
        case .tlsv12: 12
        case .tlsv13: 13
        }
    }
}

extension Duration {
    var httpConnectionNanoseconds: Int64 {
        let components = self.components
        let seconds = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if seconds.overflow {
            return components.seconds.signum() >= 0 ? .max : .min
        }
        let attoseconds = components.attoseconds / 1_000_000_000
        let total = seconds.partialValue.addingReportingOverflow(attoseconds)
        if total.overflow {
            return seconds.partialValue >= 0 ? .max : .min
        }
        return total.partialValue
    }

    var isPositive: Bool {
        httpConnectionNanoseconds > 0
    }
}

extension HTTPConnection.Configuration.TLS.Version {
    var niossl: TLSVersion {
        switch self {
        case .tlsv12:
            .tlsv12
        case .tlsv13:
            .tlsv13
        }
    }

    #if canImport(Network)
    var nw: tls_protocol_version_t {
        switch self {
        case .tlsv12:
            .TLSv12
        case .tlsv13:
            .TLSv13
        }
    }
    #endif
}

extension HTTPConnection.Configuration.TLS.CertificateVerification {
    var niossl: NIOSSL.CertificateVerification {
        switch self {
        case .fullVerification:
            .fullVerification
        case .noHostnameVerification:
            .noHostnameVerification
        case .none:
            .none
        }
    }

    /// QUIC has no separate "skip certificates" mode. `.none` maps to no verification.
    @available(anyAppleOS 26, *)
    var quic: NIOQUIC.CertificateVerification {
        switch self {
        case .fullVerification:
            .fullVerification
        case .noHostnameVerification:
            .noHostnameVerification
        case .none:
            .noVerification
        }
    }
}
