//
//  HTTPAuthentication.swift
//  HTTPConnectionKit
//

import Foundation
import HTTPTypes

/// A credential that can be applied and renewed by an authentication provider.
public protocol HTTPAuthenticationCredential: Sendable {
    /// Whether the credential should be renewed before another request is sent.
    var requiresRefresh: Bool { get }
}

public extension HTTPAuthenticationCredential {
    var requiresRefresh: Bool { false }
}

/// The request information exposed to an authentication provider.
public struct HTTPAuthenticationRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var method: HTTPRequest.Method
    public var url: URL
    public var headers: HTTPFields

    public init(method: HTTPRequest.Method, url: URL, headers: HTTPFields) {
        self.method = method
        self.url = url
        self.headers = headers
    }

    public var description: String {
        var redacted = headers
        for name in [HTTPField.Name.authorization, .proxyAuthorization, .cookie] {
            if redacted[name] != nil {
                redacted[name] = "<redacted>"
            }
        }
        return "HTTPAuthenticationRequest(method: \(method.rawValue), url: \(url), headers: \(redacted))"
    }

    public var debugDescription: String { description }
}

/// The response information exposed to an authentication provider.
public struct HTTPAuthenticationResponse: Sendable {
    public var head: HTTPResponse
    public var challenges: [HTTPChallenge]
    public var body: Data?

    public init(head: HTTPResponse, challenges: [HTTPChallenge], body: Data?) {
        self.head = head
        self.challenges = challenges
        self.body = body
    }

    init(_ response: Response) {
        self.init(head: response.head, challenges: response.challenges, body: response.body)
    }
}

/// Supplies, applies, and renews one kind of HTTP credential.
///
/// Install a provider on `HTTPConnection.Configuration` to opt into preemptive authentication and
/// one authentication retry. Concurrent requests share one refresh operation.
public protocol HTTPAuthenticationProvider: Sendable {
    associatedtype Credential: HTTPAuthenticationCredential

    /// Loads the credential owned by this provider. This is called once by a client.
    func credential() async throws -> Credential?

    /// Applies a credential to an outgoing request.
    func apply(_ credential: Credential, to request: inout HTTPAuthenticationRequest)

    /// Validates a credential before it is applied.
    func validate(_ credential: Credential) throws

    /// Returns whether this response indicates that this provider's credential was rejected.
    func isAuthenticationFailure(_ response: HTTPAuthenticationResponse) -> Bool

    /// Returns whether the request was sent with this exact credential.
    func isRequest(_ request: HTTPAuthenticationRequest, authenticatedWith credential: Credential) -> Bool

    /// Renews a credential. `response` is nil when proactive renewal happens before a request.
    func refresh(
        _ credential: Credential,
        after response: HTTPAuthenticationResponse?
    ) async throws -> Credential

    /// Supplies credentials for an RFC 7235 challenge. The default declines the challenge.
    func credentials(for challenges: [HTTPChallenge], url: URL) async -> HTTPCredentials?

    /// Returns whether this provider applies to a URL.
    func applies(to url: URL) -> Bool

    /// Allows credentials to be applied after a redirect changes the origin.
    func allowsRedirect(to url: URL) -> Bool
}

public extension HTTPAuthenticationProvider {
    func validate(_ credential: Credential) throws {}

    func isAuthenticationFailure(_ response: HTTPAuthenticationResponse) -> Bool {
        guard response.head.status.code == 401 else {
            return false
        }
        if response.challenges.isEmpty {
            return true
        }
        let bearer = response.challenges.filter { $0.scheme.lowercased() == "bearer" }
        guard !bearer.isEmpty else {
            return false
        }
        return bearer.contains {
            guard let error = $0.parameters["error"]?.lowercased() else {
                return true
            }
            return error == "invalid_token"
        }
    }

    func credentials(for challenges: [HTTPChallenge], url: URL) async -> HTTPCredentials? {
        nil
    }

    func applies(to url: URL) -> Bool {
        true
    }

    func allowsRedirect(to url: URL) -> Bool {
        false
    }

    func isRequest(_ request: HTTPAuthenticationRequest, authenticatedWith credential: Credential) -> Bool {
        var applied = request
        apply(credential, to: &applied)
        return applied.headers == request.headers
    }
}

/// A bearer access token with optional expiry information.
public struct BearerToken: HTTPAuthenticationCredential, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var value: String
    public var expiresAt: Date?
    public var refreshLeeway: TimeInterval

    public init(
        _ value: String,
        expiresAt: Date? = nil,
        refreshLeeway: TimeInterval = 30
    ) {
        self.value = value
        self.expiresAt = expiresAt
        self.refreshLeeway = refreshLeeway
    }

    public var requiresRefresh: Bool {
        guard let expiresAt else { return false }
        return Date().addingTimeInterval(refreshLeeway) >= expiresAt
    }

    public var description: String {
        "BearerToken(<redacted>, expiresAt: \(String(describing: expiresAt)))"
    }

    public var debugDescription: String { description }
}

/// The common bearer-token authentication provider.
public struct BearerTokenProvider: HTTPAuthenticationProvider {
    private let load: @Sendable () async throws -> BearerToken?
    private let renew: @Sendable (BearerToken) async throws -> BearerToken
    private let scope: @Sendable (URL) -> Bool
    private let widensRedirectScope: Bool

    public init(
        load: @escaping @Sendable () async throws -> BearerToken?,
        refresh: @escaping @Sendable (BearerToken) async throws -> BearerToken,
        appliesTo: (@Sendable (URL) -> Bool)? = nil
    ) {
        self.load = load
        renew = refresh
        scope = appliesTo ?? { $0.scheme?.lowercased() == "https" }
        widensRedirectScope = appliesTo != nil
    }

    public func credential() async throws -> BearerToken? {
        try await load()
    }

    public func apply(_ credential: BearerToken, to request: inout HTTPAuthenticationRequest) {
        request.headers[.authorization] = "Bearer \(credential.value)"
    }

    public func validate(_ credential: BearerToken) throws {
        guard HTTPField.isValidValue("Bearer \(credential.value)") else {
            throw HTTPConnectionError.invalidRequest
        }
    }

    public func isRequest(
        _ request: HTTPAuthenticationRequest,
        authenticatedWith credential: BearerToken
    ) -> Bool {
        request.headers[.authorization] == "Bearer \(credential.value)"
    }

    public func refresh(
        _ credential: BearerToken,
        after response: HTTPAuthenticationResponse?
    ) async throws -> BearerToken {
        try await renew(credential)
    }

    public func applies(to url: URL) -> Bool {
        scope(url)
    }

    public func allowsRedirect(to url: URL) -> Bool {
        widensRedirectScope && scope(url)
    }
}

/// Bounds repeated refreshes without scheduling a retry timer.
public struct HTTPAuthenticationRefreshWindow: Sendable, Equatable {
    public var maximumAttempts: Int
    public var interval: HTTPConnection.Configuration.Interval

    public init(
        maximumAttempts: Int = 5,
        interval: HTTPConnection.Configuration.Interval = .seconds(30)
    ) {
        self.maximumAttempts = maximumAttempts
        self.interval = interval
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.maximumAttempts == rhs.maximumAttempts
            && lhs.interval.nanoseconds == rhs.interval.nanoseconds
    }
}

protocol HTTPAuthenticationSession: Sendable {
    func prepare(_ request: HTTPAuthenticationRequest) async throws -> HTTPAuthenticationRequest
    func retry(
        _ request: HTTPAuthenticationRequest,
        after response: HTTPAuthenticationResponse
    ) async throws -> HTTPAuthenticationRequest?
    func credentials(for challenges: [HTTPChallenge], url: URL) async -> HTTPCredentials?
    func applies(to url: URL) async -> Bool
    func allowsRedirect(to url: URL) async -> Bool
}

actor ProviderAuthenticationSession<Provider: HTTPAuthenticationProvider>: HTTPAuthenticationSession {
    private let provider: Provider
    private let window: HTTPAuthenticationRefreshWindow
    private var didLoadCredential = false
    private var currentCredential: Provider.Credential?
    private var refresh: SharedRefresh?
    private var nextRefreshID = 0
    private var nextWaiterID = 0
    private var refreshDates: [Date] = []

    /// One in-flight refresh and the requests waiting on it.
    ///
    /// Waiters hold continuations rather than awaiting `Task.value`, so a cancelled request leaves
    /// immediately. When the last waiter leaves, the refresh itself is cancelled.
    private struct SharedRefresh {
        let id: Int
        let task: Task<Void, Never>
        var waiters: [Int: CheckedContinuation<Provider.Credential, Error>] = [:]
    }

    init(provider: Provider, window: HTTPAuthenticationRefreshWindow) {
        self.provider = provider
        self.window = window
    }

    func prepare(_ request: HTTPAuthenticationRequest) async throws -> HTTPAuthenticationRequest {
        guard provider.applies(to: request.url) else {
            return request
        }
        var request = request
        guard var credential = try await credential() else {
            return request
        }
        if credential.requiresRefresh {
            credential = try await refreshed(credential, after: nil)
        }
        try provider.validate(credential)
        provider.apply(credential, to: &request)
        try Self.validate(request)
        return request
    }

    func retry(
        _ request: HTTPAuthenticationRequest,
        after response: HTTPAuthenticationResponse
    ) async throws -> HTTPAuthenticationRequest? {
        guard provider.applies(to: request.url), provider.isAuthenticationFailure(response) else {
            return nil
        }
        guard let credential = try await credential() else {
            return nil
        }
        var request = request
        if !provider.isRequest(request, authenticatedWith: credential) {
            try provider.validate(credential)
            provider.apply(credential, to: &request)
            try Self.validate(request)
            return request
        }
        let renewed = try await refreshed(credential, after: response)
        try provider.validate(renewed)
        provider.apply(renewed, to: &request)
        try Self.validate(request)
        return request
    }

    func credentials(for challenges: [HTTPChallenge], url: URL) async -> HTTPCredentials? {
        guard provider.applies(to: url) else { return nil }
        return await provider.credentials(for: challenges, url: url)
    }

    func applies(to url: URL) -> Bool {
        provider.applies(to: url)
    }

    func allowsRedirect(to url: URL) -> Bool {
        provider.allowsRedirect(to: url)
    }

    private static func validate(_ request: HTTPAuthenticationRequest) throws {
        guard request.headers.allSatisfy({ HTTPField.isValidValue($0.value) }) else {
            throw HTTPConnectionError.invalidRequest
        }
    }

    private func credential() async throws -> Provider.Credential? {
        if !didLoadCredential {
            currentCredential = try await provider.credential()
            didLoadCredential = true
        }
        return currentCredential
    }

    private func refreshed(
        _ credential: Provider.Credential,
        after response: HTTPAuthenticationResponse?
    ) async throws -> Provider.Credential {
        try Task.checkCancellation()
        if refresh == nil {
            try recordRefresh()
            let provider = provider
            let id = nextRefreshID
            nextRefreshID += 1
            let task = Task {
                let result: Result<Provider.Credential, Error>
                do {
                    result = .success(try await provider.refresh(credential, after: response))
                } catch {
                    result = .failure(error)
                }
                self.completeRefresh(id, result: result)
            }
            refresh = SharedRefresh(id: id, task: task)
        }
        return try await joinRefresh()
    }

    private func joinRefresh() async throws -> Provider.Credential {
        let waiterID = nextWaiterID
        nextWaiterID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard refresh != nil, !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                refresh?.waiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.leaveRefresh(waiterID) }
        }
    }

    /// Removes a cancelled waiter. The last one to leave cancels the refresh and detaches it, so a
    /// later request starts its own instead of inheriting a cancelled one.
    private func leaveRefresh(_ waiterID: Int) {
        guard let continuation = refresh?.waiters.removeValue(forKey: waiterID) else {
            return
        }
        continuation.resume(throwing: CancellationError())
        if let current = refresh, current.waiters.isEmpty {
            refresh = nil
            current.task.cancel()
        }
    }

    private func completeRefresh(_ id: Int, result: Result<Provider.Credential, Error>) {
        guard let current = refresh, current.id == id else {
            // A detached refresh that still produced a credential is worth keeping.
            if refresh == nil, case .success(let credential) = result {
                currentCredential = credential
            }
            return
        }
        refresh = nil
        if case .success(let credential) = result {
            currentCredential = credential
        }
        for waiter in current.waiters.values {
            waiter.resume(with: result)
        }
    }

    private func recordRefresh(now: Date = Date()) throws {
        let seconds = TimeInterval(window.interval.nanoseconds) / 1_000_000_000
        refreshDates.removeAll { now.timeIntervalSince($0) >= seconds }
        guard window.maximumAttempts > 0, refreshDates.count < window.maximumAttempts else {
            throw HTTPConnectionError.authenticationRefreshLimitExceeded
        }
        refreshDates.append(now)
    }
}

func makeAuthenticationSession(
    _ provider: any HTTPAuthenticationProvider,
    window: HTTPAuthenticationRefreshWindow
) -> any HTTPAuthenticationSession {
    func open<Provider: HTTPAuthenticationProvider>(
        _ provider: Provider
    ) -> any HTTPAuthenticationSession {
        ProviderAuthenticationSession(provider: provider, window: window)
    }
    return open(provider)
}
