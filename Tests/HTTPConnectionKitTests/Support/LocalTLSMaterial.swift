//
//  LocalTLSMaterial.swift
//  HTTPConnectionKit
//
//  Created by NeedleTails on 10/5/26.
//

import Crypto
import Foundation
import NIOSSL
import SwiftASN1
import X509

/// A P-256 certificate for 127.0.0.1, generated once per test process.
///
/// Local TLS and QUIC servers present this identity. QUIC's TLS stack accepts this key and
/// certificate shape. Tests turn certificate checks off because it is not in the system trust store.
enum LocalTLSMaterial {
    struct Files: Sendable {
        var certificatePath: String
        var keyPath: String
        var certificateChain: [NIOSSLCertificate]
        var privateKey: NIOSSLPrivateKey
        var clientCertificateChain: [NIOSSLCertificate]
        var clientPrivateKey: NIOSSLPrivateKey
        var trustRoots: [NIOSSLCertificate]
    }

    static let shared: Files = {
        do {
            return try make()
        } catch {
            fatalError("Could not create the local test certificate: \(error)")
        }
    }()

    private static func make() throws -> Files {
        let caKey = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let caName = try DistinguishedName {
            CommonName("HTTPConnectionKit Test CA")
        }
        let now = Date()
        let caCertificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: caKey.publicKey,
            notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: now.addingTimeInterval(60 * 60 * 24),
            issuer: caName,
            subject: caName,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                KeyUsage(keyCertSign: true)
            },
            issuerPrivateKey: caKey
        )

        let privateKey = P256.Signing.PrivateKey()
        let key = Certificate.PrivateKey(privateKey)
        let name = try DistinguishedName {
            CommonName("127.0.0.1")
        }
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            Critical(
                KeyUsage(digitalSignature: true)
            )
            try ExtendedKeyUsage([.serverAuth])
            SubjectAlternativeNames([
                .dnsName("localhost"),
                .ipAddress(ASN1OctetString(contentBytes: [127, 0, 0, 1])),
            ])
        }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: key.publicKey,
            notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: now.addingTimeInterval(60 * 60 * 24),
            issuer: caName,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: caKey
        )

        let clientKey = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let clientName = try DistinguishedName {
            CommonName("HTTPConnectionKit Test Client")
        }
        let clientCertificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: clientKey.publicKey,
            notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: now.addingTimeInterval(60 * 60 * 24),
            issuer: caName,
            subject: clientName,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.clientAuth])
            },
            issuerPrivateKey: caKey
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("http-connection-kit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let certificateURL = directory.appendingPathComponent("cert.pem")
        let keyURL = directory.appendingPathComponent("key.pem")
        let clientCertificateURL = directory.appendingPathComponent("client-cert.pem")
        let clientKeyURL = directory.appendingPathComponent("client-key.pem")
        let caURL = directory.appendingPathComponent("ca.pem")
        try (certificate.serializeAsPEM().pemString + "\n" + caCertificate.serializeAsPEM().pemString)
            .write(to: certificateURL, atomically: true, encoding: .utf8)
        try key.serializeAsPEM().pemString.write(to: keyURL, atomically: true, encoding: .utf8)
        try (clientCertificate.serializeAsPEM().pemString + "\n" + caCertificate.serializeAsPEM().pemString)
            .write(to: clientCertificateURL, atomically: true, encoding: .utf8)
        try clientKey.serializeAsPEM().pemString.write(to: clientKeyURL, atomically: true, encoding: .utf8)
        try caCertificate.serializeAsPEM().pemString.write(to: caURL, atomically: true, encoding: .utf8)

        return Files(
            certificatePath: certificateURL.path,
            keyPath: keyURL.path,
            certificateChain: try NIOSSLCertificate.fromPEMFile(certificateURL.path),
            privateKey: try NIOSSLPrivateKey(file: keyURL.path, format: .pem),
            clientCertificateChain: try NIOSSLCertificate.fromPEMFile(clientCertificateURL.path),
            clientPrivateKey: try NIOSSLPrivateKey(file: clientKeyURL.path, format: .pem),
            trustRoots: try NIOSSLCertificate.fromPEMFile(caURL.path)
        )
    }
}

enum FixtureServerError: Error, CustomStringConvertible {
    case missingPort
    case missingParent

    var description: String {
        switch self {
        case .missingPort:
            "The fixture server did not bind a port"
        case .missingParent:
            "An HTTP/3 stream arrived without a connection"
        }
    }
}
