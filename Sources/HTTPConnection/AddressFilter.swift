//
//  AddressFilter.swift
//  HTTPConnectionKit
//

import NIOCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

extension HTTPConnection.Configuration {
    /// Decides which resolved addresses the client may connect to.
    ///
    /// With a filter set, the client resolves each host itself, refuses the host when **any** of its
    /// addresses is refused, and then connects only to the addresses it checked. The check therefore
    /// can't be bypassed by DNS answering differently between the check and the connection, and it
    /// applies to every connection the client opens, including redirect targets, over TCP and QUIC.
    public struct AddressFilter: Sendable {
        private let predicate: @Sendable (SocketAddress) -> Bool

        /// `allows` receives each resolved address, including its port.
        public init(_ allows: @escaping @Sendable (SocketAddress) -> Bool) {
            self.predicate = allows
        }

        public func allows(_ address: SocketAddress) -> Bool {
            predicate(address)
        }

        /// Allows only globally routable unicast addresses.
        ///
        /// Refuses loopback, private, carrier-grade NAT, link-local (including cloud metadata
        /// endpoints), multicast, reserved, documentation, benchmarking and other IANA
        /// special-purpose ranges for IPv4 and IPv6, and Unix domain sockets. IPv4-mapped and NAT64
        /// IPv6 addresses are judged by the IPv4 address they carry.
        public static let publicInternetOnly = AddressFilter { address in
            switch address {
            case .v4(let v4):
                return SpecialPurposeRanges.isPublic(ipv4: SpecialPurposeRanges.bytes(of: v4.address.sin_addr))
            case .v6(let v6):
                return SpecialPurposeRanges.isPublic(ipv6: SpecialPurposeRanges.bytes(of: v6.address.sin6_addr))
            case .unixDomainSocket:
                return false
            }
        }
    }
}

/// IANA special-purpose address registries (IPv4 and IPv6), as CIDR blocks.
enum SpecialPurposeRanges {
    struct Block {
        let prefix: [UInt8]
        let length: Int

        func contains(_ address: [UInt8]) -> Bool {
            var remaining = length
            for (index, byte) in prefix.enumerated() where remaining > 0 {
                let bits = min(8, remaining)
                let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
                if address[index] & mask != byte & mask { return false }
                remaining -= bits
            }
            return true
        }
    }

    static let ipv4Refused: [Block] = [
        Block(prefix: [0, 0, 0, 0], length: 8),          // "this network"
        Block(prefix: [10, 0, 0, 0], length: 8),         // private
        Block(prefix: [100, 64, 0, 0], length: 10),      // carrier-grade NAT
        Block(prefix: [127, 0, 0, 0], length: 8),        // loopback
        Block(prefix: [169, 254, 0, 0], length: 16),     // link-local, cloud metadata
        Block(prefix: [172, 16, 0, 0], length: 12),      // private
        Block(prefix: [192, 0, 0, 0], length: 24),       // IETF protocol assignments
        Block(prefix: [192, 0, 2, 0], length: 24),       // documentation
        Block(prefix: [192, 31, 196, 0], length: 24),    // AS112
        Block(prefix: [192, 52, 193, 0], length: 24),    // AMT
        Block(prefix: [192, 88, 99, 0], length: 24),     // 6to4 relay anycast
        Block(prefix: [192, 168, 0, 0], length: 16),     // private
        Block(prefix: [192, 175, 48, 0], length: 24),    // AS112
        Block(prefix: [198, 18, 0, 0], length: 15),      // benchmarking
        Block(prefix: [198, 51, 100, 0], length: 24),    // documentation
        Block(prefix: [203, 0, 113, 0], length: 24),     // documentation
        Block(prefix: [224, 0, 0, 0], length: 4),        // multicast
        Block(prefix: [240, 0, 0, 0], length: 4),        // reserved, broadcast
    ]

    /// Global unicast is `2000::/3`; everything outside it is refused before these are checked.
    static let ipv6RefusedInsideGlobalUnicast: [Block] = [
        Block(prefix: [0x20, 0x01, 0x00, 0x00], length: 23),          // IETF protocol assignments, Teredo
        Block(prefix: [0x20, 0x01, 0x0D, 0xB8], length: 32),          // documentation
        Block(prefix: [0x20, 0x02], length: 16),                      // 6to4
        Block(prefix: [0x26, 0x20, 0x00, 0x4F, 0x80, 0x00], length: 48), // AS112
        Block(prefix: [0x3F, 0xFF], length: 20),                      // documentation
    ]

    static let ipv6GlobalUnicast = Block(prefix: [0x20], length: 3)
    static let ipv4Mapped = Block(prefix: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF], length: 96)
    static let nat64WellKnown = Block(prefix: [0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0], length: 96)

    static func isPublic(ipv4 bytes: [UInt8]) -> Bool {
        bytes.count == 4 && !ipv4Refused.contains { $0.contains(bytes) }
    }

    static func isPublic(ipv6 bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if ipv4Mapped.contains(bytes) || nat64WellKnown.contains(bytes) {
            return isPublic(ipv4: Array(bytes[12...]))
        }
        return ipv6GlobalUnicast.contains(bytes)
            && !ipv6RefusedInsideGlobalUnicast.contains { $0.contains(bytes) }
    }

    static func bytes<T>(of value: T) -> [UInt8] {
        withUnsafeBytes(of: value) { Array($0) }
    }
}
