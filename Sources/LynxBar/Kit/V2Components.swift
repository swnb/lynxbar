import AppKit
import SwiftUI

extension View {
    /// SwiftUI 的透明 frame 不一定参与命中测试；V2 自定义 plain button 必须让完整可见表面可点击。
    func v2InteractiveSurface() -> some View {
        contentShape(Rectangle())
    }

    /// 在 macOS 14+ 上启用平滑数字滚动过渡，macOS 13 自动回退为静默更新。
    @ViewBuilder
    func lynxNumericTransition() -> some View {
        if #available(macOS 14.0, *) {
            self.contentTransition(.numericText())
        } else {
            self
        }
    }
}

/// 封装原生 `NSVisualEffectView` 的窗口后置毛玻璃底板。
/// 在用户开启“降低透明度”辅助功能时自动回退到高对比不透明 `Theme.surface`。
struct VisualEffectBackdrop: View {
    var material: NSVisualEffectView.Material = .popover
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency || Theme.shouldReduceTransparency {
            Theme.surface
        } else {
            ZStack {
                VisualEffectViewRepresentable(material: material)
                Theme.panelBackdropTint
            }
        }
    }
}

/// `NSVisualEffectView` 的轻量 SwiftUI 桥接，锁定 `.behindWindow` 与 `.active` 状态。
private struct VisualEffectViewRepresentable: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        if nsView.material != material {
            nsView.material = material
        }
        nsView.blendingMode = .behindWindow
        nsView.state = .active
    }
}

/// 原生毛玻璃精密卡片容器：采用 continuous 圆角、半透明抬升表面、0.5pt 精密描边与顶部微高光。
/// 可选 `accentTint` 用于 Hero / 告警卡片叠加极淡的环境色光晕。
struct V2Card<Content: View>: View {
    var accentTint: Color? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        content()
            .background {
                ZStack {
                    shape.fill(Theme.cardFill)
                    if let accentTint {
                        shape.fill(
                            LinearGradient(
                                colors: [accentTint.opacity(0.095), accentTint.opacity(0.02), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    }
                }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Theme.cardTopHighlight, .clear, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
            }
            .overlay {
                shape.strokeBorder(
                    accentTint.map { $0.opacity(0.22) } ?? Theme.cardHairline,
                    lineWidth: 0.5
                )
            }
    }
}

/// 统一的胶囊进度条组件，替代系统默认 `ProgressView`，保持凹陷槽与柔和渐变填充一致。
struct LynxProgressBar: View {
    let value: Double
    let tint: Color
    var height: CGFloat = 5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clampedValue: Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let fillWidth = clampedValue > 0 ? max(height, proxy.size.width * CGFloat(clampedValue)) : 0
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Theme.controlTrack)
                if fillWidth > 0 {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.82), tint],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: min(proxy.size.width, fillWidth))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: clampedValue)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// 统一的滑动胶囊分段选择器，用于趋势切换、进程排序等轻量选项，替代混用的系统分段 Picker。
struct LynxSegmentedPill<Option: Hashable>: View {
    let options: [Option]
    let selection: Option
    let title: (Option) -> String
    var minItemWidth: CGFloat = 42
    var itemHeight: CGFloat = 22
    let onSelect: (Option) -> Void

    @Namespace private var thumbNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 1) {
            ForEach(options, id: \.self) { option in
                SegmentedPillOptionButton(
                    title: title(option),
                    isSelected: selection == option,
                    minWidth: minItemWidth,
                    height: itemHeight,
                    namespace: thumbNamespace,
                    reduceMotion: reduceMotion,
                    action: {
                        if reduceMotion {
                            onSelect(option)
                        } else {
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                                onSelect(option)
                            }
                        }
                    }
                )
            }
        }
        .padding(2)
        .background(Theme.controlTrack)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.cardHairline, lineWidth: 0.5)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// `LynxSegmentedPill` 内部单个选项按钮，提供完整命中面、hover、键盘焦点环与 VoiceOver 选中态。
private struct SegmentedPillOptionButton: View {
    let title: String
    let isSelected: Bool
    let minWidth: CGFloat
    let height: CGFloat
    let namespace: Namespace.ID
    let reduceMotion: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(LocalizedStringKey(title))
                .font(Theme.Font.micro.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Theme.ink : Theme.secondaryInk)
                .padding(.horizontal, 6)
                .frame(minWidth: minWidth, minHeight: height)
                .v2InteractiveSurface()
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Theme.controlThumb)
                            .overlay {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(Theme.cardHairline, lineWidth: 0.5)
                            }
                            .shadow(color: Color.black.opacity(0.08), radius: 1.5, y: 0.5)
                            .matchedGeometryEffect(id: "segmentedThumb", in: namespace)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Theme.hoverFill)
                    }
                }
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Theme.focusRingColor(isSelected: isSelected), lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 统一的语义淡彩胶囊行动按钮，替代系统 `.bordered` 灰按钮，在深浅色毛玻璃下保持高质感与清晰层级。
struct LynxActionPillButton: View {
    let title: String
    let tint: Color
    var isProminent: Bool = false
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(LocalizedStringKey(title))
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .frame(minHeight: 24)
                .v2InteractiveSurface()
                .background(
                    Capsule(style: .continuous)
                        .fill(tint.opacity(fillOpacity))
                )
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(tint.opacity(isProminent ? 0.42 : 0.28), lineWidth: 0.5)
                }
                .overlay {
                    if isFocused {
                        Capsule(style: .continuous)
                            .stroke(Theme.focusRingColor(isSelected: false), lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovered = $0 }
    }

    private var fillOpacity: Double {
        if isHovered {
            return isProminent ? 0.28 : 0.20
        }
        return isProminent ? 0.18 : 0.12
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

    @Namespace private var thumbNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ranges) { range in
                RangeButton(
                    range: range,
                    isSelected: selection == range,
                    namespace: thumbNamespace,
                    action: {
                        if reduceMotion {
                            select(range)
                        } else {
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                                select(range)
                            }
                        }
                    }
                )
            }
        }
        .padding(2)
        .background(Theme.controlTrack)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.cardHairline, lineWidth: 0.5)
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
    let namespace: Namespace.ID
    let action: () -> Void
    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(range.rawValue)
                .font(Theme.Font.subheadline.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Theme.ink : Theme.secondaryInk)
                .frame(minWidth: 36, minHeight: 24)
                .v2InteractiveSurface()
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                            .fill(Theme.controlThumb)
                            .overlay {
                                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                    .strokeBorder(Theme.cardHairline, lineWidth: 0.5)
                            }
                            .shadow(color: Color.black.opacity(0.08), radius: 1.5, y: 0.5)
                            .matchedGeometryEffect(id: "rangeThumb", in: namespace)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                            .fill(Theme.hoverFill)
                    }
                }
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
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
