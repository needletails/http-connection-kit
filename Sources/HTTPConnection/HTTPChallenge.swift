//
//  HTTPChallenge.swift
//  HTTPConnectionKit
//

import Crypto
import Foundation
import HTTPTypes

/// One challenge from `WWW-Authenticate` or `Proxy-Authenticate`.
public struct HTTPChallenge: Sendable, Equatable {
    public var scheme: String
    public var parameters: [String: String]

    public init(scheme: String, parameters: [String: String] = [:]) {
        self.scheme = scheme
        self.parameters = parameters
    }

    public static func parse(_ fields: HTTPFields) -> [HTTPChallenge] {
        var challenges: [HTTPChallenge] = []
        for field in fields where field.name == .wwwAuthenticate || field.name == .proxyAuthenticate {
            challenges.append(contentsOf: parseHeader(field.value))
        }
        return challenges
    }

    static func parseHeader(_ value: String) -> [HTTPChallenge] {
        var challenges: [HTTPChallenge] = []
        var scheme = ""
        var parameters: [String: String] = [:]
        var index = value.startIndex

        func flush() {
            guard !scheme.isEmpty else { return }
            challenges.append(HTTPChallenge(scheme: scheme, parameters: parameters))
            scheme = ""
            parameters = [:]
        }

        while index < value.endIndex {
            while index < value.endIndex, value[index].isWhitespace || value[index] == "," {
                index = value.index(after: index)
            }
            guard index < value.endIndex else { break }

            let start = index
            while index < value.endIndex, value[index].isLetter || value[index].isNumber || value[index] == "-" {
                index = value.index(after: index)
            }
            let token = String(value[start..<index])
            while index < value.endIndex, value[index].isWhitespace {
                index = value.index(after: index)
            }

            if index < value.endIndex, value[index] == "=" {
                index = value.index(after: index)
                while index < value.endIndex, value[index].isWhitespace {
                    index = value.index(after: index)
                }
                let parsed: String
                if index < value.endIndex, value[index] == "\"" {
                    index = value.index(after: index)
                    var raw = ""
                    while index < value.endIndex, value[index] != "\"" {
                        if value[index] == "\\" {
                            index = value.index(after: index)
                            guard index < value.endIndex else { break }
                        }
                        raw.append(value[index])
                        index = value.index(after: index)
                    }
                    if index < value.endIndex { index = value.index(after: index) }
                    parsed = raw
                } else {
                    let valueStart = index
                    while index < value.endIndex, value[index] != "," && !value[index].isWhitespace {
                        index = value.index(after: index)
                    }
                    parsed = String(value[valueStart..<index])
                }
                parameters[token.lowercased()] = parsed
            } else {
                flush()
                scheme = token
            }
        }
        flush()
        return challenges
    }
}

/// Credentials returned by an authenticator.
public struct HTTPCredentials: Sendable {
    public var username: String?
    public var password: String?
    public var bearerToken: String?

    public init(username: String? = nil, password: String? = nil, bearerToken: String? = nil) {
        self.username = username
        self.password = password
        self.bearerToken = bearerToken
    }

    public static func basic(username: String, password: String) -> Self {
        Self(username: username, password: password)
    }

    public static func bearer(_ token: String) -> Self {
        Self(bearerToken: token)
    }

    public static func digest(username: String, password: String) -> Self {
        Self(username: username, password: password)
    }
}

/// Chooses credentials for a challenge. Returning `nil` leaves the response as-is.
public typealias HTTPAuthenticator = @Sendable ([HTTPChallenge], URL) async -> HTTPCredentials?

enum ChallengeAuthorization {
    static func header(
        challenge: HTTPChallenge,
        credentials: HTTPCredentials,
        method: HTTPRequest.Method,
        uri: String,
        body: Data?,
        nonceCount: Int
    ) -> (name: HTTPField.Name, value: String)? {
        switch challenge.scheme.lowercased() {
        case "basic":
            guard let username = credentials.username, let password = credentials.password else {
                return nil
            }
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            return (.authorization, "Basic \(token)")
        case "bearer":
            guard let token = credentials.bearerToken else {
                return nil
            }
            return (.authorization, "Bearer \(token)")
        case "digest":
            guard let username = credentials.username, let password = credentials.password else {
                return nil
            }
            let value = digestValue(
                challenge: challenge,
                username: username,
                password: password,
                method: method,
                uri: uri,
                body: body,
                nonceCount: nonceCount
            )
            return (.authorization, value)
        default:
            return nil
        }
    }

    static func digestValue(
        challenge: HTTPChallenge,
        username: String,
        password: String,
        method: HTTPRequest.Method,
        uri: String,
        body: Data?,
        nonceCount: Int
    ) -> String {
        let realm = challenge.parameters["realm"] ?? ""
        let nonce = challenge.parameters["nonce"] ?? ""
        let opaque = challenge.parameters["opaque"]
        let algorithm = (challenge.parameters["algorithm"] ?? "MD5").uppercased()
        let qops = (challenge.parameters["qop"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let qop: String?
        if qops.contains("auth") {
            qop = "auth"
        } else if qops.contains("auth-int"), body != nil {
            qop = "auth-int"
        } else if qops.isEmpty {
            qop = nil
        } else {
            qop = qops.first
        }
        let cnonce = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))
        let nc = String(format: "%08x", nonceCount)
        let hashData: (Data) -> String = { data in
            if algorithm.hasPrefix("SHA-256") {
                return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let hash: (String) -> String = { hashData(Data($0.utf8)) }

        var ha1 = hash("\(username):\(realm):\(password)")
        if algorithm.hasSuffix("-SESS") {
            ha1 = hash("\(ha1):\(nonce):\(cnonce)")
        }
        let ha2: String
        if qop == "auth-int" {
            ha2 = hash("\(method.rawValue):\(uri):\(hashData(body ?? Data()))")
        } else {
            ha2 = hash("\(method.rawValue):\(uri)")
        }
        let response: String
        if let qop {
            response = hash("\(ha1):\(nonce):\(nc):\(cnonce):\(qop):\(ha2)")
        } else {
            response = hash("\(ha1):\(nonce):\(ha2)")
        }

        var parts = [
            "Digest username=\"\(username)\"",
            "realm=\"\(realm)\"",
            "nonce=\"\(nonce)\"",
            "uri=\"\(uri)\"",
            "response=\"\(response)\"",
        ]
        if let qop {
            parts.append("qop=\(qop)")
            parts.append("nc=\(nc)")
            parts.append("cnonce=\"\(cnonce)\"")
        }
        parts.append("algorithm=\(challenge.parameters["algorithm"] ?? "MD5")")
        if let opaque {
            parts.append("opaque=\"\(opaque)\"")
        }
        return parts.joined(separator: ", ")
    }
}

extension HTTPField.Name {
    static var proxyAuthenticate: HTTPField.Name { HTTPField.Name("Proxy-Authenticate")! }
    static var proxyAuthorization: HTTPField.Name { HTTPField.Name("Proxy-Authorization")! }
}
