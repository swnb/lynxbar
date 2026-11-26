import AppKit
import Darwin
import Foundation
import os
import SwiftUI
import XCTest
@testable import LynxBar

// MARK: - Deterministic Clock & Sleeper

/// Thread-safe deterministic clock for opaque-box E2E tests under Swift 6 strict concurrency.
final class E2ETestClock: Sendable {
    private let currentDate: OSAllocatedUnfairLock<Date>

    init(_ initial: Date = Date(timeIntervalSince1970: 1_760_000_000)) {
        self.currentDate = OSAllocatedUnfairLock(initialState: initial)
    }

    var now: Date {
        currentDate.withLock { $0 }
    }

    func set(_ date: Date) {
        currentDate.withLock { $0 = date }
    }

    func advance(by seconds: TimeInterval) {
        currentDate.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    func makeProvider() -> @Sendable () -> Date {
        { [self] in self.now }
    }
}

/// Deterministic virtual sleeper allowing tests to observe requested sleep intervals and step polling loops without wall-clock waits.
actor E2EVirtualSleeper {
    private struct Waiter {
        let id: UUID
        let duration: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }

    private(set) var recordedDelays: [TimeInterval] = []
    private var waiters: [Waiter] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep(_ duration: TimeInterval) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                recordedDelays.append(duration)
                waiters.append(Waiter(id: id, duration: duration, continuation: continuation))
                let observers = arrivalWaiters
                arrivalWaiters.removeAll()
                for observer in observers {
                    observer.resume()
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    var pendingCount: Int { waiters.count }

    func waitUntilPendingCount(atLeast expected: Int, maxYields: Int = 200) async {
        for _ in 0..<maxYields {
            if waiters.count >= expected { return }
            await withCheckedContinuation { continuation in
                if waiters.count >= expected {
                    continuation.resume()
                } else {
                    arrivalWaiters.append(continuation)
                }
            }
        }
    }

    @discardableResult
    func resumeNext() -> TimeInterval? {
        guard !waiters.isEmpty else { return nil }
        let waiter = waiters.removeFirst()
        waiter.continuation.resume()
        return waiter.duration
    }

    func resumeAll() {
        let current = waiters
        waiters.removeAll()
        for waiter in current {
            waiter.continuation.resume()
        }
    }

    func cancelAll() {
        let current = waiters
        waiters.removeAll()
        for waiter in current {
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

// MARK: - HTTP & Provider Test Doubles

/// Scripted `AIUsageHTTPTransport` recording outbound requests without making any live network calls.
actor E2ERecordingHTTPTransport: AIUsageHTTPTransport {
    typealias Handler = @Sendable (URLRequest, Int) async throws -> (Data, HTTPURLResponse)

    private(set) var requests: [URLRequest] = []
    private var scriptedQueue: [Result<(Data, HTTPURLResponse), Error>] = []
    private let handler: Handler?

    init(scriptedQueue: [Result<(Data, HTTPURLResponse), Error>]) {
        self.scriptedQueue = scriptedQueue
        self.handler = nil
    }

    init(handler: @escaping Handler) {
        self.scriptedQueue = []
        self.handler = handler
    }

    var callCount: Int { requests.count }

    func enqueue(_ result: Result<(Data, HTTPURLResponse), Error>) {
        scriptedQueue.append(result)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = requests.count
        requests.append(request)

        if let handler {
            return try await handler(request, index)
        }
        if !scriptedQueue.isEmpty {
            let next = scriptedQueue.removeFirst()
            return try next.get()
        }
        throw URLError(.badServerResponse)
    }

    static func makeResponse(
        url: URL,
        statusCode: Int,
        headers: [String: String] = [:]
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }
}

/// Spy `ClaudeCredentialReading` counting reads without touching macOS Keychain or `~/.claude`.
final class E2ESpyClaudeCredentialReader: ClaudeCredentialReading, Sendable {
    private let state: OSAllocatedUnfairLock<(callCount: Int, handler: @Sendable (Date) -> Result<ClaudeOAuthCredentials, AIUsageFetchError>)>

    init(handler: @escaping @Sendable (Date) -> Result<ClaudeOAuthCredentials, AIUsageFetchError>) {
        self.state = OSAllocatedUnfairLock(initialState: (0, handler))
    }

    convenience init(result: Result<ClaudeOAuthCredentials, AIUsageFetchError>) {
        self.init { _ in result }
    }

    var callCount: Int {
        state.withLock { $0.callCount }
    }

    func setResult(_ result: Result<ClaudeOAuthCredentials, AIUsageFetchError>) {
        state.withLock { $0.handler = { _ in result } }
    }

    func readCredentials(now: Date) -> Result<ClaudeOAuthCredentials, AIUsageFetchError> {
        let handler = state.withLock { box -> @Sendable (Date) -> Result<ClaudeOAuthCredentials, AIUsageFetchError> in
            box.callCount += 1
            return box.handler
        }
        return handler(now)
    }
}

/// Spy `CodexCredentialReading` counting reads without touching `~/.codex`.
final class E2ESpyCodexCredentialReader: CodexCredentialReading, Sendable {
    private let state: OSAllocatedUnfairLock<(callCount: Int, handler: @Sendable (Date) -> Result<CodexOAuthCredentials, AIUsageFetchError>)>

    init(handler: @escaping @Sendable (Date) -> Result<CodexOAuthCredentials, AIUsageFetchError>) {
        self.state = OSAllocatedUnfairLock(initialState: (0, handler))
    }

    convenience init(result: Result<CodexOAuthCredentials, AIUsageFetchError>) {
        self.init { _ in result }
    }

    var callCount: Int {
        state.withLock { $0.callCount }
    }

    func setResult(_ result: Result<CodexOAuthCredentials, AIUsageFetchError>) {
        state.withLock { $0.handler = { _ in result } }
    }

    func readCredentials(now: Date) -> Result<CodexOAuthCredentials, AIUsageFetchError> {
        let handler = state.withLock { box -> @Sendable (Date) -> Result<CodexOAuthCredentials, AIUsageFetchError> in
            box.callCount += 1
            return box.handler
        }
        return handler(now)
    }
}

/// Scriptable `AIUsageProvider` actor for testing ViewModel state transitions, single-flight, and backoff.
actor E2ESpyAIUsageProvider: AIUsageProvider {
    nonisolated let id: AIUsageProviderID

    private(set) var callCount: Int = 0
    private(set) var recordedDates: [Date] = []
    private var scriptedResults: [Result<AIProviderQuotaSnapshot, AIUsageFetchError>]
    private var fallbackResult: Result<AIProviderQuotaSnapshot, AIUsageFetchError>
    private var fetchGate: CheckedContinuation<Void, Never>?
    private var holdNextFetch = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        id: AIUsageProviderID,
        results: [Result<AIProviderQuotaSnapshot, AIUsageFetchError>] = [],
        fallback: Result<AIProviderQuotaSnapshot, AIUsageFetchError> = .failure(.networkFailure("Unscripted"))
    ) {
        self.id = id
        self.scriptedResults = results
        self.fallbackResult = fallback
    }

    func setFallback(_ result: Result<AIProviderQuotaSnapshot, AIUsageFetchError>) {
        self.fallbackResult = result
    }

    func enqueue(_ result: Result<AIProviderQuotaSnapshot, AIUsageFetchError>) {
        scriptedResults.append(result)
    }

    func holdUpcomingFetch() {
        holdNextFetch = true
    }

    func releaseHeldFetch() {
        holdNextFetch = false
        let gate = fetchGate
        fetchGate = nil
        gate?.resume()
    }

    func waitForFetchStart(atLeast expectedCalls: Int) async {
        if callCount >= expectedCalls { return }
        while callCount < expectedCalls {
            await withCheckedContinuation { continuation in
                if callCount >= expectedCalls {
                    continuation.resume()
                } else {
                    startedWaiters.append(continuation)
                }
            }
        }
    }

    func fetchQuota(now: Date) async -> Result<AIProviderQuotaSnapshot, AIUsageFetchError> {
        callCount += 1
        recordedDates.append(now)

        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        if holdNextFetch {
            await withCheckedContinuation { continuation in
                fetchGate = continuation
            }
        }

        if !scriptedResults.isEmpty {
            let next = scriptedResults.removeFirst()
            switch next {
            case .success(let snapshot):
                return .success(
                    AIProviderQuotaSnapshot(
                        providerID: snapshot.providerID,
                        primaryWindow: snapshot.primaryWindow,
                        secondaryWindow: snapshot.secondaryWindow,
                        additionalWindows: snapshot.additionalWindows,
                        extraUsage: snapshot.extraUsage,
                        planLabel: snapshot.planLabel,
                        credits: snapshot.credits,
                        accountLabel: snapshot.accountLabel,
                        fetchedAt: now
                    )
                )
            case .failure:
                return next
            }
        }

        switch fallbackResult {
        case .success(let snapshot):
            return .success(
                AIProviderQuotaSnapshot(
                    providerID: snapshot.providerID,
                    primaryWindow: snapshot.primaryWindow,
                    secondaryWindow: snapshot.secondaryWindow,
                    additionalWindows: snapshot.additionalWindows,
                    extraUsage: snapshot.extraUsage,
                    planLabel: snapshot.planLabel,
                    credits: snapshot.credits,
                    accountLabel: snapshot.accountLabel,
                    fetchedAt: now
                )
            )
        case .failure:
            return fallbackResult
        }
    }
}

// MARK: - Isolated UserDefaults, Temp Directories & Demand Owner

enum E2EIsolatedStore {
    @MainActor
    static func makeSettings() -> (settings: LynxBar.Settings, suiteName: String, defaults: UserDefaults) {
        let suiteName = "com.swnb.LynxBar.E2ETests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (LynxBar.Settings(defaults: defaults), suiteName, defaults)
    }

    static func cleanup(suiteName: String) {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}

final class E2ETempHomeFixture: Sendable {
    let rootURL: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LynxBarE2E-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.rootURL = base
    }

    func writeFile(relativePath: String, data: Data) throws -> URL {
        let fileURL = rootURL.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    func writeUTF8(relativePath: String, content: String) throws -> URL {
        try writeFile(relativePath: relativePath, data: Data(content.utf8))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

final class E2ECleanupTracker: Sendable {
    private let state = OSAllocatedUnfairLock<(suites: [String], homes: [E2ETempHomeFixture], servers: [E2ELoopbackHTTPServer])>(initialState: ([], [], []))

    func registerSuite(_ suite: String) {
        state.withLock { $0.suites.append(suite) }
    }

    func registerHome(_ home: E2ETempHomeFixture) {
        state.withLock { $0.homes.append(home) }
    }

    func registerLoopbackServer(_ server: E2ELoopbackHTTPServer) {
        state.withLock { $0.servers.append(server) }
    }

    func cleanupAll() {
        let items = state.withLock { current -> (suites: [String], homes: [E2ETempHomeFixture], servers: [E2ELoopbackHTTPServer]) in
            let copy = current
            current = ([], [], [])
            return copy
        }
        for server in items.servers {
            server.stop()
        }
        for suite in items.suites {
            E2EIsolatedStore.cleanup(suiteName: suite)
        }
        for home in items.homes {
            home.cleanup()
        }
    }
}

/// Strictly-localhost (`127.0.0.1:0` ephemeral port) HTTP/1.1 loopback stub for verifying
/// `AIUsageHTTPClient` cookie rejection and wire-level headers without external network traffic.
final class E2ELoopbackHTTPServer: Sendable {
    private struct State {
        var listenFD: Int32
        var stopped: Bool = false
        var capturedRequests: [String] = []
    }

    let port: UInt16
    private let state: OSAllocatedUnfairLock<State>
    private let acceptQueue = DispatchQueue(label: "com.swnb.LynxBar.E2ELoopbackHTTPServer")

    init(responses: [String]) throws {
        let listenFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var reuse: Int32 = 1
        _ = Darwin.setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(listenFD, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            Darwin.close(listenFD)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }

        guard Darwin.listen(listenFD, 8) == 0 else {
            let err = errno
            Darwin.close(listenFD)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.getsockname(listenFD, saPtr, &addrLen)
            }
        }
        guard nameResult == 0 else {
            let err = errno
            Darwin.close(listenFD)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }

        self.port = UInt16(bigEndian: boundAddr.sin_port)
        self.state = OSAllocatedUnfairLock(initialState: State(listenFD: listenFD))

        acceptQueue.async { [self] in
            defer { self.stop() }
            for responseText in responses {
                let fd = state.withLock { $0.stopped ? -1 : $0.listenFD }
                guard fd >= 0 else { break }

                var clientAddr = sockaddr_in()
                var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        Darwin.accept(fd, saPtr, &clientLen)
                    }
                }
                guard clientFD >= 0 else { break }

                var noSigPipe: Int32 = 1
                _ = Darwin.setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 5, tv_usec: 0)
                _ = Darwin.setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                _ = Darwin.setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

                let rawRequest = Self.readHTTPRequestHeaders(from: clientFD)
                state.withLock { $0.capturedRequests.append(rawRequest) }

                Self.writeAll(responseText, to: clientFD)
                _ = Darwin.shutdown(clientFD, SHUT_RDWR)
                _ = Darwin.close(clientFD)
            }
        }
    }

    deinit {
        stop()
    }

    func url(path: String = "/") -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    var capturedRequests: [String] {
        state.withLock { $0.capturedRequests }
    }

    static func httpResponse(
        statusLine: String = "HTTP/1.1 200 OK",
        headers: [(String, String)] = [],
        body: Data
    ) -> String {
        var lines = [statusLine]
        for (name, value) in headers {
            lines.append("\(name): \(value)")
        }
        lines.append("Content-Length: \(body.count)")
        lines.append("Connection: close")
        let head = lines.joined(separator: "\r\n") + "\r\n\r\n"
        return head + String(decoding: body, as: UTF8.self)
    }

    static func headerLines(from rawRequest: String) -> [String] {
        let head = rawRequest.components(separatedBy: "\r\n\r\n").first ?? rawRequest
        return Array(head.components(separatedBy: "\r\n").dropFirst())
    }

    func stop() {
        let fd = state.withLock { box -> Int32 in
            box.stopped = true
            let current = box.listenFD
            box.listenFD = -1
            return current
        }
        if fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            _ = Darwin.close(fd)
        }
    }

    private static func readHTTPRequestHeaders(from clientFD: Int32) -> String {
        var collected = Data()
        let delimiter = Data("\r\n\r\n".utf8)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while collected.count < 65_536 {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.recv(clientFD, rawBuffer.baseAddress, rawBuffer.count, 0)
            }
            if bytesRead <= 0 { break }
            collected.append(contentsOf: buffer[0..<bytesRead])
            if collected.range(of: delimiter) != nil {
                break
            }
        }
        return String(decoding: collected, as: UTF8.self)
    }

    private static func writeAll(_ text: String, to clientFD: Int32) {
        let data = Data(text.utf8)
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var totalSent = 0
            while totalSent < data.count {
                let sent = Darwin.send(clientFD, baseAddress.advanced(by: totalSent), data.count - totalSent, 0)
                if sent <= 0 { break }
                totalSent += sent
            }
        }
    }
}

@MainActor
final class E2ETestDemandOwner: MonitoringDemandOwner {
    init() {}
}

@MainActor
enum E2EAsync {
    /// Flushes MainActor work and Combine async ticks deterministically without wall-clock sleeps.
    static func settle(cycles: Int = 8) async {
        for _ in 0..<cycles {
            await Task.yield()
        }
    }

    /// Polls a MainActor condition using task yields until satisfied or bounded attempts expire.
    static func waitUntil(
        maxCycles: Int = 300,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<maxCycles {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

// MARK: - Fixture Builders (JSON, JWT & Snapshots)

enum E2EFixtureFactory {
    static func makeJWT(claims: [String: Any]) -> String {
        let headerData = try! JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"])
        let payloadData = try! JSONSerialization.data(withJSONObject: claims)
        return "\(base64URL(headerData)).\(base64URL(payloadData)).c2lnbmF0dXJl"
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func claudeCredentialsData(
        accessToken: String = "sk-ant-oat01-fixture-token",
        expiresAtValue: Any? = nil,
        subscriptionType: String? = "max",
        rateLimitTier: String? = "default_claude_max_20x"
    ) -> Data {
        var oauth: [String: Any] = ["accessToken": accessToken]
        if let expiresAtValue { oauth["expiresAt"] = expiresAtValue }
        if let subscriptionType { oauth["subscriptionType"] = subscriptionType }
        if let rateLimitTier { oauth["rateLimitTier"] = rateLimitTier }
        return try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
    }

    static func claudeUsageJSON(
        fiveHourPercent: Double? = 42.0,
        fiveHourReset: String? = "2026-11-26T18:00:00Z",
        sevenDayPercent: Double? = 65.0,
        sevenDayReset: String? = "2026-12-01T00:00:00Z",
        sonnetPercent: Double? = nil,
        opusPercent: Double? = nil,
        oauthAppsPercent: Double? = nil,
        coworkPercent: Double? = nil,
        extraEnabled: Bool? = nil,
        extraUsed: Double? = nil,
        extraLimit: Double? = nil,
        extraCurrency: String? = nil
    ) -> Data {
        var root: [String: Any] = [:]
        if let fiveHourPercent {
            var obj: [String: Any] = ["utilization": fiveHourPercent]
            if let fiveHourReset { obj["resets_at"] = fiveHourReset }
            root["five_hour"] = obj
        }
        if let sevenDayPercent {
            var obj: [String: Any] = ["utilization": sevenDayPercent]
            if let sevenDayReset { obj["resets_at"] = sevenDayReset }
            root["seven_day"] = obj
        }
        if let sonnetPercent {
            root["seven_day_sonnet"] = ["utilization": sonnetPercent, "resets_at": "2026-12-01T00:00:00Z"]
        }
        if let opusPercent {
            root["seven_day_opus"] = ["utilization": opusPercent, "resets_at": "2026-12-01T00:00:00Z"]
        }
        if let oauthAppsPercent {
            root["seven_day_oauth_apps"] = ["utilization": oauthAppsPercent, "resets_at": "2026-12-01T00:00:00Z"]
        }
        if let coworkPercent {
            root["seven_day_cowork"] = ["utilization": coworkPercent, "resets_at": "2026-12-01T00:00:00Z"]
        }
        if let extraEnabled {
            var extra: [String: Any] = ["is_enabled": extraEnabled]
            if let extraUsed { extra["used_credits"] = extraUsed }
            if let extraLimit { extra["monthly_limit"] = extraLimit }
            if let extraCurrency { extra["currency"] = extraCurrency }
            root["extra_usage"] = extra
        }
        return try! JSONSerialization.data(withJSONObject: root)
    }

    static func codexAuthJSON(
        accessToken: String?,
        refreshToken: String? = "rt_codex_fixture",
        idToken: String? = nil,
        accountId: String? = "acct_123",
        lastRefresh: Any? = nil,
        openAIAPIKey: String? = nil
    ) -> Data {
        var root: [String: Any] = [:]
        if let openAIAPIKey { root["OPENAI_API_KEY"] = openAIAPIKey }
        if let lastRefresh { root["last_refresh"] = lastRefresh }
        if accessToken != nil || refreshToken != nil || idToken != nil || accountId != nil {
            var tokens: [String: Any] = [:]
            if let accessToken { tokens["access_token"] = accessToken }
            if let refreshToken { tokens["refresh_token"] = refreshToken }
            if let idToken { tokens["id_token"] = idToken }
            if let accountId { tokens["account_id"] = accountId }
            root["tokens"] = tokens
        }
        return try! JSONSerialization.data(withJSONObject: root)
    }

    static func codexUsageJSON(
        planType: String? = "pro",
        primaryUsedPercent: Double? = 40,
        primaryWindowSeconds: Double? = 18_000,
        primaryResetAt: Any? = nil,
        primaryResetAfterSeconds: Double? = 7_200,
        secondaryUsedPercent: Double? = 25,
        secondaryWindowSeconds: Double? = 604_800,
        secondaryResetAt: Any? = nil,
        secondaryResetAfterSeconds: Double? = 200_000,
        codeReviewUsedPercent: Double? = nil,
        creditsHasCredits: Bool? = true,
        creditsUnlimited: Bool? = false,
        creditsBalance: Any? = "12.50"
    ) -> Data {
        var root: [String: Any] = [:]
        if let planType { root["plan_type"] = planType }

        var rateLimit: [String: Any] = [:]
        if let primaryUsedPercent {
            var win: [String: Any] = ["used_percent": primaryUsedPercent]
            if let primaryWindowSeconds { win["limit_window_seconds"] = primaryWindowSeconds }
            if let primaryResetAt { win["reset_at"] = primaryResetAt }
            if let primaryResetAfterSeconds { win["reset_after_seconds"] = primaryResetAfterSeconds }
            rateLimit["primary_window"] = win
        }
        if let secondaryUsedPercent {
            var win: [String: Any] = ["used_percent": secondaryUsedPercent]
            if let secondaryWindowSeconds { win["limit_window_seconds"] = secondaryWindowSeconds }
            if let secondaryResetAt { win["reset_at"] = secondaryResetAt }
            if let secondaryResetAfterSeconds { win["reset_after_seconds"] = secondaryResetAfterSeconds }
            rateLimit["secondary_window"] = win
        }
        if !rateLimit.isEmpty { root["rate_limit"] = rateLimit }

        if let codeReviewUsedPercent {
            root["code_review_rate_limit"] = [
                "primary_window": [
                    "used_percent": codeReviewUsedPercent,
                    "limit_window_seconds": 604_800,
                ]
            ]
        }

        if creditsHasCredits != nil || creditsUnlimited != nil || creditsBalance != nil {
            var credits: [String: Any] = [:]
            if let creditsHasCredits { credits["has_credits"] = creditsHasCredits }
            if let creditsUnlimited { credits["unlimited"] = creditsUnlimited }
            if let creditsBalance { credits["balance"] = creditsBalance }
            root["credits"] = credits
        }
        return try! JSONSerialization.data(withJSONObject: root)
    }

    static func makeSnapshot(
        providerID: AIUsageProviderID,
        usedRatio: Double,
        secondaryUsedRatio: Double? = nil,
        planLabel: String? = "Pro",
        resetsAt: Date? = Date(timeIntervalSince1970: 1_760_003_600),
        fetchedAt: Date = Date(timeIntervalSince1970: 1_760_000_000)
    ) -> AIProviderQuotaSnapshot {
        let primary = AIQuotaWindow(
            id: "\(providerID.rawValue)-primary",
            kind: providerID == .antigravity ? .modelQuota : .session5h,
            title: providerID == .antigravity ? "Gemini Models" : "5-hour session",
            usedRatio: usedRatio,
            resetsAt: resetsAt
        )
        let secondary = secondaryUsedRatio.map {
            AIQuotaWindow(
                id: "\(providerID.rawValue)-secondary",
                kind: providerID == .antigravity ? .modelQuota : .weekly7d,
                title: providerID == .antigravity ? "Claude and GPT" : "7-day weekly",
                usedRatio: $0,
                resetsAt: resetsAt
            )
        }
        return AIProviderQuotaSnapshot(
            providerID: providerID,
            primaryWindow: primary,
            secondaryWindow: secondary,
            planLabel: planLabel,
            fetchedAt: fetchedAt
        )
    }
}

// MARK: - Repository, Bundle & Localization Inspection Helpers

enum E2ERepoInspector {
    struct ParsedStrings {
        let orderedKeys: [String]
        let duplicates: [String]
        let entries: [String: String]
    }

    static func repoRootURL(from filePath: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(filePath)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var appBundle: Bundle {
        Bundle(for: AIUsageViewModel.self)
    }

    static func localizedString(_ key: String, localeIdentifier: String) -> String? {
        guard let lprojURL = appBundle.url(forResource: localeIdentifier, withExtension: "lproj"),
              let lprojBundle = Bundle(url: lprojURL) else {
            return nil
        }
        let sentinel = "__LYNXBAR_MISSING_KEY__"
        let resolved = lprojBundle.localizedString(forKey: key, value: sentinel, table: nil)
        return resolved == sentinel ? nil : resolved
    }

    static func parseLocalizableStrings(text: String) throws -> ParsedStrings {
        var keys: [String] = []
        let chars = Array(text.unicodeScalars)
        var i = 0
        let count = chars.count

        while i < count {
            let c = chars[i]
            if c == "/" && i + 1 < count && chars[i + 1] == "*" {
                i += 2
                var closed = false
                while i + 1 < count {
                    if chars[i] == "*" && chars[i + 1] == "/" {
                        i += 2
                        closed = true
                        break
                    }
                    i += 1
                }
                if !closed {
                    throw NSError(domain: "StringsSyntax", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unterminated block comment"])
                }
                continue
            }
            if c == "/" && i + 1 < count && chars[i + 1] == "/" {
                i += 2
                while i < count && chars[i] != "\n" {
                    i += 1
                }
                continue
            }
            if c == "\"" {
                i += 1
                var keyScalars = String.UnicodeScalarView()
                var closed = false
                while i < count {
                    let ch = chars[i]
                    if ch == "\\" && i + 1 < count {
                        keyScalars.append(ch)
                        keyScalars.append(chars[i + 1])
                        i += 2
                        continue
                    }
                    if ch == "\"" {
                        i += 1
                        closed = true
                        break
                    }
                    keyScalars.append(ch)
                    i += 1
                }
                if !closed {
                    throw NSError(domain: "StringsSyntax", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unterminated string literal"])
                }
                var k = i
                while k < count && (chars[k] == " " || chars[k] == "\t" || chars[k] == "\r" || chars[k] == "\n") {
                    k += 1
                }
                if k < count && chars[k] == "=" {
                    keys.append(String(keyScalars))
                }
                continue
            }
            i += 1
        }

        var seen = Set<String>()
        var duplicates: [String] = []
        for key in keys {
            if !seen.insert(key).inserted {
                duplicates.append(key)
            }
        }

        let data = Data(text.utf8)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dict = plist as? [String: String] else {
            throw NSError(domain: "StringsSyntax", code: 3, userInfo: [NSLocalizedDescriptionKey: "Root plist is not [String: String]"])
        }
        return ParsedStrings(orderedKeys: keys, duplicates: duplicates, entries: dict)
    }

    static func parseLocalizableStrings(at url: URL) throws -> ParsedStrings {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parseLocalizableStrings(text: text)
    }

    /// Extracts Apple printf/NSLocalizedString format specifiers while skipping escaped `%%`
    /// and avoiding space-flag false positives in prose (e.g. `"5% or"`).
    static func extractFormatSpecifiers(from text: String) -> [String] {
        let pattern = #"%%|%(?:\d+\$)?[-+#0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|L|z|t|j)?[@dDuUxXoOfeEgGcCsSpaAF]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            let token = String(text[swiftRange])
            return token == "%%" ? nil : token
        }
    }

    static func swiftSourceFiles(under relativePath: String) throws -> [URL] {
        let root = repoRootURL().appendingPathComponent(relativePath, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var urls: [URL] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            urls.append(fileURL)
        }
        return urls.sorted { $0.path < $1.path }
    }
}
