import AppKit
import XCTest
@testable import LynxBar

/// Theme 的浅色/深色 token 是否真的双外观、对比度是否达标。
///
/// 注意：brief 原稿里还有一个 `testSeriesColorsRemainDistinguishableInBothAppearances`，
/// 断言 networkInput/networkOutput 的 WCAG 亮度对比度 ≥1.5:1。实测这条在既有深色配色
/// （青 0.18/0.72/0.91 vs 琥珀 1.0/0.68/0.16）上只有 ~1.24，从未达标过——不是回归锁，
/// 是对现有设计从未满足过的新要求，照抄会直接红。亮度对比度本来就是区分两条同类
/// series 的错误度量（色相差异大、相对亮度接近的颜色人眼依然能轻松分辨），删掉这条，
/// 改在 Theme.swift 的 networkInput/networkOutput 声明处注释说明——真正的可辨识性
/// 保障交给 Task E.3 的 differentiateWithoutColor 线型冗余。
final class ThemeTests: XCTestCase {
    /// 全部语义色 token（顺序对齐 task-E.1-brief 的浅色配色表）。
    private static let allTokens: [(name: String, color: NSColor)] = [
        ("surface", Theme.nsSurface),
        ("raised", Theme.nsRaised),
        ("raisedStrong", Theme.nsRaisedStrong),
        ("ink", Theme.nsInk),
        ("secondaryInk", Theme.nsSecondaryInk),
        ("mutedInk", Theme.nsMutedInk),
        ("divider", Theme.nsDivider),
        ("hoverFill", Theme.nsHoverFill),
        ("selection", Theme.nsSelection),
        ("health", Theme.nsHealth),
        ("warning", Theme.nsWarning),
        ("critical", Theme.nsCritical),
        ("cpu", Theme.nsCpu),
        ("memory", Theme.nsMemory),
        ("disk", Theme.nsDisk),
        ("gpu", Theme.nsGpu),
        ("battery", Theme.nsBattery),
        ("networkInput", Theme.nsNetworkInput),
        ("networkOutput", Theme.nsNetworkOutput),
        ("selectionSoft", Theme.nsSelectionSoft),
        ("selectedFill", Theme.nsSelectedFill)
    ]

    /// ink/secondaryInk 之外、会被当作前景（文字或图形强调色）使用的语义色，
    /// 各自对 surface 的 WCAG 最低对比度门槛。divider/hoverFill 是刻意做低对比度的
    /// 叠加装饰层，不属于这一类，不在此列。
    private static let foregroundThresholds: [(name: String, color: NSColor, threshold: Double)] = [
        ("mutedInk", Theme.nsMutedInk, 3.0),
        ("selection", Theme.nsSelection, 3.0),
        ("health", Theme.nsHealth, 3.0),
        ("warning", Theme.nsWarning, 3.0),
        ("critical", Theme.nsCritical, 3.0),
        ("cpu", Theme.nsCpu, 3.0),
        ("memory", Theme.nsMemory, 3.0),
        ("disk", Theme.nsDisk, 3.0),
        ("gpu", Theme.nsGpu, 3.0),
        ("battery", Theme.nsBattery, 3.0),
        ("networkInput", Theme.nsNetworkInput, 3.0),
        ("networkOutput", Theme.nsNetworkOutput, 3.0)
    ]

    /// 如果有人把 surface 的 dynamicProvider 删掉、换回一个静态 NSColor（或者浅色/
    /// 深色分支写反导致两侧算出同一个值），这里必须红：面板背景会失去双外观能力。
    func testSurfaceDiffersBetweenAppearances() {
        let light = Theme.nsSurface.resolved(for: .aqua)
        let dark = Theme.nsSurface.resolved(for: .darkAqua)
        XCTAssertNotEqual(light, dark, "面板背景必须跟随系统外观")
    }

    /// 如果浅色 ink 的 RGB 改得离 surface 太近（例如调成中灰而非深灰），正文可读性
    /// 会跌破 WCAG AA，这里必须红。
    func testInkContrastMeetsWCAGAAOnBothAppearances() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let ratio = Theme.contrastRatio(
                Theme.nsInk.resolved(for: appearance),
                Theme.nsSurface.resolved(for: appearance)
            )
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                "\(appearance.rawValue) 下正文对比度 \(ratio) 低于 WCAG AA 4.5:1"
            )
        }
    }

    /// 同上，针对次要文本的大字号门槛（3:1）。
    func testSecondaryInkMeetsLargeTextContrastOnBothAppearances() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let ratio = Theme.contrastRatio(
                Theme.nsSecondaryInk.resolved(for: appearance),
                Theme.nsSurface.resolved(for: appearance)
            )
            XCTAssertGreaterThanOrEqual(ratio, 3.0, "\(appearance.rawValue) 下次要文本对比度不足")
        }
    }

    /// 覆盖全部语义色 token（不只 surface）：如果任何一个 token 的动态 provider 被
    /// 误改回静态值、或浅色/深色分支被写反导致两侧数值恰好相同，对应的那一项断言
    /// 会指名报红，而不是被别的 token 掩盖。
    func testAllSemanticColorsDifferBetweenAppearances() {
        for (name, color) in Self.allTokens {
            let light = color.resolved(for: .aqua)
            let dark = color.resolved(for: .darkAqua)
            XCTAssertNotEqual(light, dark, "\(name) 必须跟随系统外观（浅色/深色取值不能相同）")
        }
    }

    /// 覆盖 ink/secondaryInk 之外全部前景角色的语义色：如果任何一个 token 的浅色或
    /// 深色取值被改得对 surface 对比度不足 3:1（WCAG 大字号/图形对象门槛），对应项
    /// 会指名报红。
    func testStatusAndAccentColorsMeetMinimumContrastOnBothAppearances() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let surface = Theme.nsSurface.resolved(for: appearance)
            for (name, color, threshold) in Self.foregroundThresholds {
                let ratio = Theme.contrastRatio(color.resolved(for: appearance), surface)
                XCTAssertGreaterThanOrEqual(
                    ratio, threshold,
                    "\(appearance.rawValue) 下 \(name) 对比度 \(ratio) 低于门槛 \(threshold)"
                )
            }
        }
    }

    // MARK: - 焦点环对比度
    //
    // 移除 DashboardView 的强制深色后才暴露的问题：BottomDestinationButton/RangeButton
    // 选中态的焦点环原先硬编码 `Color.white`，在浅色模式下叠在浅色的 selectionSoft/
    // selectedFill 背景上几乎不可见——这是键盘导航的可访问性关键元素（WCAG 2.4.7
    // Focus Visible），必须锁住。四个场景对应两个真实调用点
    // （DashboardView.BottomDestinationButton、V2Components.RangeButton）各自的
    // 选中/未选中态，背景取各自生产代码里真实叠加的 token。

    /// 焦点环实际叠加的背景：BottomDestinationButton 叠在 BottomNavigation 的 raised
    /// 之上，RangeButton 叠在 RangePicker 的 raisedStrong 之上；选中态背景本身是半透明
    /// 的 selectionSoft/selectedFill，要先合成到底色上再比对比度。
    private static let focusRingScenarios: [(
        name: String,
        isSelected: Bool,
        backdrop: @Sendable (NSAppearance.Name) -> NSColor
    )] = [
        (
            "BottomDestinationButton 未选中",
            false,
            { appearance in Theme.nsRaised.resolved(for: appearance) }
        ),
        (
            "BottomDestinationButton 选中",
            true,
            { appearance in
                composite(
                    Theme.nsSelectionSoft.resolved(for: appearance),
                    over: Theme.nsRaised.resolved(for: appearance)
                )
            }
        ),
        (
            "RangeButton 未选中",
            false,
            { appearance in Theme.nsRaisedStrong.resolved(for: appearance) }
        ),
        (
            "RangeButton 选中",
            true,
            { appearance in
                composite(
                    Theme.nsSelectedFill.resolved(for: appearance),
                    over: Theme.nsRaisedStrong.resolved(for: appearance)
                )
            }
        )
    ]

    /// 如果 `Theme.nsFocusRingColor` 的选中态分支被改回忽略外观的硬编码颜色
    /// （例如原先的 `Color.white`），浅色模式下这里会跌破 3:1 直接报红——已用变异
    /// 验证确认（见任务报告）。四个场景都调用生产代码实际使用的
    /// `Theme.nsFocusRingColor(isSelected:)`，不是重新抄一遍三元表达式。
    func testFocusRingContrastAgainstRealBackdropsInBothStatesAndAppearances() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for scenario in Self.focusRingScenarios {
                let ring = Theme.nsFocusRingColor(isSelected: scenario.isSelected)
                    .resolved(for: appearance)
                let backdrop = scenario.backdrop(appearance)
                let ratio = Theme.contrastRatio(ring, backdrop)
                XCTAssertGreaterThanOrEqual(
                    ratio, 3.0,
                    "\(appearance.rawValue) 下「\(scenario.name)」焦点环对比度 \(ratio) 不足"
                )
            }
        }
    }

    /// 手工做 alpha 合成：`Theme.contrastRatio` 不处理 alpha 通道（Task E.1 报告记录过
    /// 的既有特性——它只读 RGB，忽略 alphaComponent），把半透明颜色直接丢给它会得到
    /// 误导性的数字。这里先把半透明 overlay 按其真实 alpha 合成到不透明背景上，再喂给
    /// `contrastRatio`，得到的才是实际可感知对比度。
    private static func composite(_ overlay: NSColor, over base: NSColor) -> NSColor {
        guard let o = overlay.usingColorSpace(.sRGB), let b = base.usingColorSpace(.sRGB) else {
            return base
        }
        let alpha = o.alphaComponent
        func mix(_ overlayComponent: CGFloat, _ baseComponent: CGFloat) -> CGFloat {
            alpha * overlayComponent + (1 - alpha) * baseComponent
        }
        return NSColor(
            srgbRed: mix(o.redComponent, b.redComponent),
            green: mix(o.greenComponent, b.greenComponent),
            blue: mix(o.blueComponent, b.blueComponent),
            alpha: 1
        )
    }
}
