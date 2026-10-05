//
//  HTTPConnectionConfiguration.swift
//  HTTPConnectionKit
//
//  Created by NeedleTails on 10/5/26.
//

import Foundation
import NIOQUIC
import NIOSSL
#if canImport(Network)
import Network
import Security
#endif

extension HTTPConnection {
    /// Channel and TLS settings for every connection this client opens.
    ///
    /// Protocol selection stays with the preferred version and the handshake. These settings change
    /// how that connection is established.
    public struct Configuration: Sendable {
        public var tls: TLS
        public var channel: Channel

        public init(tls: TLS = TLS(), channel: Channel = Channel()) {
            self.tls = tls
            self.channel = channel
        }

        /// TLS bounds and certificate checking for TCP and QUIC.
        public struct TLS: Sendable {
            /// Lowest TLS version offered on TCP. QUIC always uses TLS 1.3.
            public var minimumVersion: Version
            /// How the peer certificate is checked on TCP and QUIC.
            public var certificateVerification: CertificateVerification

            public init(
                minimumVersion: Version = .tlsv12,
                certificateVerification: CertificateVerification = .fullVerification
            ) {
                self.minimumVersion = minimumVersion
                self.certificateVerification = certificateVerification
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
            /// How long a TCP or NIOTS connect may take before it fails.
            public var connectTimeout: Interval
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
            public var quicIdleTimeout: Interval

            public init(
                connectTimeout: Interval = .seconds(10),
                tcpNoDelay: Bool = true,
                keepAlive: Bool = true,
                reuseLocalEndpoint: Bool = true,
                writeBufferLowWaterMark: Int = 32 * 1024,
                writeBufferHighWaterMark: Int = 256 * 1024,
                maximumReceiveLength: Int = 65_535,
                udpBufferBytes: Int = 1 << 21,
                quicIdleTimeout: Interval = .seconds(30)
            ) {
                self.connectTimeout = connectTimeout
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

        /// A length of time, in whole nanoseconds.
        public struct Interval: Sendable {
            public var nanoseconds: Int64

            public init(nanoseconds: Int64) {
                self.nanoseconds = nanoseconds
            }

            public static func seconds(_ seconds: Int) -> Self {
                Self(nanoseconds: Int64(seconds) * 1_000_000_000)
            }

            public static func milliseconds(_ milliseconds: Int) -> Self {
                Self(nanoseconds: Int64(milliseconds) * 1_000_000)
            }
        }
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
