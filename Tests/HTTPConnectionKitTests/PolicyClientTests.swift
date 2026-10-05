//
//  PolicyClientTests.swift
//  HTTPConnectionKitTests
//

import Foundation
import HTTPConnectionKit
import HTTPTypes
import Testing

@Suite("Redirects, decompression, authentication, and cookies")
struct PolicyClientTests {
    @Test(arguments: TestHTTP.allCases)
    func redirectsFollowStatusRules(_ version: TestHTTP) async throws {
        try await withLocalClient(version) { client, url, _, _ in
            for code in [301, 302, 303] {
                let response = try await client.request(
                    method: .post,
                    url: url("/redirect/\(code)"),
                    headers: [:],
                    body: Data("dropped".utf8)
                )
                let echo = FixtureEcho(try #require(response.body))
                #expect(echo.fields["method"] == "GET")
                #expect(echo.body.isEmpty)
            }

            let replayed = try await client.request(
                method: .post,
                url: url("/redirect/307"),
                headers: [:],
                body: Data("kept".utf8)
            )
            let replayEcho = FixtureEcho(try #require(replayed.body))
            #expect(replayEcho.fields["method"] == "POST")
            #expect(replayEcho.body == Data("kept".utf8))

            let permanent = try await client.request(
                method: .put,
                url: url("/redirect/308"),
                headers: [:],
                body: Data("again".utf8)
            )
            #expect(FixtureEcho(try #require(permanent.body)).fields["method"] == "PUT")
        }
    }

    @Test(arguments: TestHTTP.allCases)
    func redirectLimitAndUnreplayableBody(_ version: TestHTTP) async throws {
        var configuration = HTTPConnection.Configuration()
        configuration.maximumRedirects = 8
        if version == .http2 {
            configuration.tls.certificateVerification = .none
        }
        try await withLocalClient(version, configuration: configuration) { client, url, _, _ in
            await #expect(throws: HTTPConnectionError.tooManyRedirects) {
                try await client.request(method: .get, url: url("/redirect-loop"), headers: [:], body: nil)
            }

            let (stream, continuation) = AsyncStream<Data>.makeStream()
            continuation.yield(Data("once".utf8))
            continuation.finish()
            await #expect(throws: HTTPConnectionError.unreplayableBody) {
                try await client.request(
                    method: .post,
                    url: url("/redirect/307"),
                    headers: [:],
                    body: stream
                )
            }
        }
    }

    @Test func authorizationIsStrippedOnAHostChange() async throws {
        try await withHTTP1Client { client, server in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer keep-me"
            let response = try await client.request(
                method: .get,
                url: server.url("/redirect-host"),
                headers: headers,
                body: nil
            )
            let echo = FixtureEcho(try #require(response.body))
            #expect(echo.fields["header.authorization"] == nil)
        }
    }

    @Test(arguments: TestHTTP.allCases)
    func gzipAndDeflateAreInflated(_ version: TestHTTP) async throws {
        try await withLocalClient(version) { client, url, _, _ in
            let gzip = try await client.request(method: .get, url: url("/gzip"), headers: [:], body: nil)
            #expect(gzip.body == Data("hello-gzip".utf8))
            #expect(gzip.head.headerFields[.contentEncoding] == nil)

            let deflate = try await client.request(method: .get, url: url("/deflate"), headers: [:], body: nil)
            #expect(deflate.body == Data("hello-deflate".utf8))

            let brotli = try await client.request(method: .get, url: url("/br"), headers: [:], body: nil)
            #expect(brotli.body == Data("brotli-raw".utf8))
            #expect(brotli.head.headerFields[.contentEncoding] == "br")

            let streamed = try await client.requestStream(method: .get, url: url("/gzip"))
            #expect(try await streamed.body.collect() == Data("hello-gzip".utf8))
        }
    }

    @Test(arguments: TestHTTP.allCases)
    func aGzipBombHitsTheRatioLimit(_ version: TestHTTP) async throws {
        var configuration = HTTPConnection.Configuration()
        configuration.decompressionRatioLimit = 10
        if version == .http2 {
            configuration.tls.certificateVerification = .none
        }
        try await withLocalClient(version, configuration: configuration) { client, url, _, _ in
            await #expect(throws: HTTPConnectionError.decompressionLimit) {
                try await client.request(method: .get, url: url("/gzip-bomb"), headers: [:], body: nil)
            }
        }
    }

    @Test func callerAcceptEncodingIsLeftAlone() async throws {
        try await withHTTP1Client { client, server in
            var headers = HTTPFields()
            headers[.acceptEncoding] = "identity"
            let response = try await client.request(
                method: .get,
                url: server.url("/echo"),
                headers: headers,
                body: nil
            )
            let echo = FixtureEcho(try #require(response.body))
            #expect(echo.fields["header.accept-encoding"] == "identity")
        }
    }

    @Test(arguments: TestHTTP.allCases)
    func basicBearerAndDigestChallenges(_ version: TestHTTP) async throws {
        var configuration = HTTPConnection.Configuration()
        configuration.authenticator = { challenges, _ in
            if challenges.contains(where: { $0.scheme.lowercased() == "digest" }) {
                return .digest(username: "user", password: "secret")
            }
            if challenges.contains(where: { $0.scheme.lowercased() == "bearer" })
                && !challenges.contains(where: { $0.scheme.lowercased() == "basic" })
            {
                return .bearer("token-1")
            }
            return .basic(username: "user", password: "secret")
        }
        if version == .http2 {
            configuration.tls.certificateVerification = .none
        }
        try await withLocalClient(version, configuration: configuration) { client, url, _, _ in
            let basic = try await client.request(method: .get, url: url("/auth/basic"), headers: [:], body: nil)
            #expect(basic.head.status.code == 200)

            let bearer = try await client.request(method: .get, url: url("/auth/bearer"), headers: [:], body: nil)
            #expect(bearer.head.status.code == 200)

            let digest = try await client.request(method: .get, url: url("/auth/digest"), headers: [:], body: nil)
            #expect(digest.head.status.code == 200)
            let digestBody = String(decoding: try #require(digest.body), as: UTF8.self)
            #expect(digestBody.contains("algorithm=SHA-256"))
            #expect(digestBody.contains("qop=auth"))
        }
    }

    @Test func digestStaleAllowsOneMoreRetry() async throws {
        var configuration = HTTPConnection.Configuration()
        configuration.authenticator = { _, _ in .digest(username: "user", password: "secret") }
        try await withHTTP1Client(configuration: configuration) { client, server in
            let response = try await client.request(
                method: .get,
                url: server.url("/auth/digest-stale"),
                headers: [:],
                body: nil
            )
            #expect(response.head.status.code == 200)
            let body = String(decoding: try #require(response.body), as: UTF8.self)
            #expect(body.contains("nonce=\"xyz\""))
        }
    }

    @Test func proxyAuthorizationUsesTheProxyHeader() async throws {
        var configuration = HTTPConnection.Configuration()
        configuration.authenticator = { _, _ in .basic(username: "user", password: "secret") }
        try await withHTTP1Client(configuration: configuration) { client, server in
            let response = try await client.request(
                method: .get,
                url: server.url("/auth/proxy"),
                headers: [:],
                body: nil
            )
            #expect(response.head.status.code == 200)
        }
    }

    @Test func challengesAreExposedWithoutAnAuthenticator() async throws {
        try await withHTTP1Client { client, server in
            let response = try await client.request(
                method: .get,
                url: server.url("/auth/basic"),
                headers: [:],
                body: nil
            )
            #expect(response.head.status.code == 401)
            #expect(response.challenges.contains(where: { $0.scheme.lowercased() == "basic" }))
            #expect(response.challenges.contains(where: { $0.scheme.lowercased() == "bearer" }))
        }
    }

    @Test func aOneShotBodyCannotBeRetried() async throws {
        var configuration = HTTPConnection.Configuration()
        configuration.authenticator = { _, _ in .basic(username: "user", password: "secret") }
        try await withHTTP1Client(configuration: configuration) { client, server in
            let (stream, continuation) = AsyncStream<Data>.makeStream()
            continuation.yield(Data("once".utf8))
            continuation.finish()
            await #expect(throws: HTTPConnectionError.unreplayableBody) {
                try await client.request(
                    method: .post,
                    url: server.url("/auth/basic"),
                    headers: [:],
                    body: stream
                )
            }
        }
    }

    @Test func cookieJarIsSentOnTheNextRequest() async throws {
        try await withHTTP1Client { client, server in
            _ = try await client.request(method: .get, url: server.url("/set-cookie"), headers: [:], body: nil)
            let echoed = try await client.request(method: .get, url: server.url("/echo"), headers: [:], body: nil)
            let echo = FixtureEcho(try #require(echoed.body))
            #expect(echo.fields["header.cookie"] == "session=1")
        }
    }

    @Test func aCallerCookieIsNotCopiedAcrossARedirect() async throws {
        try await withHTTP1Client { client, server in
            var headers = HTTPFields()
            headers[.cookie] = "stale=1"
            let response = try await client.request(
                method: .get,
                url: server.url("/redirect/302"),
                headers: headers,
                body: nil
            )
            let echo = FixtureEcho(try #require(response.body))
            #expect(echo.fields["header.cookie"] == nil)
        }
    }

    @Test func cookieHeaderIsRecomputedForTheRedirectedURL() async throws {
        try await withHTTP1Client { client, server in
            _ = try await client.request(method: .get, url: server.url("/set-cookie-path"), headers: [:], body: nil)
            let response = try await client.request(
                method: .get,
                url: server.url("/redirect/302"),
                headers: [:],
                body: nil
            )
            let echo = FixtureEcho(try #require(response.body))
            #expect(echo.fields["header.cookie"] == "scoped=1")
        }
    }
}

@Suite("HTTP/3 decompression")
struct HTTP3DecompressionTests {
    @Test func gzipIsInflated() async throws {
        guard #available(anyAppleOS 26, *) else { return }
        try await withHTTP3Client { client, server in
            let gzip = try await client.request(method: .get, url: server.url("/gzip"), headers: [:], body: nil)
            #expect(gzip.body == Data("hello-gzip".utf8))
            let streamed = try await client.requestStream(method: .get, url: server.url("/deflate"))
            #expect(try await streamed.body.collect() == Data("hello-deflate".utf8))
        }
    }
}

@Suite("Challenge parsing")
struct HTTPChallengeTests {
    @Test func severalChallengesInOneFieldAreParsed() {
        var fields = HTTPFields()
        fields[.wwwAuthenticate] = #"Basic realm="x", Bearer realm="api", Digest realm="z", nonce="abc", qop="auth""#
        let challenges = HTTPChallenge.parse(fields)
        #expect(challenges.map(\.scheme) == ["Basic", "Bearer", "Digest"])
        #expect(challenges[2].parameters["nonce"] == "abc")
        #expect(challenges[2].parameters["qop"] == "auth")
    }
}
