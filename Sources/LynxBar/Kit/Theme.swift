import AppKit
import SwiftUI

/// LynxBar V2 语义化双外观视觉 token。所有颜色按语义集中管理，同时给出浅色/深色两套
/// sRGB 取值，通过 NSColor 的动态 provider 跟随窗口的有效外观，避免详情页各自调色。
/// 正式启动由 AppDelegate 应用 Settings.appearanceMode（默认跟随系统，可选浅色/深色）；
/// DEBUG QA 可显式覆盖指定诊断窗口外观。
enum Theme {
    enum Series: Sendable {
        case cpu
        case memory
        case disk
        case gpu
        case battery
        case networkInput
        case networkOutput
    }

    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
    }

    enum Radius {
        static let control: CGFloat = 7
        static let card: CGFloat = 12
        static let panel: CGFloat = 14
    }

    /// 语义字号阶梯：全部基于系统文本样式构造，随「系统设置 → 辅助功能 → 显示 →
    /// 文字大小」整体缩放（即 Dynamic Type）。字重不在这里固定——各 token 只锚定
    /// 字号/字体设计，调用处按原有视觉权重通过 `.weight(_:)` 链式指定。
    ///
    /// 类型名 `Font` 会遮蔽 `SwiftUI.Font`，因此本枚举内部一律写全称
    /// `SwiftUI.Font.system(...)`，避免递归引用自身。
    enum Font {
        // MARK: 标题

        /// 面板/详情页顶部标题行（如 "CPU"、"Memory" 的图标+文字），默认约 17pt。
        static let title2 = SwiftUI.Font.system(.title2, design: .default)
        /// 全局首屏标题（DashboardHeader "LynxBar"）与少数装饰性图标，默认约 22pt。
        static let title = SwiftUI.Font.system(.title, design: .default)
        /// 面板内小节标题，默认约 15pt。
        static let title3 = SwiftUI.Font.system(.title3, design: .default)
        /// 小节标题的圆体数字变体，用于小型数值徽标，默认约 15pt。
        static let title3Rounded = SwiftUI.Font.system(.title3, design: .rounded)

        // MARK: 正文

        static let body = SwiftUI.Font.system(.body, design: .default)
        /// 正文的圆体数字变体，用于中等强调的数值展示。
        static let bodyRounded = SwiftUI.Font.system(.body, design: .rounded)
        static let callout = SwiftUI.Font.system(.callout, design: .default)
        static let calloutMono = SwiftUI.Font.system(.callout, design: .monospaced)

        // MARK: 辅助信息

        static let subheadline = SwiftUI.Font.system(.subheadline, design: .default)
        /// 辅助信息的圆体数字变体。
        static let subheadlineRounded = SwiftUI.Font.system(.subheadline, design: .rounded)
        static let caption = SwiftUI.Font.system(.caption, design: .default)
        static let captionMono = SwiftUI.Font.system(.caption, design: .monospaced)

        // MARK: 极小文字（徽标、图表刻度/tooltip 等）

        static let micro = SwiftUI.Font.system(.caption2, design: .default)
        static let microMono = SwiftUI.Font.system(.caption2, design: .monospaced)

        // MARK: 数值读数

        /// 面板主百分比等最醒目读数（CPU/Memory/Disk 使用率大字），圆体等宽数字。
        static let metricValue = SwiftUI.Font.system(.largeTitle, design: .rounded)
        /// 卡片内次级数值读数（如 Network 上下行速率卡片），圆体等宽数字。
        static let statValue = SwiftUI.Font.system(.title, design: .rounded)
        /// 纯装饰性大图标（About 页 Logo、DiskCleanup 空状态插画），不强求与正文
        /// 保持原比例——装饰图形本身不承载文字信息，420pt 宽面板里按原始阶梯换算
        /// 会在最大字号下失控，因此封顶在 largeTitle。
        static let largeTitle = SwiftUI.Font.system(.largeTitle, design: .default)
    }

    // MARK: - 动态颜色构造

    /// 不透明纯色 token：浅色/深色各给一组 sRGB 三元组，alpha 固定为 1。
    private static func dynamic(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat)
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (r, g, b) = isDark ? dark : light
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
    }

    /// ink 系列专用：浅色是不透明的调色灰，深色沿用既有的半透明白（叠在深色 surface
    /// 上已验证过对比度）。两侧不对称，不能复用上面纯色版本的 `dynamic(light:dark:)`。
    private static func dynamicInk(
        light: (CGFloat, CGFloat, CGFloat),
        darkWhiteAlpha: CGFloat
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if isDark {
                return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: darkWhiteAlpha)
            }
            let (r, g, b) = light
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
    }

    /// 描边/悬浮叠加层：浅色是黑、深色是白，各自独立不透明度。
    private static func dynamicOverlay(lightAlpha: CGFloat, darkAlpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let white: CGFloat = isDark ? 1 : 0
            return NSColor(srgbRed: white, green: white, blue: white, alpha: isDark ? darkAlpha : lightAlpha)
        }
    }

    // MARK: - 背景

    static let nsSurface = dynamic(light: (0.98, 0.98, 0.99), dark: (0.055, 0.067, 0.080))
    static let nsRaised = dynamic(light: (0.945, 0.95, 0.96), dark: (0.083, 0.102, 0.121))
    static let nsRaisedStrong = dynamic(light: (0.90, 0.91, 0.92), dark: (0.108, 0.132, 0.154))

    static var surface: Color { Color(nsColor: nsSurface) }
    static var raised: Color { Color(nsColor: nsRaised) }
    static var raisedStrong: Color { Color(nsColor: nsRaisedStrong) }

    // MARK: - 文字

    static let nsInk = dynamicInk(light: (0.11, 0.12, 0.13), darkWhiteAlpha: 0.96)
    static let nsSecondaryInk = dynamicInk(light: (0.36, 0.38, 0.40), darkWhiteAlpha: 0.67)
    static let nsMutedInk = dynamicInk(light: (0.52, 0.54, 0.56), darkWhiteAlpha: 0.46)

    static var ink: Color { Color(nsColor: nsInk) }
    static var secondaryInk: Color { Color(nsColor: nsSecondaryInk) }
    static var mutedInk: Color { Color(nsColor: nsMutedInk) }

    // MARK: - 描边与叠加

    static let nsDivider = dynamicOverlay(lightAlpha: 0.12, darkAlpha: 0.10)
    static let nsHoverFill = dynamicOverlay(lightAlpha: 0.05, darkAlpha: 0.055)
    /// 分段选择器（RangePicker/OverviewTrendPicker）里选中项的中性高亮填充，
    /// 比 hoverFill 更强调、但不像 selectionSoft 那样带品牌蓝——用于不想切成
    /// "选中=蓝色"语义的场景（例如时间范围/趋势这类中性切换，而不是导航目的地）。
    /// 深色沿用原来的 `Color.white.opacity(0.14)`；浅色原先直接复用同一个白色值，
    /// 在浅色 raisedStrong（本来就接近白）上叠加更多白色几乎不可见，改成黑色叠加
    /// 才能在浅色下产生可辨识的"已选中"视觉重量。
    static let nsSelectedFill = dynamicOverlay(lightAlpha: 0.10, darkAlpha: 0.14)
    static var divider: Color { Color(nsColor: nsDivider) }
    static var hoverFill: Color { Color(nsColor: nsHoverFill) }
    static var selectedFill: Color { Color(nsColor: nsSelectedFill) }

    // MARK: - 交互强调色

    static let nsSelection = dynamic(light: (0.00, 0.36, 0.85), dark: (0.22, 0.53, 1.0))
    /// `withAlphaComponent` 在动态 NSColor 上依然保留其按外观解析的能力，
    /// 只是覆盖 alpha 通道——比在 Color 层用 `.opacity()` 更方便在测试里
    /// 按外观解析出合成前的准确 alpha 值（`resolved(for:).alphaComponent`）。
    static let nsSelectionSoft = nsSelection.withAlphaComponent(0.14)
    static var selection: Color { Color(nsColor: nsSelection) }
    static var selectionSoft: Color { Color(nsColor: nsSelectionSoft) }

    /// 焦点环颜色：未选中态直接用强调色本身作为焦点提示；选中态改用 ink——
    /// 因为选中态背景（selectionSoft/selectedFill）已经是强调色系的浅色调，
    /// 焦点环若还用 selection 会和背景/前景糊在一起，ink 与 surface/raised 系
    /// 背景始终保持高对比度（见 ThemeTests 的 WCAG 校验），能在两种外观下都
    /// 清楚划出焦点边界。拆成 NSColor 版本 + Color 版本两层：View 只能用
    /// Color（ShapeStyle），但测试需要不经过 Color↔NSColor 转换直接拿到
    /// 动态 NSColor 本身才能可靠按外观 resolve；Color 版本原样转发 NSColor
    /// 版本的结果，两者不会走两条独立逻辑而漂移。
    static func nsFocusRingColor(isSelected: Bool) -> NSColor {
        isSelected ? nsInk : nsSelection
    }
    static func focusRingColor(isSelected: Bool) -> Color {
        Color(nsColor: nsFocusRingColor(isSelected: isSelected))
    }

    // MARK: - 状态色

    static let nsHealth = dynamic(light: (0.10, 0.50, 0.18), dark: (0.35, 0.82, 0.39))
    static let nsWarning = dynamic(light: (0.60, 0.40, 0.00), dark: (1.0, 0.68, 0.16))
    static let nsCritical = dynamic(light: (0.78, 0.10, 0.12), dark: (1.0, 0.32, 0.34))

    static var health: Color { Color(nsColor: nsHealth) }
    static var warning: Color { Color(nsColor: nsWarning) }
    static var critical: Color { Color(nsColor: nsCritical) }

    // MARK: - CPU 逐核占用强度色阶
    //
    // 供 CPUPanelView 的 CoreUtilizationBand 使用。最低档 low 直接复用 nsCpu/
    // selection（本身已有 ≥3:1 门槛，见下方 foregroundThresholds 测试），这里只
    // 补 moderate/active/elevated/saturated 四档——Task E.1 只 grep 了
    // `Color.white`/`Color.black`，漏掉了这四个不带外观判断的 `Color(red:green:
    // blue:)` 字面量，浅色模式下对仪表槽（raisedStrong）和面板背景（surface）都
    // 跌破 3:1，且 elevated（本意比 moderate 更告警）对比度反而比 moderate 低、
    // saturated 在深色模式下对比度反而是四档里最低的——两种外观下都存在"告警强度
    // 与对比度顺序颠倒"的问题。
    //
    // 用 WCAG 对比度公式反推每档的 RGB（脚本过程见 task-E.2-report.md），保持
    // 原色相家族（青/绿/橙/红）不变、只调整明度：浅色下越告警越深（对近乎全白的
    // 背景对比度越高），深色下越告警越亮（对近乎全黑的背景对比度越高）。两种外观
    // 分别对 raisedStrong 和 surface 都验证过 ≥3:1 且四档单调递增（数值见
    // ThemeTests.testCoreUtilizationBandContrastAndMonotonicity 与任务报告）。
    static let nsCoreModerate = dynamic(
        light: (0.034, 0.559, 0.677),
        dark: (0.180, 0.523, 0.600)
    )
    static let nsCoreActive = dynamic(
        light: (0.103, 0.514, 0.281),
        dark: (0.260, 0.577, 0.397)
    )
    static let nsCoreElevated = dynamic(
        light: (0.581, 0.324, 0.029),
        dark: (0.774, 0.492, 0.170)
    )
    static let nsCoreSaturated = dynamic(
        light: (0.616, 0.156, 0.123),
        dark: (0.973, 0.410, 0.370)
    )

    static var coreModerate: Color { Color(nsColor: nsCoreModerate) }
    static var coreActive: Color { Color(nsColor: nsCoreActive) }
    static var coreElevated: Color { Color(nsColor: nsCoreElevated) }
    static var coreSaturated: Color { Color(nsColor: nsCoreSaturated) }

    // MARK: - 指标 series 强调色

    static let nsCpu = nsSelection
    static let nsMemory = dynamic(light: (0.46, 0.16, 0.72), dark: (0.68, 0.34, 0.94))
    static let nsDisk = nsWarning
    static let nsGpu = dynamic(light: (0.72, 0.10, 0.48), dark: (0.95, 0.38, 0.72))
    static let nsBattery = nsHealth
    static let nsNetworkInput = dynamic(light: (0.00, 0.42, 0.60), dark: (0.18, 0.72, 0.91))
    /// 网络输出（上传）与 warning 共用同一组取值，是既有设计如此，不是巧合别名。
    static let nsNetworkOutput = nsWarning
    /// Accent color for AI subscription quota views (verified >= 5.4:1 contrast on light/dark `raisedStrong`).
    static let nsAiUsage = dynamic(light: (0.30, 0.26, 0.76), dark: (0.55, 0.53, 1.00))
    /// Accent colors for Codex and Antigravity AI quota cards (verified >= 4.7:1 contrast on light/dark `raisedStrong`).
    static let nsAiCodex = dynamic(light: (0.05, 0.45, 0.34), dark: (0.26, 0.80, 0.62))
    static let nsAiAntigravity = dynamic(light: (0.06, 0.36, 0.78), dark: (0.36, 0.66, 1.00))

    static var cpu: Color { Color(nsColor: nsCpu) }
    static var memory: Color { Color(nsColor: nsMemory) }
    static var disk: Color { Color(nsColor: nsDisk) }
    static var gpu: Color { Color(nsColor: nsGpu) }
    static var battery: Color { Color(nsColor: nsBattery) }
    static var aiUsage: Color { Color(nsColor: nsAiUsage) }
    static var aiCodex: Color { Color(nsColor: nsAiCodex) }
    static var aiAntigravity: Color { Color(nsColor: nsAiAntigravity) }

    /// Returns the semantic accent color for `providerID` in AI quota cards and badges.
    static func aiProviderAccent(for providerID: AIUsageProviderID) -> Color {
        switch providerID {
        case .claude: return aiUsage
        case .codex: return aiCodex
        case .antigravity: return aiAntigravity
        }
    }
    /// 网络输入（下载）固定为青色，网络输出（上传）固定为琥珀色。
    /// 使用方向语义命名，避免图表实现把两条 series 误用为同一 token。
    ///
    /// 注意：这两个 token 之间刻意不设 WCAG 亮度对比度门槛。青色与琥珀色色相差异
    /// 很大、相对亮度却接近——人眼凭色相就能轻松区分两者，但 WCAG 的相对亮度对比度
    /// 公式只看亮度、不看色相，拿它衡量“两条 series 是否可区分”是错误的度量，强行
    /// 满足亮度比只会逼出偏离设计意图的颜色。色觉障碍场景下的可辨识性交给 Task E.3
    /// 的 differentiateWithoutColor 线型冗余负责，不靠这里的亮度对比度兜底。
    static var networkInput: Color { Color(nsColor: nsNetworkInput) }
    static var networkOutput: Color { Color(nsColor: nsNetworkOutput) }

    /// 面板浮层背景，取值与 `surface` 一致。PanelHost 直接把它写进 CALayer，
    /// 需要 NSColor 而非 SwiftUI Color。
    static let panelBackground = nsSurface

    // MARK: - 原生毛玻璃与精密层次（Glass & Precision Elevation）

    /// 是否开启系统“降低透明度”辅助功能；开启时所有毛玻璃表面自动回退到高对比不透明表面。
    static var shouldReduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    /// 叠在 NSVisualEffectView 之上的轻薄语义底色，平衡不同壁纸下的整体可读性。
    static let nsPanelBackdropTint = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if isDark {
            return NSColor(srgbRed: 0.055, green: 0.067, blue: 0.085, alpha: 0.56)
        }
        return NSColor(srgbRed: 0.98, green: 0.985, blue: 0.995, alpha: 0.58)
    }

    /// 面板外缘 0.5pt 精密边框（深色微亮高光边，浅色微暗轮廓边）。
    static let nsPanelBorder = dynamicOverlay(lightAlpha: 0.14, darkAlpha: 0.16)

    /// 玻璃面板之上的卡片半透明表面，兼顾通透感与 WCAG 前景可读性。
    static let nsCardFill = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if isDark {
            return NSColor(srgbRed: 0.115, green: 0.135, blue: 0.165, alpha: 0.58)
        }
        return NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.68)
    }

    /// 卡片极细描边（0.5pt），取代厚重实线边框以降低“框套框”噪音。
    static let nsCardHairline = dynamicOverlay(lightAlpha: 0.08, darkAlpha: 0.095)

    /// 卡片顶部边缘微弱镜面高光，塑造 macOS 原生浮层纵深。
    static let nsCardTopHighlight = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: isDark ? 0.10 : 0.72)
    }

    /// 分段控件与进度条的凹陷轨道背景。
    static let nsControlTrack = dynamicOverlay(lightAlpha: 0.06, darkAlpha: 0.08)

    /// 分段控件选中态悬浮胶囊滑块背景。
    static let nsControlThumb = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if isDark {
            return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.15)
        }
        return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.94)
    }

    /// 底部导航 Dock 的半透明独立底板。
    static let nsDockSurface = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if isDark {
            return NSColor(srgbRed: 0.065, green: 0.080, blue: 0.100, alpha: 0.54)
        }
        return NSColor(srgbRed: 0.96, green: 0.97, blue: 0.985, alpha: 0.56)
    }

    /// 图表内部极淡虚线网格颜色。
    static let nsChartGrid = dynamicOverlay(lightAlpha: 0.07, darkAlpha: 0.07)

    static var panelBackdropTint: Color { Color(nsColor: nsPanelBackdropTint) }
    static var panelBorder: Color { Color(nsColor: nsPanelBorder) }
    static var cardFill: Color { shouldReduceTransparency ? raised : Color(nsColor: nsCardFill) }
    static var cardHairline: Color { Color(nsColor: nsCardHairline) }
    static var cardTopHighlight: Color { Color(nsColor: nsCardTopHighlight) }
    static var controlTrack: Color { shouldReduceTransparency ? raisedStrong : Color(nsColor: nsControlTrack) }
    static var controlThumb: Color { shouldReduceTransparency ? selectedFill : Color(nsColor: nsControlThumb) }
    static var dockSurface: Color { shouldReduceTransparency ? raised : Color(nsColor: nsDockSurface) }
    static var chartGrid: Color { Color(nsColor: nsChartGrid) }

    static func color(for series: Series) -> NSColor {
        switch series {
        case .cpu: return nsCpu
        case .memory: return nsMemory
        case .disk: return nsDisk
        case .gpu: return nsGpu
        case .battery: return nsBattery
        case .networkInput: return nsNetworkInput
        case .networkOutput: return nsNetworkOutput
        }
    }
}

// MARK: - WCAG 对比度校验辅助
//
// ThemeTests 用它验证 token 达标；Task E.3 的图表配色也会复用 contrastRatio，
// 因此放在这里而不是测试文件里。

extension NSColor {
    /// 在指定外观下解析动态颜色，供对比度校验使用。
    func resolved(for appearanceName: NSAppearance.Name) -> NSColor {
        var resolved = self
        NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
            resolved = self.usingColorSpace(.sRGB) ?? self
        }
        return resolved
    }
}

extension Theme {
    /// WCAG 2.1 相对亮度对比度，返回值域 1.0 ... 21.0。
    static func contrastRatio(_ lhs: NSColor, _ rhs: NSColor) -> Double {
        let lighter = max(relativeLuminance(lhs), relativeLuminance(rhs))
        let darker = min(relativeLuminance(lhs), relativeLuminance(rhs))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(_ color: NSColor) -> Double {
        guard let srgb = color.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(srgb.redComponent)
            + 0.7152 * channel(srgb.greenComponent)
            + 0.0722 * channel(srgb.blueComponent)
    }
}
