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
        configuration.redirects = .follow(maximum: 8)
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
        configuration.decompression = .enabled(ratioLimit: 10)
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
        configuration.authentication = ChallengeAuthenticationProvider(mode: .routing)
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
        configuration.authentication = ChallengeAuthenticationProvider(mode: .digest)
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

    @Test(arguments: TestHTTP.allCases)
    func bearerAuthenticationIsAppliedBeforeTheFirstRequest(_ version: TestHTTP) async throws {
        let probe = AuthenticationProbe(credential: TestCredential(token: "fresh"))
        var configuration = HTTPConnection.Configuration()
        configuration.authentication = TestAuthenticationProvider(probe: probe)
        if version == .http2 {
            configuration.tls.certificateVerification = .none
        }
        try await withLocalClient(version, configuration: configuration) { client, url, _, _ in
            let response = try await client.request(
                method: .get,
                url: url("/auth/refresh"),
                headers: [:],
                body: nil
            )
            #expect(response.head.status.code == 200)
            #expect(String(decoding: try #require(response.body), as: UTF8.self) == "Bearer fresh\n")
            #expect(probe.loadCount == 1)
            #expect(probe.refreshCount == 0)
        }
    }

    @Test func bearerTokenProviderCoversTheCommonRefreshFlow() async throws {
        let probe = BearerProbe()
        var configuration = HTTPConnection.Configuration()
        configuration.authentication = BearerTokenProvider(
            load: { probe.load() },
            refresh: { old in probe.refresh(old) },
            appliesTo: { _ in true }
        )
        try await withHTTP1Client(configuration: configuration) { client, server in
            let response = try await client.request(
                method: .get,
                url: server.url("/auth/refresh"),
                headers: [:],
                body: nil
            )
            #expect(response.head.status.code == 200)
            #expect(probe.refreshCount == 1)
        }
    }

    @Test func bearerTokensRequireHTTPSByDefault() async throws {
        var configuration = HTTPConnection.Configuration()
        configuration.authentication = BearerTokenProvider(
            load: { BearerToken("fresh") },
            refresh: { _ in BearerToken("fresh") }
        )
        try await withHTTP1Client(configuration: configuration) { client, server in
            let response = try await client.request(method: .get, url: server.url("/echo"))
            let echo = FixtureEcho(try #require(response.body))
            #expect(echo.fields["header.authorization"] == nil)
        }
    }

    @Test func authenticationIsNotReappliedAcrossAnOriginRedirect() async throws {
        let probe = AuthenticationProbe(credential: TestCredential(token: "fresh"))
        var configuration = HTTPConnection.Configuration()
        configuration.authentication = TestAuthenticationProvider(probe: probe)
        try await withHTTP1Client(configuration: configuration) { client, server in
            let response = try await client.request(method: .get, url: server.url("/redirect-host"))
            let echo = FixtureEcho(try #require(response.body))
            #expect(echo.fields["header.authorization"] == nil)
        }
    }

    @Test func invalidBearerTokenCannotInjectAHeader() async throws {
        var configuration = HTTPConnection.Configuration()
        configuration.authentication = BearerTokenProvider(
            load: { BearerToken("valid\r\nX-Injected: yes") },
            refresh: { $0 },
            appliesTo: { _ in true }
        )
        try await withHTTP1Client(configuration: configuration) { client, server in
            await #expect(throws: HTTPConnectionError.invalidRequest) {
                try await client.request(method: .get, url: server.url("/echo"))
            }
        }
    }

    @Test func redirectToGetDropsBodyHeaders() async throws {
        try await withHTTP1Client { client, server in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            headers[.contentLength] = "7"
            let response = try await client.request(
                method: .post,
                url: server.url("/redirect/302"),
                headers: headers,
                body: Data("payload".utf8)
            )
            let echo = FixtureEcho(try #require(response.body))
            #expect(echo.fields["method"] == "GET")
            #expect(echo.fields["header.content-type"] == nil)
            #expect(echo.fields["header.content-length"] == nil)
        }
    }

    @Test func httpsToHTTPRedirectStripsAuthorization() async throws {
        let cleartext = try await HTTP1FixtureServer.bind()
        do {
            var configuration = HTTPConnection.Configuration()
            configuration.tls.certificateVerification = .none
            try await withTLSClient(
                mode: .http1,
                preferred: .http1_1,
                configuration: configuration
            ) { client, tls in
                let redirect = URL(
                    string: "\(tls.url("/redirect/302").absoluteString)?to=\(cleartext.url("/echo").absoluteString)"
                )
                var headers = HTTPFields()
                headers[.authorization] = "Bearer secret"
                let response = try await client.request(
                    method: .get,
                    url: try #require(redirect),
                    headers: headers
                )
                let echo = FixtureEcho(try #require(response.body))
                #expect(echo.fields["header.authorization"] == nil)
            }
            await cleartext.stop()
        } catch {
            await cleartext.stop()
            throw error
        }
    }

    @Test func bufferedResponsesRespectTheConfiguredLimit() async throws {
        var configuration = HTTPConnection.Configuration()
        configuration.maximumBufferedBodySize = 32
        try await withHTTP1Client(configuration: configuration) { client, server in
            await #expect(throws: HTTPConnectionError.responseTooLarge) {
                try await client.request(method: .get, url: server.url("/large?bytes=33"))
            }
            let response = try await client.request(method: .get, url: server.url("/large?bytes=32"))
            #expect(response.body?.count == 32)
            let streamed = try await client.requestStream(method: .get, url: server.url("/large?bytes=33"))
            #expect(try await streamed.body.collect() == Data(repeating: 0x61, count: 33))
        }
    }

    @Test func requestDeadlineCancelsAStalledExchange() async throws {
        var configuration = HTTPConnection.Configuration()
        configuration.timeouts.request = .seconds(2)
        try await withHTTP1Client(configuration: configuration) { client, server in
            await #expect(throws: HTTPConnectionError.timeout) {
                try await client.request(method: .get, url: server.url("/hold"))
            }
            let response = try await client.request(method: .get, url: server.url("/echo"))
            #expect(response.head.status.code == 200)
        }
    }

    @Test func perRequestDeadlineOverridesTheConfiguredDeadline() async throws {
        var configuration = HTTPConnection.Configuration()
        configuration.timeouts.request = .seconds(30)
        try await withHTTP1Client(configuration: configuration) { client, server in
            await #expect(throws: HTTPConnectionError.timeout) {
                try await client.request(
                    method: .get,
                    url: server.url("/hold"),
                    headers: [:],
                    body: nil,
                    options: .init(timeout: .milliseconds(50))
                )
            }
            let response = try await client.request(method: .get, url: server.url("/echo"))
            #expect(response.head.status.code == 200)
        }
    }

    @Test func authenticationDescriptionsRedactSecrets() {
        #expect(!String(describing: BearerToken("secret-token")).contains("secret-token"))
        #expect(!String(describing: HTTPCredentials.bearer("secret-token")).contains("secret-token"))
        var headers = HTTPFields()
        headers[.authorization] = "Bearer secret-token"
        headers[.cookie] = "session=secret-cookie"
        let request = HTTPAuthenticationRequest(
            method: .get,
            url: URL(string: "https://example.com/")!,
            headers: headers
        )
        let description = String(describing: request)
        #expect(!description.contains("secret-token"))
        #expect(!description.contains("secret-cookie"))
    }

    @Test func aBare401IsUnchangedWithoutAProvider() async throws {
        try await withHTTP1Client { client, server in
            let response = try await client.request(
                method: .get,
                url: server.url("/auth/refresh"),
                headers: [:],
                body: nil
            )
            #expect(response.head.status.code == 401)
            #expect(response.challenges.isEmpty)
            #expect(String(decoding: try #require(response.body), as: UTF8.self) == "expired")
        }
    }

    @Test(arguments: TestHTTP.allCases)
    func anExpiredAccessTokenIsRefreshedOnce(_ version: TestHTTP) async throws {
        let probe = AuthenticationProbe(credential: TestCredential(token: "expired"))
        var configuration = HTTPConnection.Configuration()
        configuration.authentication = TestAuthenticationProvider(probe: probe)
        if version == .http2 {
            configuration.tls.certificateVerification = .none
        }
        try await withLocalClient(version, configuration: configuration) { client, url, _, _ in
            let response = try await client.request(
                method: .get,
                url: url("/auth/refresh"),
                headers: [:],
                body: nil
            )
            #expect(response.head.status.code == 200)
            #expect(String(decoding: try #require(response.body), as: UTF8.self) == "Bearer fresh\n")
            #expect(probe.refreshCount == 1)
        }
    }

    @Test func aCredentialThatRequiresRefreshIsRenewedBeforeSending() async throws {
        let probe = AuthenticationProbe(
            credential: TestCredential(token: "expired", requiresRefresh: true)
        )
        var configuration = HTTPConnection.Configuration()
        configuration.authentication = TestAuthenticationProvider(probe: probe)
        try await withHTTP1Client(configuration: configuration) { client, server in
            let response = try await client.request(
                method: .get,
                url: server.url("/auth/refresh"),
                headers: [:],
                body: nil
            )
            #expect(response.head.status.code == 200)
            #expect(probe.refreshCount == 1)
        }
    }

    @Test func aSecondAuthenticationFailureIsReturnedWithoutAnotherRefresh() async throws {
        let probe = AuthenticationProbe(credential: TestCredential(token: "expired"))
        var configuration = HTTPConnection.Configuration()
        configuration.authentication = TestAuthenticationProvider(probe: probe)
        try await withHTTP1Client(configuration: configuration) { client, server in
            let response = try await client.request(
                method: .get,
                url: server.url("/auth/refresh-rejected"),
                headers: [:],
                body: nil
            )
            #expect(response.head.status.code == 401)
            #expect(probe.refreshCount == 1)
        }
    }

    @Test func insufficientScopeDoesNotRefreshTheCredential() async throws {
        let probe = AuthenticationProbe(credential: TestCredential(token: "fresh"))
        var configuration = HTTPConnection.Configuration()
        configuration.authentication = TestAuthenticationProvider(probe: probe)
        try await withHTTP1Client(configuration: configuration) { client, server in
            let response = try await client.request(
                method: .get,
                url: server.url("/auth/bearer-scope"),
                headers: [:],
                body: nil
            )
            #expect(response.head.status.code == 401)
            #expect(probe.refreshCount == 0)
        }
    }

    @Test func streamedAuthenticationFailureIsRetried() async throws {
        let probe = AuthenticationProbe(credential: TestCredential(token: "expired"))
        var configuration = HTTPConnection.Configuration()
        configuration.authentication = TestAuthenticationProvider(probe: probe)
        try await withHTTP1Client(configuration: configuration) { client, server in
            let response = try await client.requestStream(
                method: .get,
                url: server.url("/auth/refresh"),
                headers: [:]
            )
            #expect(response.head.status.code == 200)
            #expect(try await response.body.collect() == Data("Bearer fresh\n".utf8))
            #expect(probe.refreshCount == 1)
        }
    }

    @Test func streamedAuthenticationFailureBodyUsesTheBufferLimit() async throws {
        let probe = AuthenticationProbe(credential: TestCredential(token: "expired"))
        var configuration = HTTPConnection.Configuration()
        configuration.authentication = TestAuthenticationProvider(probe: probe)
        configuration.maximumBufferedBodySize = 32
        try await withHTTP1Client(configuration: configuration) { client, server in
            await #expect(throws: HTTPConnectionError.responseTooLarge) {
                try await client.requestStream(
                    method: .get,
                    url: server.url("/auth/refresh-large")
                )
            }
            #expect(probe.refreshCount == 0)
        }
    }

    @Test func concurrentFailuresShareOneRefresh() async throws {
        let gate = AuthenticationRefreshGate()
        let probe = AuthenticationProbe(
            credential: TestCredential(token: "expired"),
            expectedFailures: 8,
            refreshGate: gate
        )
        var configuration = HTTPConnection.Configuration()
        configuration.authentication = TestAuthenticationProvider(probe: probe)
        try await withHTTP1Client(configuration: configuration) { client, server in
            let url = server.url("/auth/refresh")
            try await withThrowingTaskGroup(of: HCKResponse.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        try await client.request(
                            method: .get,
                            url: url,
                            headers: [:],
                            body: nil
                        )
                    }
                }
                await probe.allFailures.wait()
                await gate.release.signal()
                for try await response in group {
                    #expect(response.head.status.code == 200)
                }
            }
            #expect(probe.refreshCount == 1)
        }
    }

    @Test func aRefreshErrorIsReportedAsAuthenticationFailed() async throws {
        let probe = AuthenticationProbe(
            credential: TestCredential(token: "expired"),
            refreshError: AuthenticationTestError.refreshFailed
        )
        var configuration = HTTPConnection.Configuration()
        configuration.authentication = TestAuthenticationProvider(probe: probe)
        try await withHTTP1Client(configuration: configuration) { client, server in
            await #expect(throws: HTTPConnectionError.self) {
                try await client.request(
                    method: .get,
                    url: server.url("/auth/refresh"),
                    headers: [:],
                    body: nil
                )
            }
        }
    }

    @Test func theRefreshWindowStopsARefreshStorm() async throws {
        let probe = AuthenticationProbe(credential: TestCredential(token: "expired"))
        var configuration = HTTPConnection.Configuration()
        configuration.authentication = TestAuthenticationProvider(probe: probe)
        configuration.authenticationRefreshWindow = HTTPAuthenticationRefreshWindow(
            maximumAttempts: 1,
            interval: .seconds(30)
        )
        try await withHTTP1Client(configuration: configuration) { client, server in
            let rejected = try await client.request(
                method: .get,
                url: server.url("/auth/refresh-rejected"),
                headers: [:],
                body: nil
            )
            #expect(rejected.head.status.code == 401)
            await #expect(throws: HTTPConnectionError.authenticationRefreshLimitExceeded) {
                try await client.request(
                    method: .get,
                    url: server.url("/auth/refresh-rejected"),
                    headers: [:],
                    body: nil
                )
            }
            #expect(probe.refreshCount == 1)
        }
    }

    @Test func cancellingTheOnlyRefreshWaiterCancelsTheRefresh() async throws {
        let refresh = CancellableRefresh()
        var configuration = HTTPConnection.Configuration()
        configuration.authentication = HungRefreshProvider(refresh: refresh)
        try await withHTTP1Client(configuration: configuration) { client, server in
            let url = server.url("/echo")
            let first = Task {
                try await client.request(method: .get, url: url, headers: [:], body: nil)
            }
            await refresh.started.wait()
            first.cancel()
            #expect(await waitForTask(first, seconds: 2))
            #expect(await waitForTask(Task { await refresh.finished.wait() }, seconds: 2))
            #expect(refresh.callCount == 1)
            #expect(refresh.wasCancelled)
        }
    }

    @Test func cancellingOneOfTwoRefreshWaitersLeavesTheRefreshRunning() async throws {
        let refresh = CancellableRefresh()
        var configuration = HTTPConnection.Configuration()
        configuration.authentication = HungRefreshProvider(refresh: refresh)
        try await withHTTP1Client(configuration: configuration) { client, server in
            let url = server.url("/echo")
            let first = Task {
                try await client.request(method: .get, url: url, headers: [:], body: nil)
            }
            await refresh.started.wait()
            let second = Task {
                try await client.request(method: .get, url: url, headers: [:], body: nil)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            first.cancel()
            // The cancelled waiter leaves at once; the other keeps the refresh alive.
            #expect(await waitForTask(first, seconds: 2))
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(!refresh.wasCancelled)
            second.cancel()
            #expect(await waitForTask(second, seconds: 2))
            #expect(await waitForTask(Task { await refresh.finished.wait() }, seconds: 2))
            #expect(refresh.callCount == 1)
            #expect(refresh.wasCancelled)
        }
    }

    @Test func aOneShotBodyCannotBeRetried() async throws {
        var configuration = HTTPConnection.Configuration()
        configuration.authentication = ChallengeAuthenticationProvider(mode: .basic)
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

    @Test func concurrentGzipStreamsInflate() async throws {
        guard #available(anyAppleOS 26, *) else { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try await withHTTP3Client { client, server in
                        let gzip = try await client.request(
                            method: .get,
                            url: server.url("/gzip"),
                            headers: [:],
                            body: nil
                        )
                        #expect(gzip.body == Data("hello-gzip".utf8))
                        let streamed = try await client.requestStream(method: .get, url: server.url("/deflate"))
                        #expect(try await streamed.body.collect() == Data("hello-deflate".utf8))
                    }
                }
            }
            try await group.waitForAll()
        }
    }
}

private struct ChallengeCredential: HTTPAuthenticationCredential {}

private struct ChallengeAuthenticationProvider: HTTPAuthenticationProvider {
    enum Mode: Sendable {
        case basic
        case digest
        case routing
    }

    let mode: Mode

    func credential() async throws -> ChallengeCredential? {
        nil
    }

    func apply(_ credential: ChallengeCredential, to request: inout HTTPAuthenticationRequest) {}

    func isRequest(
        _ request: HTTPAuthenticationRequest,
        authenticatedWith credential: ChallengeCredential
    ) -> Bool {
        false
    }

    func refresh(
        _ credential: ChallengeCredential,
        after response: HTTPAuthenticationResponse?
    ) async throws -> ChallengeCredential {
        credential
    }

    func credentials(for challenges: [HTTPChallenge], url: URL) async -> HTTPCredentials? {
        switch mode {
        case .basic:
            .basic(username: "user", password: "secret")
        case .digest:
            .digest(username: "user", password: "secret")
        case .routing:
            if challenges.contains(where: { $0.scheme.lowercased() == "digest" }) {
                .digest(username: "user", password: "secret")
            } else if challenges.contains(where: { $0.scheme.lowercased() == "bearer" })
                        && !challenges.contains(where: { $0.scheme.lowercased() == "basic" }) {
                .bearer("token-1")
            } else {
                .basic(username: "user", password: "secret")
            }
        }
    }
}

private struct TestCredential: HTTPAuthenticationCredential {
    var token: String
    var requiresRefresh = false
}

private final class CancellableRefresh: @unchecked Sendable {
    let started = HoldGate()
    let finished = HoldGate()
    private let lock = NSLock()
    private var calls = 0
    private var cancelled = false

    func run() async throws -> TestCredential {
        recordCall()
        await started.signal()
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch {
            recordCancellation()
            await finished.signal()
            throw error
        }
        await finished.signal()
        return TestCredential(token: "fresh")
    }

    private func recordCall() {
        lock.lock()
        calls += 1
        lock.unlock()
    }

    private func recordCancellation() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private struct HungRefreshProvider: HTTPAuthenticationProvider {
    let refresh: CancellableRefresh

    func credential() async throws -> TestCredential? {
        TestCredential(token: "stale", requiresRefresh: true)
    }

    func apply(_ credential: TestCredential, to request: inout HTTPAuthenticationRequest) {
        request.headers[.authorization] = "Bearer \(credential.token)"
    }

    func refresh(
        _ credential: TestCredential,
        after response: HTTPAuthenticationResponse?
    ) async throws -> TestCredential {
        try await refresh.run()
    }
}

private final class BearerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var refreshes = 0

    func load() -> BearerToken {
        BearerToken("expired")
    }

    func refresh(_ old: BearerToken) -> BearerToken {
        lock.lock()
        refreshes += 1
        lock.unlock()
        return BearerToken("fresh")
    }

    var refreshCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return refreshes
    }
}

private struct TestAuthenticationProvider: HTTPAuthenticationProvider {
    let probe: AuthenticationProbe

    func credential() async throws -> TestCredential? {
        probe.load()
    }

    func apply(_ credential: TestCredential, to request: inout HTTPAuthenticationRequest) {
        request.headers[.authorization] = "Bearer \(credential.token)"
    }

    func isRequest(_ request: HTTPAuthenticationRequest, authenticatedWith credential: TestCredential) -> Bool {
        request.headers[.authorization] == "Bearer \(credential.token)"
    }

    func isAuthenticationFailure(_ response: HTTPAuthenticationResponse) -> Bool {
        guard response.head.status.code == 401 else {
            return false
        }
        let bearer = response.challenges.filter { $0.scheme.lowercased() == "bearer" }
        let failed = response.challenges.isEmpty || bearer.contains {
            guard let error = $0.parameters["error"]?.lowercased() else {
                return true
            }
            return error == "invalid_token"
        }
        if failed {
            probe.recordAuthenticationFailure()
        }
        return failed
    }

    func refresh(
        _ credential: TestCredential,
        after response: HTTPAuthenticationResponse?
    ) async throws -> TestCredential {
        try await probe.refresh()
    }
}

private enum AuthenticationTestError: Error {
    case refreshFailed
}

private actor AuthenticationRefreshGate {
    let started = HoldGate()
    let release = HoldGate()

    func wait() async {
        await started.signal()
        await release.wait()
    }
}

private final class AuthenticationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCredential: TestCredential
    private var loads = 0
    private var refreshes = 0
    private var failures = 0
    private let expectedFailures: Int?
    private let refreshGate: AuthenticationRefreshGate?
    private let refreshError: (any Error)?
    let allFailures = HoldGate()

    init(
        credential: TestCredential,
        expectedFailures: Int? = nil,
        refreshGate: AuthenticationRefreshGate? = nil,
        refreshError: (any Error)? = nil
    ) {
        storedCredential = credential
        self.expectedFailures = expectedFailures
        self.refreshGate = refreshGate
        self.refreshError = refreshError
    }

    func load() -> TestCredential {
        lock.lock()
        defer { lock.unlock() }
        loads += 1
        return storedCredential
    }

    func recordAuthenticationFailure() {
        lock.lock()
        failures += 1
        let complete = failures == expectedFailures
        lock.unlock()
        if complete {
            Task { await allFailures.signal() }
        }
    }

    func refresh() async throws -> TestCredential {
        let (refreshError, refreshGate) = beginRefresh()
        if let refreshGate {
            await refreshGate.wait()
        }
        if let refreshError {
            throw refreshError
        }
        return storeRefreshedCredential()
    }

    private func beginRefresh() -> ((any Error)?, AuthenticationRefreshGate?) {
        lock.lock()
        defer { lock.unlock() }
        refreshes += 1
        return (refreshError, refreshGate)
    }

    private func storeRefreshedCredential() -> TestCredential {
        lock.lock()
        defer { lock.unlock() }
        let credential = TestCredential(token: "fresh")
        storedCredential = credential
        return credential
    }

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loads
    }

    var refreshCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return refreshes
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
