import AppKit
import SwiftUI
import XCTest
@testable import LynxBar

@MainActor
final class CPUCoreGaugeTests: XCTestCase {
    // MARK: - 逐核占用强度色阶：对比度与单调性
    //
    // 背景（E.1 审查复核发现，E.1 当时只 grep 了 `Color.white`/`Color.black`，
    // 漏掉了 moderate/active/elevated/saturated 四个不带外观判断的
    // `Color(red:green:blue:)` 字面量）：
    //   - 浅色模式下对仪表槽（raisedStrong）和面板背景（surface）的对比度实测
    //     只有 1.51–2.40 / 1.78–2.83，全部低于本 Change 对图形对象强制的 3:1。
    //   - 更糟的是 elevated（本意比 moderate 更告警）浅色对比度反而比 moderate
    //     低；saturated 在深色模式下的对比度反而是四档里最低的——两种外观下都有
    //     "告警强度与对比度顺序颠倒"的问题，且没有任何测试覆盖到过，这正是它被
    //     漏掉的原因。
    //
    // 已改为 Theme.swift 里的双外观语义 token（nsCoreModerate/nsCoreActive/
    // nsCoreElevated/nsCoreSaturated）。这里锁住两件事：每档在两种外观下对两个
    // 真实背景都 ≥3:1；四档按 moderate<active<elevated<saturated 的告警顺序，
    // 对比度严格单调递增，不允许反过来。
    //
    // 范围说明：`.low` 档复用既有的 `Theme.cpu`（= `nsSelection`，被 selection/
    // 焦点环等多处共享，且已有自己的 ≥3:1 门槛测试），不在本次"4 处硬编码颜色"
    // 的修复范围内，因此不并入这条单调链——实测 low 对两个背景的对比度
    // （浅色 4.85/5.71，深色 4.67/5.48）本身就高于 moderate，如果强行把 low 也
    // 并入同一条严格单调序列，会需要改动 nsSelection/nsCpu 这个被广泛复用的
    // token，超出这次要修的范围，因此这里只锁 moderate→saturated 四档之间的
    // 单调性。

    private static let coreBandOrder: [(name: String, color: NSColor)] = [
        ("moderate", Theme.nsCoreModerate),
        ("active", Theme.nsCoreActive),
        ("elevated", Theme.nsCoreElevated),
        ("saturated", Theme.nsCoreSaturated),
    ]

    /// 仪表实际画的两层背景：`CompactCoreGaugeStyle` 的槽本身是 `raisedStrong`，
    /// 仪表所在卡片又坐落在 `surface` 之上的页面里——两个都要达标，缺一个都可能
    /// 在真实视觉里读不出来。
    func testCoreUtilizationBandColorsMeetMinimumContrastOnBothAppearances() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let raisedStrong = Theme.nsRaisedStrong.resolved(for: appearance)
            let surface = Theme.nsSurface.resolved(for: appearance)
            for (name, color) in Self.coreBandOrder {
                let resolved = color.resolved(for: appearance)
                let ratioAgainstTrack = Theme.contrastRatio(resolved, raisedStrong)
                let ratioAgainstSurface = Theme.contrastRatio(resolved, surface)
                XCTAssertGreaterThanOrEqual(
                    ratioAgainstTrack, 3.0,
                    "\(appearance.rawValue) 下 \(name) 对仪表槽(raisedStrong)对比度 \(ratioAgainstTrack) 不足 3:1"
                )
                XCTAssertGreaterThanOrEqual(
                    ratioAgainstSurface, 3.0,
                    "\(appearance.rawValue) 下 \(name) 对面板背景(surface)对比度 \(ratioAgainstSurface) 不足 3:1"
                )
            }
        }
    }

    /// 如果有人把某一档的颜色改得比"更轻微"的档位更不显眼（例如原 bug 里
    /// elevated 比 moderate 还暗淡），这里必须红——覆盖两种外观、两个背景，
    /// 四种组合缺一不可，因为原 bug 是浅色/深色各自独立地在不同背景上颠倒。
    func testCoreUtilizationBandContrastIncreasesMonotonicallyWithSeverity() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (backdropName, backdrop) in [
                ("raisedStrong", Theme.nsRaisedStrong.resolved(for: appearance)),
                ("surface", Theme.nsSurface.resolved(for: appearance)),
            ] {
                let ratios = Self.coreBandOrder.map {
                    Theme.contrastRatio($0.color.resolved(for: appearance), backdrop)
                }
                for index in 1..<ratios.count {
                    let previous = Self.coreBandOrder[index - 1].name
                    let current = Self.coreBandOrder[index].name
                    XCTAssertLessThan(
                        ratios[index - 1], ratios[index],
                        "\(appearance.rawValue) 对 \(backdropName)：\(previous)(\(ratios[index - 1])) "
                            + "应当严格低于更告警的 \(current)(\(ratios[index]))，告警强度与对比度顺序颠倒了"
                    )
                }
            }
        }
    }

    func testUtilizationBandsUseStableInclusiveBoundaries() {
        let cases: [(Double, CoreUtilizationBand)] = [
            (0.000, .low),
            (0.349, .low),
            (0.350, .moderate),
            (0.449, .moderate),
            (0.450, .active),
            (0.599, .active),
            (0.600, .elevated),
            (0.849, .elevated),
            (0.850, .saturated),
            (1.000, .saturated),
        ]

        for (usage, expected) in cases {
            XCTAssertEqual(
                CoreUtilizationBand.resolve(usage),
                expected,
                "Unexpected band for \(usage)"
            )
        }
    }

    func testUtilizationNormalizationClampsRangeAndRejectsNonFiniteValues() {
        XCTAssertEqual(CoreUtilizationBand.normalized(-0.2), 0)
        XCTAssertEqual(CoreUtilizationBand.normalized(1.2), 1)
        XCTAssertEqual(CoreUtilizationBand.normalized(.nan), 0)
        XCTAssertEqual(CoreUtilizationBand.normalized(.infinity), 0)
        XCTAssertEqual(CoreUtilizationBand.normalized(-.infinity), 0)
    }

    func testTwelveCoreGaugeRowFitsBaselineCardContentWidth() {
        XCTAssertEqual(CoreGaugeLayout.rowWidth(itemCount: 0), 0)
        XCTAssertEqual(CoreGaugeLayout.rowWidth(itemCount: 12), 380)
        XCTAssertLessThanOrEqual(
            CoreGaugeLayout.rowWidth(itemCount: 12),
            CoreGaugeLayout.baselineContentWidth
        )
    }

    // MARK: - 圆环内不再画读数：溢出回归锁
    //
    // 这两条锁住 33f94a1 引入、eb0dbf4 放大后暴露的一个真实缺陷：逐核百分比读数
    // 原本画在 28pt 圆环内部，靠 `.system(size: 6.2)` 恰好塞得下；eb0dbf4 把它接进
    // Dynamic Type 的 `.caption2`（macOS 实测 10pt）后，"54.9%" 的内在宽度涨到
    // 32.9pt——比圆环外径还宽，横向盖住描边并压到相邻核心上，默认字号下就已复现。
    //
    // 更要紧的是当时写在注释里的 "lineLimit(1) + minimumScaleFactor 兜底防止溢出"
    // 是一条从未生效的死代码：`.frame(width:28,height:28)` 加在 `Gauge` 外层，
    // SwiftUI 的 frame 只把子视图居中放置，既不裁剪也不把宽度约束传给内部的 Text，
    // 缩放逻辑因此没有触发条件。实测把下限从 0.78 一路降到 0.1，渲染结果零变化——
    // 所以不要再指望 minimumScaleFactor 能在这里救场。
    //
    // 现在读数改由 `accessibilityValue` 与 `.help()` tooltip 承载，环内不画文本，
    // 强度只靠颜色和弧长表达；精确数值不丢（由下面既有的 accessibility 测试锁住）。

    /// 用与视图完全一致的字体配置（rounded + monospacedDigit + semibold）实测宽度。
    private static func readoutWidth(_ text: String, pointSize: CGFloat) -> CGFloat {
        let base = NSFont.monospacedDigitSystemFont(ofSize: pointSize, weight: .semibold)
        let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        let font = NSFont(descriptor: descriptor, size: pointSize) ?? base
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// 固化"为什么环内不能放读数"这个结论：语义字阶最小的一档仍然放不下。
    /// 如果有人想把数字塞回圆环，这条会先红，并直接给出差了多少 pt。
    func testDynamicTypePercentReadoutCannotFitInsideRing() {
        let caption2 = NSFont.preferredFont(forTextStyle: .caption2).pointSize
        let inner = CoreGaugeLayout.ringInnerDiameter

        // 最宽的真实读数形态：三位有效数字 + 小数位 + 百分号。
        for sample in ["54.9%", "100%"] {
            let width = Self.readoutWidth(sample, pointSize: caption2)
            XCTAssertGreaterThan(
                width, inner,
                "\(sample) 在 .caption2(\(caption2)pt) 下宽 \(width)pt，本应超过环内可用直径 "
                    + "\(inner)pt——如果这条不再成立，说明字体度量或圆环尺寸变了，"
                    + "环内放读数的禁令需要重新评估，而不是直接放行。"
            )
        }

        // 对照：历史上那个恰好塞得下的固定字号，说明缺陷来自字号跃迁而非圆环变小。
        XCTAssertLessThan(
            Self.readoutWidth("54.9%", pointSize: 6.2), inner,
            "6.2pt 的历史读数本应塞得进 \(inner)pt 内径——这是判断"
                + "「溢出由 Dynamic Type 字号跃迁引入」的对照基准。"
        )
    }

    /// 结构锁：`CompactCoreGaugeStyle` 不得再渲染 `currentValueLabel`。
    /// 沿用 `TypographyTests` 的源码扫描思路，并保留同样的防假绿前置断言。
    func testCoreGaugeStyleDrawsNoTextInsideRing() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LynxBarTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("Sources/LynxBar/Modules/CPU/CPUPanelView.swift")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: source.path),
            "#filePath 推出的 CPUPanelView.swift 不存在：\(source.path)——路径解析异常时，"
                + "下面的「未发现违规」不可信。"
        )

        let contents = try String(contentsOf: source, encoding: .utf8)

        // 防假绿：确认真的读到了这份文件，而不是同名空文件。
        XCTAssertTrue(
            contents.contains("struct CompactCoreGaugeStyle"),
            "读到的文件里找不到 CompactCoreGaugeStyle，扫描目标不对：\(source.path)"
        )

        XCTAssertFalse(
            contents.contains("currentValueLabel"),
            "圆环内径只有 \(CoreGaugeLayout.ringInnerDiameter)pt，装不下 Dynamic Type 下的"
                + "百分比读数（见 testDynamicTypePercentReadoutCannotFitInsideRing）。"
                + "精确数值请继续走 accessibilityValue 和 .help() tooltip，不要画回环内。"
        )
    }

    func testGaugeKeepsCoreIdentityAndNumericAccessibilityValue() {
        let gauge = CoreUtilizationGauge(coreIndex: 2, usage: 0.549)

        XCTAssertFalse(gauge.accessibilityLabelText.isEmpty)
        XCTAssertTrue(gauge.accessibilityLabelText.hasSuffix("3"))
        XCTAssertEqual(gauge.accessibilityValueText, "54.9%")
        XCTAssertEqual(gauge.normalizedUsage, 0.549)
    }

    /// 圆环不得越过自己那 28pt 的布局位。
    ///
    /// `Circle().stroke(lineWidth:)` 的描边居中骑在路径上，一半落在 frame 之外，
    /// 视觉外径会撑到 `gaugeDiameter + ringLineWidth`；实测 30.5pt 对 28pt 的
    /// `itemWidth`，每侧多出 1.5pt，把 4pt 的 `itemSpacing` 吃到只剩 1.5pt，相邻
    /// 仪表几乎顶在一起。描边必须走 `strokeBorder` / `inset` 收进形状内侧。
    ///
    /// 这条锁直接把真视图渲染成位图再量描边跨度，不做源码字符串匹配——换任何
    /// 写法只要视觉外径超了都会红。
    func testGaugeRingStaysWithinItsLayoutWidth() throws {
        // usage = 0：进度弧为空，量到的就是背景槽本身的视觉外径。
        let hostWidth = CoreGaugeLayout.itemWidth * 2
        let host = NSHostingView(rootView: CoreUtilizationGauge(coreIndex: 0, usage: 0))
        host.frame = NSRect(x: 0, y: 0, width: hostWidth, height: 44)
        host.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            host.bitmapImageRepForCachingDisplay(in: host.bounds),
            "无法为 NSHostingView 建立离屏位图"
        )
        host.cacheDisplay(in: host.bounds, to: bitmap)

        let scaleX = CGFloat(bitmap.pixelsWide) / hostWidth
        let scaleY = CGFloat(bitmap.pixelsHigh) / host.bounds.height
        // 圆环垂直中心：VStack 首个元素，居中行必然穿过左右两侧描边。
        let row = Int(CoreGaugeLayout.gaugeDiameter / 2 * scaleY)

        var minX: Int?
        var maxX: Int?
        for x in 0..<bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: row), color.alphaComponent > 0.1 else {
                continue
            }
            if minX == nil { minX = x }
            maxX = x
        }

        let left = try XCTUnwrap(minX, "中心行没有渲染出任何描边像素，渲染管线可能没生效")
        let right = try XCTUnwrap(maxX)
        let visualDiameter = CGFloat(right - left + 1) / scaleX

        XCTAssertLessThanOrEqual(
            visualDiameter, CoreGaugeLayout.itemWidth,
            String(
                format: "圆环视觉外径 %.2fpt 超过布局位 %.2fpt，每侧溢出 %.2fpt——"
                    + "描边居中骑在路径上了，请用 strokeBorder / inset 收进内侧。",
                visualDiameter, CoreGaugeLayout.itemWidth,
                (visualDiameter - CoreGaugeLayout.itemWidth) / 2
            )
        )
    }

    /// 环内读数移除后，鼠标用户读精确值只剩 tooltip 这一条路——它必须同时带上
    /// 核心身份和数值，否则「拿掉数字」就变成了净损失。
    func testTooltipCarriesBothCoreIdentityAndExactValue() {
        let gauge = CoreUtilizationGauge(coreIndex: 2, usage: 0.549)

        XCTAssertTrue(
            gauge.tooltipText.contains(gauge.accessibilityLabelText),
            "tooltip 里丢了核心身份：\(gauge.tooltipText)"
        )
        XCTAssertTrue(
            gauge.tooltipText.contains("54.9%"),
            "tooltip 里丢了精确读数：\(gauge.tooltipText)"
        )
    }
}
