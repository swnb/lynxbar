import XCTest

/// 固定 pt 字号回归锁：`Sources/LynxBar` 下不得再出现 `Font.system(size:...)` 这种不随
/// Dynamic Type 缩放的写法，一律改用 `Theme.Font` 语义字阶（内部基于
/// `SwiftUI.Font.system(.textStyle, design:)`）。
///
/// 相比 task-E.2-brief 原稿的实现，这里做了两处健壮性加固，都是本任务实测踩到的坑，
/// 不是假设性的自我加戏：
///
/// 1. **前置断言防止假绿**：`#filePath` 推出的仓库根路径如果算错，
///    `FileManager.default.enumerator(at:)` 会枚举到一个空目录或不存在的目录，
///    此时 `offenders` 天然是空数组，测试会"通过"——但通过的原因是压根没扫到任何
///    文件，不是真的没有违规。加两条前置断言：扫到的 `.swift` 文件数量落在合理量级
///    （当前仓库 65 个，留了增长空间但不能是个位数），且 `Kit/Theme.swift` 确实存在于
///    推出的路径下。任何一条不满足，测试自己先失败，不会把路径错误伪装成"零违规"。
/// 2. **多行 `.font(.system(` 调用**：brief 原稿按"每行 `contains(".system(size:")`"
///    逐行扫描。实测本次改造中 Battery/GPU/DiskCleanup 三个文件各有一处
///    `.font(.system(\n    size: ...\n))` 跨行写法（三元表达式塞进 size 参数换行对齐），
///    `.system(` 和 `size:` 分属两行，逐行子串匹配完全扫不到——这不是假设，是这次实测
///    真实漏掉过的 3 处。改成对整份文件内容做正则匹配（`\.system\(\s*size\s*:`，
///    `\s` 天然吃掉换行），再用匹配位置反推行号，单行/多行写法一视同仁。
final class TypographyTests: XCTestCase {
    private static let expectedMinimumSwiftFileCount = 50

    private static let offenderPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "\\.system\\(\\s*size\\s*:", options: [])
    }()

    func testNoFixedPointSizesRemainInViews() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LynxBarTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("Sources/LynxBar")

        // 前置断言 1：路径本身必须存在，且必须是目录——不存在时下面的 enumerator
        // 会直接枚举出空结果，如果没有这条断言，路径推错和"零违规"是无法区分的。
        var isDirectory: ObjCBool = false
        let rootExists = FileManager.default.fileExists(
            atPath: sourceRoot.path,
            isDirectory: &isDirectory
        )
        XCTAssertTrue(
            rootExists && isDirectory.boolValue,
            "#filePath 推出的 Sources/LynxBar 路径不存在或不是目录：\(sourceRoot.path)——" +
                "说明 #filePath 在当前构建环境下解析异常，需要检查是否有路径重写"
                + "（如 -file-prefix-map）或仓库结构是否变化。"
        )

        // 前置断言 2：路径下必须能找到一个已知文件，进一步确认枚举到的是真仓库而不是
        // 恰好同名的空目录。
        let knownFile = sourceRoot.appendingPathComponent("Kit/Theme.swift")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: knownFile.path),
            "推出的 Sources/LynxBar 下找不到 Kit/Theme.swift，说明推出的路径不是真正的仓库源码根：" +
                "\(sourceRoot.path)"
        )

        var offenders: [String] = []
        var swiftFileCount = 0
        let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            swiftFileCount += 1
            let contents = try String(contentsOf: url, encoding: .utf8)
            let nsContents = contents as NSString
            let fullRange = NSRange(location: 0, length: nsContents.length)
            Self.offenderPattern.enumerateMatches(
                in: contents,
                options: [],
                range: fullRange
            ) { match, _, _ in
                guard let match else { return }
                let prefix = nsContents.substring(to: match.range.location)
                let lineNumber = prefix.reduce(into: 1) { count, character in
                    if character == "\n" { count += 1 }
                }
                offenders.append("\(url.lastPathComponent):\(lineNumber)")
            }
        }

        // 前置断言 3：真正扫到了有意义数量的源文件——否则上面两条断言都可能因为
        // 巧合（比如根目录下恰好也放了一份 Kit/Theme.swift）而通过，但 enumerator
        // 实际遍历的是别的、内容稀少的目录，导致下面 offenders.isEmpty 是假绿。
        XCTAssertGreaterThanOrEqual(
            swiftFileCount,
            Self.expectedMinimumSwiftFileCount,
            "只扫到 \(swiftFileCount) 个 .swift 文件，远低于预期量级" +
                "（当前仓库 Sources/LynxBar 下有 65 个）。扫描范围可能不对，" +
                "此时下面「零违规」的结论不可信。"
        )

        XCTAssertTrue(
            offenders.isEmpty,
            "固定 pt 字号不随系统文本大小缩放，请改用 Theme.Font：\n" + offenders.joined(separator: "\n")
        )
    }
}
