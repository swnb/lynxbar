import SwiftUI

extension View {
    /// SwiftUI 的透明 frame 不一定参与命中测试；V2 自定义 plain button 必须让完整可见表面可点击。
    func v2InteractiveSurface() -> some View {
        contentShape(Rectangle())
    }
}

struct V2Card<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(Theme.raised)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .stroke(Theme.divider, lineWidth: 1)
            }
    }
}

/// 为普通卡片内容提供统一安全区；需要贴边分隔线的复杂卡片继续直接使用 `V2Card`。
struct V2InsetCardContent<Content: View>: View {
    var horizontalPadding: CGFloat = Theme.Spacing.medium
    var verticalPadding: CGFloat = Theme.Spacing.small
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
    }
}

/// 活动页面的紧凑标题使用同一条图标优先层级。
///
/// 图标负责第一眼定位，短标题负责确认语义；完整含义由调用方通过
/// `accessibilityLabel` 保留，避免为了压缩视觉文案而损失 VoiceOver 信息。
struct IconSectionHeader<Trailing: View>: View {
    let systemName: String
    let title: String
    let tint: Color
    let accessibilityLabel: String
    let trailing: Trailing

    init(
        systemName: String,
        title: String,
        tint: Color,
        accessibilityLabel: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.systemName = systemName
        self.title = title
        self.tint = tint
        self.accessibilityLabel = accessibilityLabel ?? title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemName)
                .font(Theme.Font.callout.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(title))
                .font(Theme.Font.callout.weight(.semibold))
                .lineLimit(1)
                .accessibilityLabel(Text(LocalizedStringKey(accessibilityLabel)))
            Spacer(minLength: 6)
            trailing
        }
        .frame(minHeight: 18)
    }
}

extension IconSectionHeader where Trailing == EmptyView {
    init(
        systemName: String,
        title: String,
        tint: Color,
        accessibilityLabel: String? = nil
    ) {
        self.init(
            systemName: systemName,
            title: title,
            tint: tint,
            accessibilityLabel: accessibilityLabel
        ) {
            EmptyView()
        }
    }
}

/// 共享布局常量同时是自动化验收边界；标题和首个 y 轴标签之间不能再粘连。
enum V2LayoutPolicy {
    static let chartHeaderToPlot: CGFloat = 6
    static let disclosureExpansionDuration: TimeInterval = 0.16
    static let expandedSectionRevealDelayNanoseconds: UInt64 = 180_000_000
    static let overviewAttentionCardHeight: CGFloat = 61
    static let overviewAttentionCardHorizontalPadding: CGFloat = 11
    static let overviewAttentionCardVerticalPadding: CGFloat = 8
}

struct RangePicker: View {
    let ranges: [HistoryRange]
    let selection: HistoryRange
    let select: (HistoryRange) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ranges) { range in
                RangeButton(
                    range: range,
                    isSelected: selection == range,
                    action: { select(range) }
                )
            }
        }
        .padding(2)
        .background(Theme.raisedStrong)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .stroke(Theme.divider, lineWidth: 1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// 给低频、可安全重试的采样提供统一图标入口。固定尺寸在 spinner 与图标之间
/// 不发生布局跳动，完整 28pt 表面同时承担 hover、焦点和指针命中。
struct CompactRefreshButton: View {
    let isRefreshing: Bool
    let hasError: Bool
    let tint: Color
    let accessibilityLabel: String
    let helpText: String
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered && !isRefreshing ? Theme.hoverFill : Color.clear)

                if isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(tint)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(Theme.Font.subheadline.weight(.semibold))
                        .foregroundStyle(hasError ? Theme.warning : tint)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 28, height: 28)
            .v2InteractiveSurface()
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.selection, lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .disabled(isRefreshing)
        .onHover { isHovered = $0 }
        .help(helpText)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(
            isRefreshing
                ? NSLocalizedString("Refreshing", comment: "")
                : hasError
                    ? NSLocalizedString("Last refresh failed", comment: "")
                    : NSLocalizedString("Ready", comment: "")
        )
    }
}

private struct RangeButton: View {
    let range: HistoryRange
    let isSelected: Bool
    let action: () -> Void
    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(range.rawValue)
                .font(Theme.Font.subheadline.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Theme.ink : Theme.secondaryInk)
                .frame(minWidth: 36, minHeight: 26)
                .v2InteractiveSurface()
                .background(isSelected ? Theme.selectedFill : (isHovered ? Theme.hoverFill : .clear))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.focusRingColor(isSelected: isSelected), lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .accessibilityLabel(
            String(
                format: NSLocalizedString("%@ time range", comment: ""),
                range.rawValue
            )
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct CopyableValueRow: View {
    let label: String
    let value: String?
    var detail: String?
    var minHeight: CGFloat = 31
    @State private var copied = false
    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(label))
                    .font(Theme.Font.subheadline)
                    .foregroundStyle(Theme.mutedInk)
                if let detail {
                    Text(LocalizedStringKey(detail))
                        .font(Theme.Font.micro)
                        .foregroundStyle(Theme.mutedInk)
                }
            }
            Spacer()
            Text(value ?? NSLocalizedString("Unavailable", comment: ""))
                .font(Theme.Font.calloutMono)
                .foregroundStyle(value == nil ? Theme.mutedInk : Theme.ink)
                .lineLimit(1)
            if let value {
                Button {
                    guard ClipboardAction.copyToPasteboard(value) else { return }
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        await MainActor.run { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(Theme.Font.callout.weight(.semibold))
                        .foregroundStyle(copied ? Theme.health : Theme.secondaryInk)
                        .frame(width: 28, height: 28)
                        .v2InteractiveSurface()
                        .background(isHovered ? Theme.hoverFill : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            if isFocused {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Theme.selection, lineWidth: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .focused($isFocused)
                .onHover { isHovered = $0 }
                .accessibilityLabel(
                    copied
                        ? NSLocalizedString("Copied", comment: "")
                        : String(
                            format: NSLocalizedString("Copy %@", comment: ""),
                            NSLocalizedString(label, comment: "")
                        )
                )
            }
        }
        .frame(minHeight: minHeight)
    }
}

struct DisclosureRow<Content: View>: View {
    let title: String
    let subtitle: String
    let systemName: String?
    let tint: Color
    let accessibilityLabel: String
    @Binding var isExpanded: Bool
    let content: Content
    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    init(
        title: String,
        subtitle: String,
        systemName: String? = nil,
        tint: Color = Theme.secondaryInk,
        accessibilityLabel: String? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemName = systemName
        self.tint = tint
        self.accessibilityLabel = accessibilityLabel ?? title
        _isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: V2LayoutPolicy.disclosureExpansionDuration)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    if let systemName {
                        Image(systemName: systemName)
                            .font(Theme.Font.body.weight(.semibold))
                            .foregroundStyle(tint)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(title))
                            .font(Theme.Font.callout.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        if !subtitle.isEmpty {
                            Text(LocalizedStringKey(subtitle))
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.mutedInk)
                        }
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(Theme.Font.caption.weight(.semibold))
                        .foregroundStyle(Theme.secondaryInk)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 42)
                .v2InteractiveSurface()
                .background(isHovered ? Theme.hoverFill : Color.clear)
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: Theme.Radius.card)
                            .stroke(Theme.selection, lineWidth: 2)
                            .padding(2)
                    }
                }
            }
            .buttonStyle(.plain)
            .focused($isFocused)
            .onHover { isHovered = $0 }
            .accessibilityLabel(Text(LocalizedStringKey(accessibilityLabel)))
            .accessibilityValue(
                NSLocalizedString(isExpanded ? "Expanded" : "Collapsed", comment: "")
            )

            if isExpanded {
                Divider().overlay(Theme.divider)
                content
                    .padding(12)
            }
        }
    }
}

func historySubtitle(_ result: MetricHistoryResult) -> String {
    if result.points.isEmpty {
        return NSLocalizedString("Collecting history…", comment: "")
    }
    if result.isWarmingUp {
        return String(
            format: NSLocalizedString("%@ available · warming up", comment: ""),
            shortDuration(result.availableDuration)
        )
    }
    return String(
        format: NSLocalizedString("Complete %@ window", comment: ""),
        result.range.rawValue
    )
}

/// 完成态不需要长期占据图表 header；只有用户仍需等待的状态才可见。
func visibleHistoryStatus(_ result: MetricHistoryResult) -> String? {
    guard result.points.isEmpty || result.isWarmingUp else { return nil }
    return historySubtitle(result)
}

private func shortDuration(_ duration: TimeInterval) -> String {
    if duration < 60 { return "\(Int(duration))s" }
    if duration < 3_600 { return "\(Int(duration / 60))m" }
    if duration < 86_400 { return "\(Int(duration / 3_600))h" }
    return "\(Int(duration / 86_400))d"
}
