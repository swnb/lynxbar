import Foundation

/// Freshness state of a menu bar reading at evaluation time.
enum MenuBarReadingAvailability: String, Codable, Sendable {
    case available
    case stale
    case unavailable
}

/// 数值以比例（0...1）或 bytes/s 表达；来源时间为真正采样时间。
/// 数值 TTL 单位秒。公开通知状态使用 observationActive 表达有效订阅，
/// 不因长时间没有状态变化而套用轮询数值的陈旧窗口。
struct MenuBarMetricReading: Equatable, Sendable {
    let primaryValue: Double?
    let secondaryValue: Double?
    let stateValue: String?
    let resetsAt: Date?
    let displayStyle: AIQuotaDisplayStyle?
    let observedAt: Date?
    let staleAfter: TimeInterval
    let availability: MenuBarReadingAvailability
    private let observationActive: Bool

    /// Creates a numeric menu bar reading (ratio in `0...1` or throughput in bytes/s) with an explicit TTL.
    static func numeric(
        _ primaryValue: Double?,
        secondary secondaryValue: Double? = nil,
        observedAt: Date,
        staleAfter: TimeInterval = 15
    ) -> Self {
        MenuBarMetricReading(
            primaryValue: primaryValue,
            secondaryValue: secondaryValue,
            stateValue: nil,
            resetsAt: nil,
            displayStyle: nil,
            observedAt: observedAt,
            staleAfter: staleAfter,
            availability: primaryValue?.isFinite == true
                ? .available
                : .unavailable,
            observationActive: false
        )
    }

    /// Creates a discrete state reading with an explicit expiration window.
    static func state(
        _ stateValue: String?,
        observedAt: Date,
        staleAfter: TimeInterval = 60
    ) -> Self {
        MenuBarMetricReading(
            primaryValue: nil,
            secondaryValue: nil,
            stateValue: stateValue,
            resetsAt: nil,
            displayStyle: nil,
            observedAt: observedAt,
            staleAfter: staleAfter,
            availability: stateValue == nil ? .unavailable : .available,
            observationActive: false
        )
    }

    /// 事件来源只在订阅有效时可用；停止观察立即隐藏旧状态。
    static func observedState(_ stateValue: String?, observationActive: Bool) -> Self {
        MenuBarMetricReading(
            primaryValue: nil,
            secondaryValue: nil,
            stateValue: stateValue,
            resetsAt: nil,
            displayStyle: nil,
            observedAt: nil,
            staleAfter: 0,
            availability: observationActive && stateValue != nil ? .available : .unavailable,
            observationActive: observationActive
        )
    }

    /// Creates a menu bar reading for an AI subscription quota window with a 15-minute (900s) default TTL.
    static func aiQuota(
        usedRatio: Double?,
        resetsAt: Date? = nil,
        displayStyle: AIQuotaDisplayStyle = .remaining,
        observedAt: Date,
        staleAfter: TimeInterval = 900
    ) -> Self {
        let validUsedRatio: Double? = {
            guard let usedRatio, usedRatio.isFinite else { return nil }
            return min(max(usedRatio, 0), 1)
        }()
        return MenuBarMetricReading(
            primaryValue: validUsedRatio,
            secondaryValue: nil,
            stateValue: nil,
            resetsAt: resetsAt,
            displayStyle: displayStyle,
            observedAt: observedAt,
            staleAfter: staleAfter,
            availability: validUsedRatio != nil ? .available : .unavailable,
            observationActive: false
        )
    }

    /// Sentinel reading representing a missing or disabled metric.
    static let unavailable = MenuBarMetricReading(
        primaryValue: nil,
        secondaryValue: nil,
        stateValue: nil,
        resetsAt: nil,
        displayStyle: nil,
        observedAt: nil,
        staleAfter: 0,
        availability: .unavailable,
        observationActive: false
    )

    /// Evaluates whether this reading is currently available, stale, or unavailable at `now`.
    func resolvedAvailability(at now: Date) -> MenuBarReadingAvailability {
        guard availability == .available else { return availability }
        if observationActive { return .available }
        guard let observedAt, staleAfter > 0 else {
            return .stale
        }
        let age = now.timeIntervalSince(observedAt)
        guard age >= 0, age <= staleAfter else { return .stale }
        return .available
    }
}

/// Point-in-time health severity and per-slot readings passed to `MenuBarStatusFormatter`.
struct MenuBarStatusSnapshot: Equatable, Sendable {
    let health: HealthSeverity
    let readings: [MenuBarStatusSlot: MenuBarMetricReading]

    /// Returns the reading recorded for `slot`, or `.unavailable` if absent.
    func reading(for slot: MenuBarStatusSlot) -> MenuBarMetricReading {
        readings[slot] ?? .unavailable
    }
}

/// Formatted single-slot menu bar text paired with its localized VoiceOver label.
struct MenuBarStatusSegment: Equatable, Sendable {
    let slot: MenuBarStatusSlot
    let text: String
    let accessibilityLabel: String
}

/// 纯 formatter 输出；estimatedWidth 是估算，生产 AppKit renderer 仍须用
/// 实际字体测量后限制 mode.widthBudget，超限时采用隐藏文字回退。
struct MenuBarStatusPresentation: Equatable, Sendable {
    let mode: MenuBarDisplayMode
    let title: String
    let accessibilityLabel: String
    let segments: [MenuBarStatusSegment]
    let estimatedWidth: Double
}

/// Formats `MenuBarStatusSnapshot` values into compact menu bar strings and localized VoiceOver labels.
enum MenuBarStatusFormatter {
    /// Builds the complete `MenuBarStatusPresentation` for the requested display mode, slots, and locale.
    static func format(
        mode: MenuBarDisplayMode,
        slots: [MenuBarStatusSlot],
        snapshot: MenuBarStatusSnapshot,
        locale: Locale = .current,
        now: Date = Date(),
        aiQuotaDisplayStyle: AIQuotaDisplayStyle? = nil
    ) -> MenuBarStatusPresentation {
        let selectedSlots = Array(
            MenuBarStatusSlot.validated(slots.map(\.rawValue))
                .prefix(mode.maximumSlotCount)
        )
        let segments = selectedSlots.map {
            segment(
                for: $0,
                reading: snapshot.reading(for: $0),
                locale: locale,
                now: now,
                aiQuotaDisplayStyle: aiQuotaDisplayStyle
            )
        }
        let symbol = healthSymbol(snapshot.health)
        let title = mode == .minimal
            ? symbol
            : ([symbol] + segments.map(\.text)).joined(separator: "  ")
        let healthLabel = localizedHealth(snapshot.health, locale: locale)
        let accessibility = ([healthLabel] + segments.map(\.accessibilityLabel))
            .joined(separator: ", ")
        return MenuBarStatusPresentation(
            mode: mode,
            title: title,
            accessibilityLabel: accessibility,
            segments: segments,
            estimatedWidth: estimatedWidth(for: title, mode: mode)
        )
    }

    /// Formats a single status slot segment and its accessibility description at `now`.
    private static func segment(
        for slot: MenuBarStatusSlot,
        reading: MenuBarMetricReading,
        locale: Locale,
        now: Date,
        aiQuotaDisplayStyle: AIQuotaDisplayStyle?
    ) -> MenuBarStatusSegment {
        let label = localizedLabel(slot, locale: locale)
        switch reading.resolvedAvailability(at: now) {
        case .unavailable:
            return MenuBarStatusSegment(
                slot: slot,
                text: "\(shortLabel(slot)) —",
                accessibilityLabel: "\(label) \(localizedUnavailable(locale))"
            )
        case .stale:
            return MenuBarStatusSegment(
                slot: slot,
                text: "\(shortLabel(slot)) —",
                accessibilityLabel: "\(label) \(localizedStale(locale))"
            )
        case .available:
            break
        }

        if slot == .aiUsage {
            let style = aiQuotaDisplayStyle ?? reading.displayStyle ?? .remaining
            let usedRatio = min(max(reading.primaryValue ?? 0, 0), 1)
            let displayedRatio = style == .remaining ? max(0, min(1, 1.0 - usedRatio)) : usedRatio
            let percent = boundedPercent(displayedRatio)
            return MenuBarStatusSegment(
                slot: slot,
                text: "\(shortLabel(slot)) \(percent)%",
                accessibilityLabel: localizedAIQuotaAccessibility(
                    percent: percent,
                    style: style,
                    resetsAt: reading.resetsAt,
                    locale: locale,
                    now: now
                )
            )
        }

        let valueText: String
        let accessibilityValue: String
        switch slot {
        case .cpu, .memory, .gpu, .internalBattery, .accessoryBattery:
            let percent = boundedPercent(reading.primaryValue)
            valueText = "\(percent)%"
            accessibilityValue = "\(percent) \(localizedPercent(locale))"
        case .disk:
            let percent = boundedPercent(reading.primaryValue)
            valueText = "\(percent)%"
            accessibilityValue = "\(percent) \(localizedPercent(locale))"
        case .network:
            let down = compactRate(reading.primaryValue)
            let up = compactRate(reading.secondaryValue)
            valueText = "↓\(down) ↑\(up)"
            accessibilityValue = "\(localizedDownload(locale)) \(localizedRate(reading.primaryValue, locale: locale)), \(localizedUpload(locale)) \(localizedRate(reading.secondaryValue, locale: locale))"
        case .thermal:
            let state = localizedThermalState(reading.stateValue, locale: locale)
            valueText = state.short
            accessibilityValue = state.full
        case .aiUsage:
            valueText = "—"
            accessibilityValue = localizedUnavailable(locale)
        }
        return MenuBarStatusSegment(
            slot: slot,
            text: "\(shortLabel(slot)) \(valueText)",
            accessibilityLabel: "\(label) \(accessibilityValue)"
        )
    }

    /// Clamps a `0...1` ratio and converts it to a rounded integer percentage (`0...100`).
    private static func boundedPercent(_ value: Double?) -> Int {
        guard let value, value.isFinite else { return 0 }
        return Int((min(max(value, 0), 1) * 100).rounded())
    }

    /// Formats a bytes-per-second value into a compact fixed-width rate string (e.g., `1.25M/s`).
    private static func compactRate(_ value: Double?) -> String {
        compactScaled(value, suffix: "/s")
    }

    /// Scales a non-negative byte count into SI units (`B`, `K`, `M`, `G`, `T`) with an optional suffix.
    private static func compactScaled(_ value: Double?, suffix: String) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        let units = ["B", "K", "M", "G", "T"]
        var scaled = min(value, 999 * pow(1_000, 4))
        var unitIndex = 0
        while scaled >= 1_000, unitIndex < units.count - 1 {
            scaled /= 1_000
            unitIndex += 1
        }
        let number = scaled >= 100
            ? String(format: "%.0f", scaled)
            : scaled >= 10
                ? String(format: "%.1f", scaled)
                : String(format: "%.2f", scaled)
        return "\(number)\(units[unitIndex])\(suffix)"
    }

    /// Formats a byte magnitude in deterministic English or Chinese words for VoiceOver output.
    private static func localizedBytes(_ value: Double?, locale: Locale) -> String {
        guard let value, value.isFinite, value >= 0 else {
            return localizedUnavailable(locale)
        }
        // ByteCountFormatter uses the process locale rather than the caller's
        // locale. Keep accessibility output deterministic in both languages.
        let units = isChinese(locale)
            ? ["字节", "千字节", "兆字节", "吉字节", "太字节"]
            : ["bytes", "kilobytes", "megabytes", "gigabytes", "terabytes"]
        var scaled = min(value, 999 * pow(1_000, 4))
        var index = 0
        while scaled >= 1_000, index < units.count - 1 {
            scaled /= 1_000
            index += 1
        }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = index == 0 ? 0 : 2
        return "\(formatter.string(from: NSNumber(value: scaled)) ?? "—") \(units[index])"
    }

    /// Formats a network throughput value in spoken English or Chinese units for VoiceOver.
    private static func localizedRate(_ value: Double?, locale: Locale) -> String {
        "\(localizedBytes(value, locale: locale)) \(isChinese(locale) ? "每秒" : "per second")"
    }

    /// Returns the compact 2–3 character menu bar prefix for `slot`.
    private static func shortLabel(_ slot: MenuBarStatusSlot) -> String {
        switch slot {
        case .cpu: return "CPU"
        case .memory: return "MEM"
        case .disk: return "DSK"
        case .network: return "NET"
        case .gpu: return "GPU"
        case .thermal: return "TMP"
        case .internalBattery: return "BAT"
        case .accessoryBattery: return "ACC"
        case .aiUsage: return "AI"
        }
    }

    /// Returns the spoken English or Chinese metric name for `slot`.
    private static func localizedLabel(
        _ slot: MenuBarStatusSlot,
        locale: Locale
    ) -> String {
        let chinese = isChinese(locale)
        switch slot {
        case .cpu: return chinese ? "处理器" : "CPU"
        case .memory: return chinese ? "内存" : "Memory"
        case .disk: return chinese ? "磁盘使用率" : "Disk usage"
        case .network: return chinese ? "网络" : "Network"
        case .gpu: return chinese ? "图形处理器" : "GPU"
        case .thermal: return chinese ? "系统热状态" : "System thermal state"
        case .internalBattery: return chinese ? "内置电池" : "Internal battery"
        case .accessoryBattery: return chinese ? "外设电量" : "Accessory battery"
        case .aiUsage: return chinese ? "AI 额度" : "AI quota"
        }
    }

    /// Maps a thermal state raw string to compact menu bar text and full VoiceOver wording.
    private static func localizedThermalState(
        _ value: String?,
        locale: Locale
    ) -> (short: String, full: String) {
        let chinese = isChinese(locale)
        switch value?.lowercased() {
        case "nominal":
            return (chinese ? "正常" : "OK", chinese ? "正常" : "nominal")
        case "fair":
            return (chinese ? "偏热" : "FAIR", chinese ? "轻度升温" : "fair")
        case "serious":
            return (chinese ? "较热" : "HOT", chinese ? "严重升温" : "serious")
        case "critical":
            return (chinese ? "过热" : "CRIT", chinese ? "临界过热" : "critical")
        default:
            return ("—", chinese ? "未知" : "unknown")
        }
    }

    /// Returns the single-character glyph representing overall `HealthSeverity`.
    private static func healthSymbol(_ severity: HealthSeverity) -> String {
        switch severity {
        case .collecting: return "◌"
        case .healthy: return "●"
        case .attention: return "▲"
        case .critical: return "!"
        }
    }

    /// Returns the localized VoiceOver description of overall `HealthSeverity`.
    private static func localizedHealth(
        _ severity: HealthSeverity,
        locale: Locale
    ) -> String {
        let chinese = isChinese(locale)
        switch severity {
        case .collecting: return chinese ? "系统健康信息采集中" : "System health collecting"
        case .healthy: return chinese ? "系统健康正常" : "System health healthy"
        case .attention: return chinese ? "系统健康需要关注" : "System health needs attention"
        case .critical: return chinese ? "系统健康严重告警" : "System health critical"
        }
    }

    /// Estimates the horizontal point width of `title` clamped by `mode.widthBudget`.
    private static func estimatedWidth(
        for title: String,
        mode: MenuBarDisplayMode
    ) -> Double {
        min(mode.widthBudget, max(28, Double(title.count) * 6.4 + 14))
    }

    /// Returns the localized `"unavailable"` word for `locale`.
    private static func localizedUnavailable(_ locale: Locale) -> String {
        isChinese(locale) ? "不可用" : "unavailable"
    }

    /// Returns the localized `"stale"` indicator for `locale`.
    private static func localizedStale(_ locale: Locale) -> String {
        isChinese(locale) ? "数据已陈旧" : "stale"
    }

    /// Returns the localized `"percent"` unit word for `locale`.
    private static func localizedPercent(_ locale: Locale) -> String {
        isChinese(locale) ? "百分比" : "percent"
    }

    /// Returns the localized `"download"` word for `locale`.
    private static func localizedDownload(_ locale: Locale) -> String {
        isChinese(locale) ? "下载" : "download"
    }

    /// Returns the localized `"upload"` word for `locale`.
    private static func localizedUpload(_ locale: Locale) -> String {
        isChinese(locale) ? "上传" : "upload"
    }

    /// Returns `true` when `locale` targets Chinese language formatting.
    private static func isChinese(_ locale: Locale) -> Bool {
        locale.language.languageCode?.identifier == "zh"
            || locale.identifier.lowercased().hasPrefix("zh")
    }

    /// Formats a deterministic bilingual accessibility label for the AI quota menu bar slot.
    private static func localizedAIQuotaAccessibility(
        percent: Int,
        style: AIQuotaDisplayStyle,
        resetsAt: Date?,
        locale: Locale,
        now: Date
    ) -> String {
        let chinese = isChinese(locale)
        let base: String
        if chinese {
            let verb = style == .remaining ? "剩余" : "已用"
            base = "Claude 额度\(verb) \(percent)%"
        } else {
            let suffix = style == .remaining ? "remaining" : "used"
            base = "Claude quota \(percent)% \(suffix)"
        }
        guard let resetsAt else { return base }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0 else { return base }
        if chinese {
            return "\(base)，\(localizedChineseDuration(remaining))后重置"
        }
        return "\(base), resets in \(Formatters.duration(remaining))"
    }

    /// Formats a duration in natural Simplified Chinese units for VoiceOver and tooltips.
    private static func localizedChineseDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        return "\(minutes) 分钟"
    }
}
