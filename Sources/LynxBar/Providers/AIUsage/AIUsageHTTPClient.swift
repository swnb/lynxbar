import Foundation

/// Minimal HTTP transport abstraction so providers can be tested completely offline.
protocol AIUsageHTTPTransport: Sendable {
    /// Executes an HTTP request and returns the response payload and HTTP metadata.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Ephemeral `URLSession`-backed transport for AI subscription quota requests.
/// Disables disk caching and cookies and applies bounded request/resource timeouts.
final class AIUsageHTTPClient: AIUsageHTTPTransport, Sendable {
    static let defaultTimeout: TimeInterval = 15

    private let session: URLSession

    /// Creates an ephemeral HTTP client with zero disk cache or cookie persistence.
    init(timeout: TimeInterval = AIUsageHTTPClient.defaultTimeout) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        self.session = URLSession(configuration: configuration)
    }

    /// Executes `request` on the ephemeral session and ensures an `HTTPURLResponse` is returned.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, httpResponse)
    }
}
