import Foundation

/// Safe, zero-dependency JWT payload decoder for extracting non-secret metadata claims
/// such as `email`, `hd`, `exp`, and provider auth claims without signature verification.
/// Never logs raw JWT strings or decoded claim payloads.
enum AIUsageJWTDecoder {
    /// Decodes the Base64URL-encoded payload segment of `jwt` into raw JSON bytes.
    static func decodePayloadData(from jwt: String) -> Data? {
        let trimmed = jwt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let segments = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return nil }

        let payloadSegment = segments[1]
        guard !payloadSegment.isEmpty else { return nil }

        var base64 = String(payloadSegment)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = base64.count % 4
        if remainder == 1 {
            return nil
        }
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }

    /// Decodes the payload segment of `jwt` into a typed `Decodable` structure.
    static func decodePayload<T: Decodable>(_ type: T.Type, from jwt: String) -> T? {
        guard let data = decodePayloadData(from: jwt) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Decodes the payload segment of `jwt` as a JSON dictionary for synchronous local inspection.
    static func decodeClaimsDictionary(from jwt: String) -> [String: Any]? {
        guard let data = decodePayloadData(from: jwt) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Shared defensive parsing utilities for AI quota timestamps, ratios, HTTP headers, and bundle metadata.
enum AIUsageParsing {
    /// Upper bound for parsed HTTP `Retry-After` delays (24 hours) so extreme upstream values cannot park polling or overflow timers.
    static let maxRetryAfterInterval: TimeInterval = 86_400

    /// Parses a finite positive Unix timestamp expressed in either seconds or milliseconds (`>= 100_000_000_000`).
    static func parseUnixTimestamp(_ rawValue: Double?) -> Date? {
        guard let rawValue, rawValue.isFinite, !rawValue.isNaN, rawValue > 0 else {
            return nil
        }
        // Unix epoch seconds stay below 1e11 until year ~5138; epoch milliseconds exceeded 1e12 in 2001.
        let seconds = rawValue >= 100_000_000_000 ? rawValue / 1_000.0 : rawValue
        return Date(timeIntervalSince1970: seconds)
    }

    /// Parses a finite Unix expiration timestamp in seconds or milliseconds (`>= 100_000_000_000`).
    /// Finite non-positive values (`<= 0`) resolve to epoch zero (`1970-01-01T00:00:00Z`) so
    /// credential pre-flight checks reject epoch-zero/negative expirations instead of bypassing expiry.
    static func parseExpiryTimestamp(_ rawValue: Double?) -> Date? {
        guard let rawValue, rawValue.isFinite, !rawValue.isNaN else {
            return nil
        }
        guard rawValue > 0 else {
            return Date(timeIntervalSince1970: 0)
        }
        // Unix epoch seconds stay below 1e11 until year ~5138; epoch milliseconds exceeded 1e12 in 2001.
        let seconds = rawValue >= 100_000_000_000 ? rawValue / 1_000.0 : rawValue
        return Date(timeIntervalSince1970: seconds)
    }

    /// Parses an ISO-8601 timestamp string supporting both fractional and whole-second formats.
    static func parseISO8601Date(_ string: String?) -> Date? {
        guard let trimmed = nonEmptyTrimmed(string) else { return nil }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(trimmed) {
            return date
        }
        return try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(trimmed)
    }

    /// Parses an HTTP `Retry-After` header containing either positive seconds or a future HTTP-date,
    /// clamping positive results to `maxRetryAfterInterval`.
    static func parseRetryAfter(_ headerValue: String?, now: Date) -> TimeInterval? {
        guard let raw = nonEmptyTrimmed(headerValue) else { return nil }

        if let seconds = TimeInterval(raw), seconds.isFinite, !seconds.isNaN, seconds > 0 {
            return min(seconds, maxRetryAfterInterval)
        }

        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy",
        ]
        // Allocate DateFormatter locally to maintain strict Swift 6 concurrency safety.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in formats {
            formatter.dateFormat = format
            if let retryDate = formatter.date(from: raw) {
                let delta = retryDate.timeIntervalSince(now)
                return delta > 0 ? min(delta, maxRetryAfterInterval) : nil
            }
        }
        return nil
    }

    /// Converts a `0...100` percentage value to a clamped `0...1` ratio, returning `nil` for non-finite inputs.
    static func normalizedRatio(fromPercent percent: Double?) -> Double? {
        guard let percent, percent.isFinite, !percent.isNaN else { return nil }
        return min(max(percent / 100.0, 0), 1)
    }

    /// Clamps an arbitrary `0...1` ratio defensively, returning `nil` for `NaN` or infinite inputs.
    static func clampedRatio(_ ratio: Double?) -> Double? {
        guard let ratio, ratio.isFinite, !ratio.isNaN else { return nil }
        return min(max(ratio, 0), 1)
    }

    /// Returns a whitespace-trimmed string or `nil` when empty or absent.
    static func nonEmptyTrimmed(_ string: String?) -> String? {
        guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Reads `CFBundleShortVersionString` from the main bundle for outbound `User-Agent` headers.
    static func defaultBundleVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    }
}

/// Decodable timestamp supporting numeric Unix timestamps (seconds or milliseconds) and ISO-8601 strings.
enum AIUsageFlexibleTimestamp: Decodable, Sendable {
    case number(Double)
    case string(String)

    /// Decodes a numeric or string timestamp from a single JSON value.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let numeric = try? container.decode(Double.self) {
            self = .number(numeric)
            return
        }
        if let integer = try? container.decode(Int64.self) {
            self = .number(Double(integer))
            return
        }
        if let text = try? container.decode(String.self) {
            self = .string(text)
            return
        }
        throw DecodingError.typeMismatch(
            AIUsageFlexibleTimestamp.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected numeric Unix timestamp or ISO-8601 string"
            )
        )
    }

    /// Resolves the decoded timestamp value into a `Date`, if valid and positive when numeric.
    var resolvedDate: Date? {
        switch self {
        case .number(let value):
            return AIUsageParsing.parseUnixTimestamp(value)
        case .string(let text):
            guard let trimmed = AIUsageParsing.nonEmptyTrimmed(text) else { return nil }
            if let numeric = Double(trimmed) {
                return AIUsageParsing.parseUnixTimestamp(numeric)
            }
            return AIUsageParsing.parseISO8601Date(trimmed)
        }
    }

    /// Resolves the decoded timestamp value as an expiration `Date`, mapping finite non-positive numbers (`<= 0`) to epoch zero.
    var resolvedExpiryDate: Date? {
        switch self {
        case .number(let value):
            return AIUsageParsing.parseExpiryTimestamp(value)
        case .string(let text):
            guard let trimmed = AIUsageParsing.nonEmptyTrimmed(text) else { return nil }
            if let numeric = Double(trimmed) {
                return AIUsageParsing.parseExpiryTimestamp(numeric)
            }
            return AIUsageParsing.parseISO8601Date(trimmed)
        }
    }
}
