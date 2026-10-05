//
//  HTTPRequestPipeline.swift
//  HTTPConnectionKit
//

import Foundation
import HTTPTypes
import NIOCore
import NIOHTTP1
import NIOHTTPTypes
import NIOHTTPCompression

private struct AuthenticationOrigin: Equatable {
    var scheme: String?
    var host: String?
    var port: Int?

    init(_ url: URL) {
        scheme = url.scheme?.lowercased()
        host = url.host?.lowercased()
        if let port = url.port {
            self.port = port
        } else {
            self.port = scheme == "https" ? 443 : scheme == "http" ? 80 : nil
        }
    }
}

extension HTTPConnection {
    func requestPrepared(
        method: HTTPRequest.Method,
        url: URL,
        headers: HTTPFields,
        body: HTTPBody?,
        collect: Bool
    ) async throws -> RequestResult {
        guard let timeout = configuration.requestTimeout else {
            return try await requestPreparedWithoutTimeout(
                method: method,
                url: url,
                headers: headers,
                body: body,
                collect: collect
            )
        }
        return try await withThrowingTaskGroup(of: RequestResult.self) { group in
            group.addTask {
                try await self.requestPreparedWithoutTimeout(
                    method: method,
                    url: url,
                    headers: headers,
                    body: body,
                    collect: collect
                )
            }
            group.addTask {
                let nanoseconds = UInt64(max(timeout.nanoseconds, 0))
                try await Task.sleep(nanoseconds: nanoseconds)
                throw HTTPConnectionError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw HTTPConnectionError.invalidRequest
            }
            return first
        }
    }

    private func requestPreparedWithoutTimeout(
        method: HTTPRequest.Method,
        url: URL,
        headers: HTTPFields,
        body: HTTPBody?,
        collect: Bool
    ) async throws -> RequestResult {
        if method == .connect {
            throw HTTPConnectionError.unimplemented
        }
        var method = method
        var url = url
        var headers = headers
        var body = body
        var redirectCount = 0
        var challengeRetries = 0
        var authenticationRetried = false
        var digestNonceCount = 1
        var previousSite: String?
        let authenticationOrigin = AuthenticationOrigin(url)

        while true {
            let components = try requestComponents(from: url)
            headers = await preparedHeaders(
                headers,
                url: url,
                method: method,
                previousSite: previousSite
            )
            if let authenticationSession {
                let sameOrigin = AuthenticationOrigin(url) == authenticationOrigin
                let allowed = sameOrigin
                    ? await authenticationSession.applies(to: url)
                    : await authenticationSession.allowsRedirect(to: url)
                if allowed {
                var request = HTTPAuthenticationRequest(method: method, url: url, headers: headers)
                do {
                    request = try await authenticationSession.prepare(request)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as HTTPConnectionError {
                    throw error
                } catch {
                    throw HTTPConnectionError.authenticationFailed(error)
                }
                headers = request.headers
                }
            }
            previousSite = CookieJar.registrableDomain(
                host: url.host?.lowercased() ?? "",
                list: BundledPublicSuffixList()
            )

            let result = try await performSingleExchange(
                method: method,
                components: components,
                headers: headers,
                body: body,
                collect: collect
            )

            switch result {
            case .collected(let response):
                let response = Response(head: stripInflatedEncoding(response.head), body: response.body)
                await configuration.cookieJar.store(response: response.head.headerFields, from: url)
                if try await applyProviderAuthenticationIfNeeded(
                    response: response,
                    method: method,
                    url: url,
                    headers: &headers,
                    body: body,
                    alreadyRetried: &authenticationRetried
                ) {
                    continue
                }
                if try await applyChallengeAuthenticationIfNeeded(
                    response: response,
                    method: &method,
                    url: url,
                    headers: &headers,
                    body: body,
                    challengeRetries: &challengeRetries,
                    digestNonceCount: &digestNonceCount
                ) {
                    continue
                }
                if configuration.followRedirects, let next = try redirectTarget(
                    response: response,
                    current: url,
                    method: &method,
                    body: &body,
                    headers: &headers,
                    redirectCount: &redirectCount
                ) {
                    url = next
                    continue
                }
                return .collected(response)
            case .streaming(var streamed):
                streamed.head = stripInflatedEncoding(streamed.head)
                await configuration.cookieJar.store(response: streamed.head.headerFields, from: url)
                let status = streamed.head.status.code
                let hasAuthenticationHandler = status == 401 && authenticationSession != nil
                    || status == 407 && proxyAuthenticationSession != nil
                if hasAuthenticationHandler || shouldFollow(status: status) {
                    let collected = try await collectStream(streamed)
                    if try await applyProviderAuthenticationIfNeeded(
                        response: collected,
                        method: method,
                        url: url,
                        headers: &headers,
                        body: body,
                        alreadyRetried: &authenticationRetried
                    ) {
                        continue
                    }
                    if try await applyChallengeAuthenticationIfNeeded(
                        response: collected,
                        method: &method,
                        url: url,
                        headers: &headers,
                        body: body,
                        challengeRetries: &challengeRetries,
                        digestNonceCount: &digestNonceCount
                    ) {
                        continue
                    }
                    if shouldFollow(status: status), let next = try redirectTarget(
                        response: collected,
                        current: url,
                        method: &method,
                        body: &body,
                        headers: &headers,
                        redirectCount: &redirectCount
                    ) {
                        url = next
                        continue
                    }
                    return .collected(collected)
                }
                return .streaming(streamed)
            }
        }
    }

    private func stripInflatedEncoding(_ head: HTTPResponse) -> HTTPResponse {
        guard configuration.decompressResponses, let encoding = head.headerFields[.contentEncoding] else {
            return head
        }
        let remaining = encoding
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.lowercased() != "gzip" && $0.lowercased() != "deflate" }
        var head = head
        if remaining.isEmpty {
            head.headerFields[.contentEncoding] = nil
        } else {
            head.headerFields[.contentEncoding] = remaining.joined(separator: ", ")
        }
        return head
    }

    private func shouldFollow(status: Int) -> Bool {
        configuration.followRedirects && isRedirect(status)
    }

    private func preparedHeaders(
        _ headers: HTTPFields,
        url: URL,
        method: HTTPRequest.Method,
        previousSite: String?
    ) async -> HTTPFields {
        var headers = headers
        if configuration.decompressResponses, headers[.acceptEncoding] == nil {
            headers[.acceptEncoding] = "deflate, gzip"
        }
        let host = url.host?.lowercased() ?? ""
        let site = CookieJar.registrableDomain(host: host, list: BundledPublicSuffixList())
        let crossSite = previousSite.map { $0 != site } ?? false
        if headers[.cookie] == nil {
            if let cookie = await configuration.cookieJar.cookieHeader(
                for: url,
                method: method,
                crossSite: crossSite
            ) {
                headers[.cookie] = cookie
            }
        }
        return headers
    }

    private func applyProviderAuthenticationIfNeeded(
        response: Response,
        method: HTTPRequest.Method,
        url: URL,
        headers: inout HTTPFields,
        body: HTTPBody?,
        alreadyRetried: inout Bool
    ) async throws -> Bool {
        guard !alreadyRetried, response.head.status.code == 401, let authenticationSession else {
            return false
        }
        let request = HTTPAuthenticationRequest(method: method, url: url, headers: headers)
        let retry: HTTPAuthenticationRequest?
        do {
            retry = try await authenticationSession.retry(request, after: HTTPAuthenticationResponse(response))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HTTPConnectionError {
            throw error
        } catch {
            throw HTTPConnectionError.authenticationFailed(error)
        }
        guard let retry else {
            return false
        }
        if body.map(\.isReplayable) == false {
            throw HTTPConnectionError.unreplayableBody
        }
        headers = retry.headers
        alreadyRetried = true
        return true
    }

    private func applyChallengeAuthenticationIfNeeded(
        response: Response,
        method: inout HTTPRequest.Method,
        url: URL,
        headers: inout HTTPFields,
        body: HTTPBody?,
        challengeRetries: inout Int,
        digestNonceCount: inout Int
    ) async throws -> Bool {
        let status = response.head.status.code
        guard status == 401 || status == 407 else {
            return false
        }
        let session = status == 407 ? proxyAuthenticationSession : authenticationSession
        guard let session else {
            return false
        }
        let challenges = response.challenges
        guard !challenges.isEmpty else {
            return false
        }
        let digestStale = challenges.contains {
            $0.scheme.lowercased() == "digest" && $0.parameters["stale"]?.lowercased() == "true"
        }
        if challengeRetries >= 2 || (challengeRetries >= 1 && !digestStale) {
            return false
        }
        guard let credentials = await session.credentials(for: challenges, url: url) else {
            return false
        }
        guard let challenge = preferredChallenge(challenges, credentials: credentials) else {
            return false
        }
        if body.map(\.isReplayable) == false {
            throw HTTPConnectionError.unreplayableBody
        }
        let replayedBody: Data?
        if challenge.scheme.lowercased() == "digest", challenge.parameters["qop"]?.contains("auth-int") == true {
            replayedBody = try await body?.collect(upTo: configuration.maximumBufferedBodySize)
        } else {
            replayedBody = nil
        }
        guard let header = ChallengeAuthorization.header(
            challenge: challenge,
            credentials: credentials,
            method: method,
            uri: url.path.isEmpty ? "/" : url.path + (url.query.map { "?\($0)" } ?? ""),
            body: replayedBody,
            nonceCount: digestNonceCount
        ) else {
            return false
        }
        let name: HTTPField.Name = status == 407 ? .proxyAuthorization : header.name
        headers[name] = header.value
        challengeRetries += 1
        digestNonceCount += 1
        return true
    }

    private func preferredChallenge(
        _ challenges: [HTTPChallenge],
        credentials: HTTPCredentials
    ) -> HTTPChallenge? {
        if credentials.bearerToken != nil {
            return challenges.first { $0.scheme.lowercased() == "bearer" }
        }
        let digests = challenges.filter { $0.scheme.lowercased() == "digest" }
        if let sha = digests.first(where: {
            ($0.parameters["algorithm"] ?? "").uppercased().hasPrefix("SHA-256")
        }) {
            return sha
        }
        if let digest = digests.first {
            return digest
        }
        return challenges.first { $0.scheme.lowercased() == "basic" }
    }

    private func redirectTarget(
        response: Response,
        current: URL,
        method: inout HTTPRequest.Method,
        body: inout HTTPBody?,
        headers: inout HTTPFields,
        redirectCount: inout Int
    ) throws -> URL? {
        let status = response.head.status.code
        guard isRedirect(status) else {
            return nil
        }
        redirectCount += 1
        if redirectCount > configuration.maximumRedirects {
            throw HTTPConnectionError.tooManyRedirects
        }
        guard let location = response.head.headerFields[.location],
              let next = URL(string: location, relativeTo: current)?.absoluteURL
        else {
            throw HTTPConnectionError.invalidRequest
        }
        switch status {
        case 301, 302, 303:
            method = method == .head ? .head : .get
            body = nil
            headers[.contentLength] = nil
            headers[.contentType] = nil
            headers[.contentEncoding] = nil
            headers[.transferEncoding] = nil
        default:
            if body.map(\.isReplayable) == false {
                throw HTTPConnectionError.unreplayableBody
            }
        }
        if AuthenticationOrigin(next) != AuthenticationOrigin(current) {
            headers[.authorization] = nil
            headers[.proxyAuthorization] = nil
        }
        headers[.cookie] = nil
        var withoutHost = HTTPFields()
        for field in headers where field.name.canonicalName != "host" {
            withoutHost.append(field)
        }
        headers = withoutHost
        return next
    }

    private func isRedirect(_ status: Int) -> Bool {
        status == 301 || status == 302 || status == 303 || status == 307 || status == 308
    }

    private func collectStream(_ streamed: StreamingResponse) async throws -> Response {
        let body = try await streamed.body.collect(upTo: configuration.maximumBufferedBodySize)
        var head = streamed.head
        let trailers = await streamed.trailers()
        head.headerFields.append(contentsOf: trailers)
        return Response(head: head, body: body.isEmpty ? nil : body)
    }

    private func performSingleExchange(
        method: HTTPRequest.Method,
        components: RequestComponents,
        headers: HTTPFields,
        body: HTTPBody?,
        collect: Bool
    ) async throws -> RequestResult {
        let cancelTarget = CancelTarget()
        var context = ExchangeContext(
            method: method,
            components: components,
            headers: headers,
            body: body,
            requestVersion: HTTPVersion(major: version.major >= 2 ? 1 : version.major, minor: version.major >= 2 ? 1 : version.minor),
            expectContinueTimeout: configuration.expectContinueTimeout,
            onProgress: configuration.onProgress,
            usesHTTP1Chunked: false
        )
        return try await withTaskCancellationHandler {
            let connection = try await self.connection(for: components, cancelTarget: cancelTarget)
            if connection.created {
                cancelTarget.set(connection.channel, closesParent: true)
            }
            context.usesHTTP1Chunked = connection.version.major == 1 && connection.version.minor >= 1
            if connection.version == .http2 {
                let request = try await Self.openHTTP2Request(
                    on: connection.channel,
                    enableTLS: components.enableTLS,
                    cancelTarget: cancelTarget,
                    decompressionLimit: decompressionLimit
                )
                return try await self.runHTTP1Exchange(
                    request: request,
                    context: context,
                    requestVersion: .http1_1,
                    collect: collect,
                    cancelTarget: cancelTarget
                )
            } else if connection.version == .http3 {
                guard #available(anyAppleOS 26, *) else {
                    throw HTTPConnectionError.unimplemented
                }
                let request = try await Self.openHTTP3Request(
                    on: connection.channel,
                    cancelTarget: cancelTarget
                )
                return try await self.runHTTP3Exchange(
                    request: request,
                    context: context,
                    collect: collect,
                    cancelTarget: cancelTarget
                )
            } else {
                let request = try await Self.openHTTP1Request(
                    on: connection.channel,
                    cancelTarget: cancelTarget
                )
                return try await self.runHTTP1Exchange(
                    request: request,
                    context: context,
                    requestVersion: connection.version,
                    collect: collect,
                    cancelTarget: cancelTarget
                )
            }
        } onCancel: {
            cancelTarget.close()
        }
    }

    private var decompressionLimit: NIOHTTPDecompression.DecompressionLimit? {
        configuration.decompressResponses
            ? .ratio(max(configuration.decompressionRatioLimit, 1))
            : nil
    }

    static func writeOpeningHTTP1(
        _ context: ExchangeContext,
        outbound: NIOAsyncChannelOutboundWriter<HTTPClientRequestPart>,
        mailbox: InboundMailbox<HTTPClientResponsePart>
    ) async throws -> HTTPResponseHead? {
        let expectsContinue = context.headers[HTTPField.Name("expect")!]?.lowercased() == "100-continue"
        if expectsContinue {
            let headers = http1Headers(
                components: context.components,
                headers: context.headers,
                length: context.body?.length,
                chunkUnknown: context.usesHTTP1Chunked
            )
            let head = HTTPRequestHead(
                version: context.requestVersion,
                method: HTTPMethod(rawValue: context.method.rawValue),
                uri: context.components.path,
                headers: headers
            )
            try await outbound.write(.head(head))
            let timeout = UInt64(max(context.expectContinueTimeout.nanoseconds, 1))
            if let part = try await mailbox.next(timeoutNanoseconds: timeout) {
                if case .head(let received) = part, !isInformational(received.status.code) {
                    return received
                }
            }
            try await writeHTTP1Body(context.body, outbound: outbound, progress: context.onProgress)
            try await outbound.write(.end(nil))
            return nil
        }
        try await writeHTTP1Request(context, outbound: outbound)
        return nil
    }

    private func runHTTP1Exchange(
        request: NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>,
        context: ExchangeContext,
        requestVersion: HTTPVersion,
        collect: Bool,
        cancelTarget: CancelTarget
    ) async throws -> RequestResult {
        var context = context
        context.requestVersion = requestVersion
        if collect {
            do {
                return try await request.executeThenClose { inbound, outbound in
                    let mailbox = InboundMailbox<HTTPClientResponsePart>()
                    let reader = Task {
                        do {
                            for try await part in inbound {
                                await mailbox.yield(part)
                            }
                            await mailbox.finish()
                        } catch {
                            await mailbox.fail(Self.mapDecompression(error))
                        }
                    }
                    defer { reader.cancel() }
                    let peeked = try await Self.writeOpeningHTTP1(
                        context,
                        outbound: outbound,
                        mailbox: mailbox
                    )
                    let response = try await Self.collectHTTP1(
                        inboundNext: { try await mailbox.next() },
                        firstHead: peeked,
                        progress: context.onProgress,
                        expected: peeked.map { Int64($0.headers["content-length"].first.flatMap(Int64.init) ?? 0) },
                        maximumBodySize: max(configuration.maximumBufferedBodySize, 0)
                    )
                    return RequestResult.collected(response)
                }
            } catch {
                throw Self.mapDecompression(error)
            }
        }

        let mailbox = InboundMailbox<HTTPClientResponsePart>()
        let trailerBox = TrailerBox()
        let box = HTTP1RequestBox(request)
        let capturedContext = context
        let task = Task.detached {
            await pumpHTTP1(box: box, context: capturedContext, mailbox: mailbox)
        }
        let lifetime = StreamLifetime(task: task)
        let head = try await Self.readFinalHTTP1Head(mailbox: mailbox)
        let expected = Self.expectedDownload(head)
        let progress = context.onProgress
        let completed = ProgressCounter()
        let httpBody = HTTPBody.oneShot(lifetime: lifetime) {
            do {
                while let part = try await mailbox.next() {
                    switch part {
                    case .head:
                        continue
                    case .body(let buffer):
                        let data = Data(buffer.readableBytesView)
                        completed.value += Int64(data.count)
                        progress?(HTTPProgress(direction: .download, completed: completed.value, expected: expected))
                        return data
                    case .end(let trailers):
                        var fields = HTTPFields()
                        if let trailers {
                            for trailer in trailers {
                                if let name = HTTPField.Name(trailer.name) {
                                    fields.append(HTTPField(name: name, value: trailer.value))
                                }
                            }
                        }
                        await trailerBox.set(fields)
                        return nil
                    }
                }
                await trailerBox.set(HTTPFields())
                return nil
            } catch {
                throw Self.mapDecompression(error)
            }
        }
        _ = cancelTarget
        return .streaming(StreamingResponse(head: head, body: httpBody, trailerBox: trailerBox))
    }

    static func mapDecompression(_ error: Error) -> Error {
        if let decompression = error as? NIOHTTPDecompression.DecompressionError {
            switch decompression {
            case .limit:
                return HTTPConnectionError.decompressionLimit
            default:
                return error
            }
        }
        return error
    }

    private static func readFinalHTTP1Head(
        mailbox: InboundMailbox<HTTPClientResponsePart>
    ) async throws -> HTTPResponse {
        while let part = try await mailbox.next() {
            if case .head(let received) = part, !isInformational(received.status.code) {
                return try httpResponse(head: received)
            }
        }
        throw HTTPConnectionError.invalidRequest
    }

    @available(anyAppleOS 26, *)
    private func runHTTP3Exchange(
        request: NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>,
        context: ExchangeContext,
        collect: Bool,
        cancelTarget: CancelTarget
    ) async throws -> RequestResult {
        if collect {
            do {
                return try await request.executeThenClose { inbound, outbound in
                    try await Self.writeHTTP3Request(context, outbound: outbound)
                    let response = try await Self.collectHTTP3(
                        inbound: inbound,
                        progress: context.onProgress,
                        maximumBodySize: max(configuration.maximumBufferedBodySize, 0)
                    )
                    return RequestResult.collected(try self.inflateIfNeeded(response))
                }
            } catch {
                throw Self.mapDecompression(error)
            }
        }
        let mailbox = InboundMailbox<HTTPResponsePart>()
        let trailerBox = TrailerBox()
        let box = HTTP3RequestBox(request)
        let capturedContext = context
        let bodyAlreadyOnWire = context.body == nil
        if bodyAlreadyOnWire {
            do {
                try await Self.writeEmptyHTTP3Request(on: request.channel, context: context)
            } catch {
                request.channel.close(promise: nil)
                throw error
            }
        }
        let task = Task.detached {
            await pumpHTTP3(
                box: box,
                context: capturedContext,
                mailbox: mailbox,
                writesRequest: !bodyAlreadyOnWire
            )
        }
        let lifetime = StreamLifetime(task: task)
        var head: HTTPResponse?
        while let part = try await mailbox.next() {
            if case .head(let received) = part, !Self.isInformational(UInt(received.status.code)) {
                head = received
                break
            }
        }
        guard var head else {
            throw HTTPConnectionError.invalidRequest
        }
        let encoding = head.headerFields[.contentEncoding]?.lowercased()
        let inflate = configuration.decompressResponses && (encoding == "gzip" || encoding == "deflate")
        if inflate {
            head.headerFields[.contentEncoding] = nil
            head.headerFields[.contentLength] = nil
        }
        let expected = inflate ? nil : Self.expectedDownload(head)
        let progress = context.onProgress
        let completed = ProgressCounter()
        let inflater: ZlibInflater? = inflate
            ? ZlibInflater(
                format: encoding == "gzip" ? .gzip : .deflate,
                ratioLimit: configuration.decompressionRatioLimit
            )
            : nil
        let httpBody = HTTPBody.oneShot(lifetime: lifetime) {
            do {
                while let part = try await mailbox.next() {
                    switch part {
                    case .head:
                        continue
                    case .body(let buffer):
                        let data = Data(buffer.readableBytesView)
                        if let inflater {
                            let inflated = try inflater.push(data)
                            if inflated.isEmpty {
                                continue
                            }
                            completed.value += Int64(inflated.count)
                            progress?(HTTPProgress(direction: .download, completed: completed.value, expected: expected))
                            return inflated
                        }
                        completed.value += Int64(data.count)
                        progress?(HTTPProgress(direction: .download, completed: completed.value, expected: expected))
                        return data
                    case .end(let trailers):
                        await trailerBox.set(trailers ?? HTTPFields())
                        if let inflater {
                            let tail = try inflater.finish()
                            if !tail.isEmpty {
                                completed.value += Int64(tail.count)
                                progress?(HTTPProgress(direction: .download, completed: completed.value, expected: expected))
                                return tail
                            }
                        }
                        return nil
                    }
                }
                await trailerBox.set(HTTPFields())
                return nil
            } catch {
                throw Self.mapDecompression(error)
            }
        }
        _ = cancelTarget
        return .streaming(StreamingResponse(head: head, body: httpBody, trailerBox: trailerBox))
    }

    private func inflateIfNeeded(_ response: Response) throws -> Response {
        guard configuration.decompressResponses else {
            return response
        }
        let encoding = response.head.headerFields[.contentEncoding]?.lowercased()
        guard encoding == "gzip" || encoding == "deflate" else {
            return response
        }
        let inflater = ZlibInflater(
            format: encoding == "gzip" ? .gzip : .deflate,
            ratioLimit: configuration.decompressionRatioLimit
        )
        var data = try inflater.push(response.body ?? Data())
        data.append(try inflater.finish())
        guard data.count <= max(configuration.maximumBufferedBodySize, 0) else {
            throw HTTPConnectionError.responseTooLarge
        }
        var head = response.head
        head.headerFields[.contentEncoding] = nil
        head.headerFields[.contentLength] = String(data.count)
        return Response(head: head, body: data.isEmpty ? nil : data)
    }

    public func resumeDownload(from url: URL, to fileURL: URL) async throws -> Response {
        let sidecar = URL(fileURLWithPath: fileURL.path + ".http-range")
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let existing = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        var headers = HTTPFields()
        if existing > 0 {
            headers[.range] = "bytes=\(existing)-"
            if let validator = try? String(contentsOf: sidecar, encoding: .utf8) {
                let trimmed = validator.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("etag:") {
                    headers[.ifRange] = String(trimmed.dropFirst(5))
                } else if trimmed.hasPrefix("last-modified:") {
                    headers[.ifRange] = String(trimmed.dropFirst(14))
                }
            }
        }
        let response = try await request(method: .get, url: url, headers: headers, body: nil)
        let data = response.body ?? Data()
        let replace: Bool
        if response.head.status.code == 206 {
            let range = response.head.headerFields[.contentRange] ?? ""
            replace = !range.contains("bytes \(existing)-")
        } else {
            replace = true
        }
        if replace {
            try data.write(to: fileURL, options: .atomic)
        } else {
            if let handle = FileHandle(forWritingAtPath: fileURL.path) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL)
            }
        }
        var validator = ""
        if let etag = response.head.headerFields[.eTag] {
            validator = "etag:\(etag)"
        } else if let modified = response.head.headerFields[.lastModified] {
            validator = "last-modified:\(modified)"
        }
        if !validator.isEmpty {
            try validator.write(to: sidecar, atomically: true, encoding: .utf8)
        }
        return response
    }
}

func pumpHTTP1(
    box: HTTP1RequestBox,
    context: ExchangeContext,
    mailbox: InboundMailbox<HTTPClientResponsePart>
) async {
    await withTaskCancellationHandler {
        do {
            try await box.request.executeThenClose { inbound, outbound in
                let reader = Task {
                    do {
                        for try await part in inbound {
                            await mailbox.yield(part)
                        }
                        await mailbox.finish()
                    } catch {
                        await mailbox.fail(HTTPConnection.mapDecompression(error))
                    }
                }
                defer { reader.cancel() }
                _ = try await HTTPConnection.writeOpeningHTTP1(context, outbound: outbound, mailbox: mailbox)
                await reader.value
            }
        } catch {
            await mailbox.fail(HTTPConnection.mapDecompression(error))
        }
    } onCancel: {
        // Closing the request channel ends the inbound stream, which is the only way the reader
        // task above can finish while the server is still sending.
        box.request.channel.close(promise: nil)
        Task { await mailbox.fail(CancellationError()) }
    }
}

@available(anyAppleOS 26, *)
func pumpHTTP3(
    box: HTTP3RequestBox,
    context: ExchangeContext,
    mailbox: InboundMailbox<HTTPResponsePart>,
    writesRequest: Bool = true
) async {
    await withTaskCancellationHandler {
        do {
            try await box.request.executeThenClose { inbound, outbound in
                if writesRequest {
                    try await HTTPConnection.writeHTTP3Request(context, outbound: outbound)
                }
                do {
                    for try await part in inbound {
                        await mailbox.yield(part)
                    }
                    await mailbox.finish()
                } catch {
                    await mailbox.fail(HTTPConnection.mapDecompression(error))
                }
            }
        } catch {
            await mailbox.fail(HTTPConnection.mapDecompression(error))
        }
    } onCancel: {
        box.request.channel.close(promise: nil)
        Task { await mailbox.fail(CancellationError()) }
    }
}

enum RequestResult: Sendable {
    case collected(Response)
    case streaming(StreamingResponse)
}
