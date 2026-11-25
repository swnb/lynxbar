import AppKit
import SwiftUI
import XCTest
@testable import LynxBar

@MainActor
final class InteractiveSurfaceTests: XCTestCase {
    func testPlainButtonTransparentEdgeActivatesFullInteractiveSurface() throws {
        let recorder = ActionRecorder()
        let button = Button {
            recorder.count += 1
        } label: {
            Text("CPU")
                .frame(width: 100, height: 40)
                .v2InteractiveSurface()
        }
        .buttonStyle(.plain)

        let hostingView = NSHostingView(rootView: button)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // 左下边缘远离居中的 “CPU” 文本，专门锁定透明 frame 的命中行为。
        let edge = NSPoint(x: 4, y: 4)
        let down = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: edge,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )
        let up = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: edge,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 2,
                clickCount: 1,
                pressure: 0
            )
        )

        window.sendEvent(down)
        window.sendEvent(up)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(recorder.count, 1)
    }

    func testScrollableRankingKeepsAllRowsReachableInsideFixedViewport() throws {
        let ranking = ScrollableProcessRanking(
            rowCount: 10,
            visibleRowCount: 3,
            rowHeight: 22
        ) {
            ForEach(0..<10, id: \.self) { index in
                Text("Process \(index)")
                    .frame(maxWidth: .infinity, minHeight: 22)
            }
        }

        let hostingView = NSHostingView(rootView: ranking)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 66),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let scrollView = try XCTUnwrap(firstScrollView(in: hostingView))
        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertGreaterThan(
            scrollView.documentView?.bounds.height ?? 0,
            scrollView.contentView.bounds.height
        )

        let initialOrigin = scrollView.contentView.bounds.origin
        let documentHeight = scrollView.documentView?.bounds.height ?? 0
        let endY = max(0, documentHeight - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: initialOrigin.x, y: endY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNotEqual(scrollView.contentView.bounds.origin, initialOrigin)
    }

    func testCompactDurationKeepsSecondLevelCoverageVisible() {
        XCTAssertEqual(Formatters.compactDuration(0), "0s")
        XCTAssertEqual(Formatters.compactDuration(59.9), "59s")
        XCTAssertEqual(Formatters.compactDuration(125), "2m 5s")
        XCTAssertEqual(Formatters.compactDuration(3_661), "1h 1m")
    }

    func testScrollableRankingKeepsAnchorAcrossStableIdentityUpdates() throws {
        let model = RankingTestModel()
        let hostingView = NSHostingView(rootView: RankingUpdateHarness(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 66),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let scrollView = try XCTUnwrap(firstScrollView(in: hostingView))
        let endY = max(
            0,
            (scrollView.documentView?.bounds.height ?? 0)
                - scrollView.contentView.bounds.height
        )
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: endY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let anchoredY = scrollView.contentView.bounds.origin.y

        // 真实采样会替换行值，但 PID identity 与滚动容器 identity 保持稳定。
        model.rows = model.rows.map {
            RankingTestRow(id: $0.id, value: $0.value + 100)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            scrollView.contentView.bounds.origin.y,
            anchoredY,
            accuracy: 1
        )
    }

    func testExpandedMemoryPageKeepsCompositionReachableInDashboardViewport() throws {
        let memory = MemoryViewModel(settings: .shared)
        let processes = ProcessViewModel(settings: .shared)
        let view = MemoryPanelView(
            viewModel: memory,
            processViewModel: processes,
            compositionInitiallyExpanded: true
        )
        .environment(\.locale, Locale(identifier: "zh-Hans"))

        let hostingView = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 496),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        let scrollViews = allScrollViews(in: hostingView)
        // 此 fixture 没有进程行，因此这里只锁定外层页面；内层排行的
        // overflow 与 anchor 由本文件的两个 ScrollableProcessRanking 测试覆盖。
        XCTAssertFalse(scrollViews.isEmpty)
        let pageScroll = try XCTUnwrap(
            scrollViews.max {
                $0.contentView.bounds.height < $1.contentView.bounds.height
            }
        )
        let viewportHeight = pageScroll.contentView.bounds.height
        let documentHeight = pageScroll.documentView?.bounds.height ?? 0
        XCTAssertGreaterThan(documentHeight, viewportHeight)

        let initialOrigin = pageScroll.contentView.bounds.origin
        let endY = max(0, documentHeight - viewportHeight)
        pageScroll.contentView.scroll(to: NSPoint(x: initialOrigin.x, y: endY))
        pageScroll.reflectScrolledClipView(pageScroll.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNotEqual(pageScroll.contentView.bounds.origin, initialOrigin)
    }

    func testIconFirstHeaderKeepsShortCopyAndFullAccessibilityMeaning() {
        let header = IconSectionHeader(
            systemName: "chart.xyaxis.line",
            title: "Usage trend",
            tint: Theme.memory,
            accessibilityLabel: "Memory capacity used"
        )

        XCTAssertEqual(header.title, "Usage trend")
        XCTAssertEqual(header.accessibilityLabel, "Memory capacity used")
        XCTAssertGreaterThanOrEqual(V2LayoutPolicy.chartHeaderToPlot, 6)
        XCTAssertGreaterThan(
            V2LayoutPolicy.expandedSectionRevealDelayNanoseconds,
            UInt64(V2LayoutPolicy.disclosureExpansionDuration * 1_000_000_000)
        )
        XCTAssertEqual(V2LayoutPolicy.overviewAttentionCardHeight, 61)
        XCTAssertGreaterThanOrEqual(V2LayoutPolicy.overviewAttentionCardVerticalPadding, 8)
        XCTAssertLessThan(
            V2LayoutPolicy.overviewAttentionCardVerticalPadding * 2,
            V2LayoutPolicy.overviewAttentionCardHeight
        )
    }

    func testVisibleHistoryStatusOmitsCompleteWindowCopy() {
        let point = MetricPoint(timestamp: Date(), value: 0.5)
        let complete = MetricHistoryResult(
            range: .minute,
            points: [point],
            availableDuration: 60,
            isWarmingUp: false
        )
        let warming = MetricHistoryResult(
            range: .minute,
            points: [point],
            availableDuration: 20,
            isWarmingUp: true
        )

        XCTAssertNil(visibleHistoryStatus(complete))
        XCTAssertNotNil(visibleHistoryStatus(warming))
        XCTAssertNotNil(visibleHistoryStatus(.empty(.minute)))
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let match = firstScrollView(in: subview) { return match }
        }
        return nil
    }

    private func allScrollViews(in view: NSView) -> [NSScrollView] {
        var matches: [NSScrollView] = []
        if let scrollView = view as? NSScrollView {
            matches.append(scrollView)
        }
        for subview in view.subviews {
            matches.append(contentsOf: allScrollViews(in: subview))
        }
        return matches
    }
}

@MainActor
private final class ActionRecorder {
    var count = 0
}

@MainActor
private final class RankingTestModel: ObservableObject {
    @Published var rows = (0..<10).map {
        RankingTestRow(id: $0, value: $0)
    }
}

private struct RankingTestRow: Identifiable {
    let id: Int
    let value: Int
}

private struct RankingUpdateHarness: View {
    @ObservedObject var model: RankingTestModel

    var body: some View {
        ScrollableProcessRanking(
            rowCount: model.rows.count,
            visibleRowCount: 3,
            rowHeight: 22
        ) {
            ForEach(model.rows) { row in
                Text("Process \(row.id): \(row.value)")
                    .frame(maxWidth: .infinity, minHeight: 22)
            }
        }
    }
}
