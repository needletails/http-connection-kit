//
//  CookieJar.swift
//  HTTPConnectionKit
//

import Foundation
import HTTPTypes

/// Answers whether a domain is a public suffix.
public protocol PublicSuffixList: Sendable {
    func contains(_ domain: String) -> Bool
}

/// A snapshot of common public suffixes. Replace it when a newer list is required.
public struct BundledPublicSuffixList: PublicSuffixList {
    private let suffixes: Set<String>

    public init(extra: [String] = []) {
        var suffixes = Self.defaults
        suffixes.formUnion(extra.map { $0.lowercased() })
        self.suffixes = suffixes
    }

    public func contains(_ domain: String) -> Bool {
        suffixes.contains(domain.lowercased())
    }

    private static let defaults: Set<String> = [
        "com", "org", "net", "edu", "gov", "mil", "int", "io", "app", "dev",
        "co", "uk", "co.uk", "org.uk", "ac.uk", "gov.uk",
        "au", "com.au", "net.au", "org.au",
        "de", "fr", "jp", "cn", "ru", "br", "in", "it", "nl", "se", "no", "es",
        "ca", "us", "info", "biz", "xyz", "online", "cloud", "ai",
        "github.io", "herokuapp.com",
    ]
}

/// RFC 6265 cookie store. Two clients may share one jar.
public actor CookieJar {
    public struct Cookie: Sendable, Equatable {
        public var name: String
        public var value: String
        public var domain: String
        public var path: String
        public var hostOnly: Bool
        public var secure: Bool
        public var httpOnly: Bool
        public var sameSite: SameSite
        public var expiry: Date?

        public enum SameSite: Sendable, Equatable {
            case unspecified
            case strict
            case lax
            case none
        }
    }

    public let publicSuffixList: any PublicSuffixList
    public let maximumCookies: Int
    public let maximumCookiesPerDomain: Int
    private var cookies: [Cookie] = []

    public init(
        publicSuffixList: any PublicSuffixList = BundledPublicSuffixList(),
        maximumCookies: Int = 3000,
        maximumCookiesPerDomain: Int = 50
    ) {
        self.publicSuffixList = publicSuffixList
        self.maximumCookies = maximumCookies
        self.maximumCookiesPerDomain = maximumCookiesPerDomain
    }

    public func store(setCookie: String, from url: URL, at now: Date = Date()) {
        guard let cookie = parse(setCookie, from: url, at: now) else {
            return
        }
        cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
        if cookie.expiry.map({ $0 <= now }) == true {
            return
        }
        let domainCount = cookies.filter { $0.domain == cookie.domain }.count
        if domainCount >= maximumCookiesPerDomain {
            if let index = cookies.firstIndex(where: { $0.domain == cookie.domain }) {
                cookies.remove(at: index)
            }
        }
        if cookies.count >= maximumCookies {
            cookies.removeFirst()
        }
        cookies.append(cookie)
    }

    public func store(response headers: HTTPFields, from url: URL, at now: Date = Date()) {
        for field in headers where field.name == .setCookie {
            store(setCookie: field.value, from: url, at: now)
        }
    }

    public func cookieHeader(
        for url: URL,
        method: HTTPRequest.Method = .get,
        crossSite: Bool = false,
        at now: Date = Date()
    ) -> String? {
        guard let host = url.host?.lowercased() else {
            return nil
        }
        let secure = url.scheme?.lowercased() == "https"
        let path = Self.requestPath(url)
        cookies.removeAll { cookie in
            cookie.expiry.map { $0 <= now } == true
        }
        var matches = cookies.filter { cookie in
            Self.domainMatches(host: host, cookie: cookie)
                && Self.pathMatches(request: path, cookie: cookie.path)
                && (!cookie.secure || secure)
                && Self.sameSiteAllows(cookie.sameSite, method: method, crossSite: crossSite)
        }
        matches.sort {
            if $0.path.count != $1.path.count {
                return $0.path.count > $1.path.count
            }
            return $0.name < $1.name
        }
        guard !matches.isEmpty else {
            return nil
        }
        return matches.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private func parse(_ header: String, from url: URL, at now: Date) -> Cookie? {
        let pieces = header.split(separator: ";", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let first = pieces.first, let equals = first.firstIndex(of: "=") else {
            return nil
        }
        let name = String(first[..<equals])
        let value = String(first[first.index(after: equals)...])
        guard !name.isEmpty, name.utf8.count + value.utf8.count <= 4096 else {
            return nil
        }
        guard let host = url.host?.lowercased() else {
            return nil
        }

        var domain: String?
        var path: String?
        var secure = false
        var httpOnly = false
        var sameSite = Cookie.SameSite.unspecified
        var expiry: Date?
        var maxAge: Int?

        for piece in pieces.dropFirst() {
            let lower = piece.lowercased()
            if lower.hasPrefix("domain=") {
                domain = String(piece.dropFirst(7)).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            } else if lower.hasPrefix("path=") {
                path = String(piece.dropFirst(5))
            } else if lower == "secure" {
                secure = true
            } else if lower == "httponly" {
                httpOnly = true
            } else if lower.hasPrefix("samesite=") {
                switch String(piece.dropFirst(9)).lowercased() {
                case "strict": sameSite = .strict
                case "lax": sameSite = .lax
                case "none": sameSite = .none
                default: break
                }
            } else if lower.hasPrefix("max-age=") {
                maxAge = Int(piece.dropFirst(8))
            } else if lower.hasPrefix("expires=") {
                expiry = Self.parseDate(String(piece.dropFirst(8)))
            }
        }

        if sameSite == .none && !secure {
            return nil
        }
        if name.hasPrefix("__Host-") {
            guard secure, domain == nil, (path ?? "/") == "/" else {
                return nil
            }
        }
        if name.hasPrefix("__Secure-"), !secure {
            return nil
        }
        if secure, url.scheme?.lowercased() != "https" {
            return nil
        }

        let hostOnly: Bool
        let storedDomain: String
        if let domain {
            guard Self.domainMatches(host: host, domain: domain), !publicSuffixList.contains(domain) else {
                return nil
            }
            hostOnly = false
            storedDomain = domain
        } else {
            hostOnly = true
            storedDomain = host
        }

        let storedPath = path.map { $0.hasPrefix("/") ? $0 : Self.defaultPath(url) } ?? Self.defaultPath(url)
        if let maxAge {
            expiry = maxAge <= 0 ? now : now.addingTimeInterval(TimeInterval(maxAge))
        }

        return Cookie(
            name: name,
            value: value,
            domain: storedDomain,
            path: storedPath,
            hostOnly: hostOnly,
            secure: secure,
            httpOnly: httpOnly,
            sameSite: sameSite,
            expiry: expiry
        )
    }

    private static func domainMatches(host: String, cookie: Cookie) -> Bool {
        if cookie.hostOnly {
            return host == cookie.domain
        }
        return domainMatches(host: host, domain: cookie.domain)
    }

    private static func domainMatches(host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    private static func pathMatches(request: String, cookie: String) -> Bool {
        if request == cookie { return true }
        guard request.hasPrefix(cookie) else { return false }
        if cookie.hasSuffix("/") { return true }
        return request.dropFirst(cookie.count).first == "/"
    }

    private static func sameSiteAllows(
        _ sameSite: Cookie.SameSite,
        method: HTTPRequest.Method,
        crossSite: Bool
    ) -> Bool {
        guard crossSite else {
            return true
        }
        switch sameSite {
        case .strict:
            return false
        case .lax:
            return method == .get || method == .head
        case .none:
            return true
        case .unspecified:
            return method == .get || method == .head
        }
    }

    static func defaultPath(_ url: URL) -> String {
        let path = requestPath(url)
        guard path.hasPrefix("/"), path != "/" else {
            return "/"
        }
        if let last = path.lastIndex(of: "/"), last != path.startIndex {
            return String(path[..<last])
        }
        return "/"
    }

    static func requestPath(_ url: URL) -> String {
        let path = url.path
        return path.isEmpty ? "/" : path
    }

    static func parseDate(_ value: String) -> Date? {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }

    static func registrableDomain(host: String, list: any PublicSuffixList) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count >= 2 else {
            return host.lowercased()
        }
        for count in 1..<labels.count {
            let suffix = labels.suffix(count).joined(separator: ".")
            let candidate = labels.suffix(count + 1).joined(separator: ".")
            if list.contains(suffix) && !list.contains(candidate) {
                return candidate
            }
        }
        return labels.suffix(2).joined(separator: ".")
    }
}
