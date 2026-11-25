import os

/// Centralized structured diagnostics using Apple unified logging (`os.Logger`).
///
/// Privacy rules:
/// - Never log OAuth tokens, authorization headers, raw Keychain JSON, HTTP response bodies, or credentials at any level.
/// - Always mark IP addresses, file system paths, usernames, and OS error descriptions as `.private` (or omit them).
enum Log {
    private static let subsystem = "com.swnb.LynxBar"

    /// Application lifecycle, appearance, launch-at-login, and UI remediation coordination.
    static let app = Logger(subsystem: subsystem, category: "app")

    /// Demand-driven system metric sampling loops and provider polling.
    static let sampling = Logger(subsystem: subsystem, category: "sampling")

    /// Metric history archive loading, migration, and persistence.
    static let history = Logger(subsystem: subsystem, category: "history")

    /// Network counters, nettop process attribution, and public IP lookups.
    static let network = Logger(subsystem: subsystem, category: "network")

    /// AI subscription quota credentials, API transport, and refresh scheduling.
    static let aiUsage = Logger(subsystem: subsystem, category: "aiUsage")
}
