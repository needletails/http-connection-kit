//
//  CookieJarTests.swift
//  HTTPConnectionKitTests
//

import Foundation
import HTTPConnectionKit
import HTTPTypes
import Testing

@Suite("Cookie jar")
struct CookieJarTests {
    @Test func maxAgeWinsOverExpiresAndZeroDeletes() async {
        let jar = CookieJar()
        let url = URL(string: "http://example.com/")!
        let now = Date(timeIntervalSince1970: 1_000_000)
        await jar.store(
            setCookie: "a=1; Expires=Wed, 21 Oct 2015 07:28:00 GMT; Max-Age=60",
            from: url,
            at: now
        )
        #expect(await jar.cookieHeader(for: url, at: now) == "a=1")
        #expect(await jar.cookieHeader(for: url, at: now.addingTimeInterval(61)) == nil)

        await jar.store(setCookie: "a=1; Max-Age=0", from: url, at: now)
        #expect(await jar.cookieHeader(for: url, at: now) == nil)
    }

    @Test func domainAndHostOnlyMatching() async {
        let jar = CookieJar()
        let host = URL(string: "http://app.example.com/")!
        await jar.store(setCookie: "host=1", from: host)
        await jar.store(setCookie: "dom=1; Domain=example.com", from: host)
        #expect(await jar.cookieHeader(for: host) == "dom=1; host=1")
        #expect(await jar.cookieHeader(for: URL(string: "http://example.com/")!) == "dom=1")
        #expect(await jar.cookieHeader(for: URL(string: "http://other.test/")!) == nil)
        await jar.store(setCookie: "bad=1; Domain=co.uk", from: URL(string: "http://www.co.uk/")!)
        #expect(await jar.cookieHeader(for: URL(string: "http://www.co.uk/")!) == nil)
    }

    @Test func pathMatchingPutsTheLongerPathFirst() async {
        let jar = CookieJar()
        let url = URL(string: "http://example.com/foo/bar")!
        await jar.store(setCookie: "short=1; Path=/", from: url)
        await jar.store(setCookie: "long=1; Path=/foo", from: url)
        #expect(await jar.cookieHeader(for: url) == "long=1; short=1")
        #expect(await jar.cookieHeader(for: URL(string: "http://example.com/")!) == "short=1")
    }

    @Test func secureHttpOnlyAndSameSiteRules() async {
        let jar = CookieJar()
        let https = URL(string: "https://example.com/")!
        let http = URL(string: "http://example.com/")!
        await jar.store(setCookie: "s=1; Secure", from: https)
        await jar.store(setCookie: "h=1; HttpOnly", from: http)
        #expect(await jar.cookieHeader(for: http) == "h=1")
        #expect(await jar.cookieHeader(for: https)?.contains("s=1") == true)
        await jar.store(setCookie: "none=1; SameSite=None", from: http)
        #expect(await jar.cookieHeader(for: http)?.contains("none=1") != true)

        await jar.store(setCookie: "strict=1; SameSite=Strict", from: http)
        await jar.store(setCookie: "lax=1; SameSite=Lax", from: http)
        #expect(await jar.cookieHeader(for: http, method: .get, crossSite: true)?.contains("strict=1") != true)
        #expect(await jar.cookieHeader(for: http, method: .get, crossSite: true)?.contains("lax=1") == true)
        #expect(await jar.cookieHeader(for: http, method: .post, crossSite: true)?.contains("lax=1") != true)
    }

    @Test func prefixesAndSizeCaps() async {
        let jar = CookieJar(maximumCookies: 3, maximumCookiesPerDomain: 2)
        let https = URL(string: "https://example.com/")!
        await jar.store(setCookie: "__Host-a=1; Path=/other; Secure", from: https)
        #expect(await jar.cookieHeader(for: https) == nil)
        await jar.store(setCookie: "__Host-a=1; Path=/; Secure", from: https)
        #expect(await jar.cookieHeader(for: https) == "__Host-a=1")
        await jar.store(setCookie: "__Secure-b=1", from: https)
        #expect(await jar.cookieHeader(for: https)?.contains("__Secure-b") != true)
        await jar.store(setCookie: "__Secure-b=1; Secure", from: https)
        #expect(await jar.cookieHeader(for: https)?.contains("__Secure-b=1") == true)

        let huge = String(repeating: "x", count: 4097)
        await jar.store(setCookie: "z=\(huge)", from: https)
        #expect(await jar.cookieHeader(for: https)?.contains("z=") != true)

        await jar.store(setCookie: "c=1", from: https)
        await jar.store(setCookie: "d=1", from: https)
        let header = await jar.cookieHeader(for: https) ?? ""
        #expect(header.split(separator: ";").count <= 2)
    }

    @Test func replacementUsesNameDomainAndPath() async {
        let jar = CookieJar()
        let url = URL(string: "http://example.com/app")!
        await jar.store(setCookie: "a=1; Path=/app", from: url)
        await jar.store(setCookie: "a=2; Path=/app", from: url)
        #expect(await jar.cookieHeader(for: url) == "a=2")
    }

    @Test func twoClientsCanShareAJar() async throws {
        let jar = CookieJar()
        var configuration = HTTPConnection.Configuration()
        configuration.cookieJar = jar
        try await withHTTP1Client(configuration: configuration) { client, server in
            _ = try await client.request(method: .get, url: server.url("/set-cookie"), headers: [:], body: nil)
            let second = HTTPConnection(preferred: .http1_1, configuration: configuration)
            let echoed = try await second.request(method: .get, url: server.url("/echo"), headers: [:], body: nil)
            #expect(FixtureEcho(try #require(echoed.body)).fields["header.cookie"] == "session=1")
            await second.shutdown()
        }
    }
}
