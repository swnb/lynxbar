import XCTest
@testable import LynxBar

/// Task C.2：落盘格式改为 binary plist、写入节流 30s → 300s、init 不再同步
/// 读盘（改为显式 `load()`）、新增 history-v2.json → history-v3.plist 的
/// 一次性迁移。这里覆盖这几条行为，而不是重复 `MetricHistoryTests.swift`
/// 已经覆盖的归档聚合/裁剪逻辑。
final class MetricHistoryPersistenceTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("history-test.plist")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        super.tearDown()
    }

    /// 如果 init 恢复成同步读盘（旧 bug），construction 之后立即查询就会
    /// 已经带上磁盘上原有的数据，第一个断言会红；如果 load() 没有真正解码
    /// 磁盘内容，第二个断言会红。目录里预先放一份非空归档，是因为如果
    /// 目标文件从一开始就不存在，两个断言无论 init 有没有读盘都会通过，
    /// 测不出问题。
    func testInitDoesNotTouchDiskAndLoadIsExplicit() async throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var seeded = MetricHistoryArchive()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        seeded.record(.cpuUsage, value: 0.5, at: timestamp)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(seeded).write(to: fileURL)

        let store = MetricHistoryStore(fileURL: fileURL)
        let before = await store.query(.cpuUsage, range: .hour, now: timestamp)
        XCTAssertTrue(
            before.points.isEmpty,
            "init 不能同步读盘：磁盘上已有的数据不该在 load() 之前就出现在查询结果里"
        )

        await store.load()
        let after = await store.query(.cpuUsage, range: .hour, now: timestamp)
        XCTAssertEqual(after.points.map(\.value), [0.5], "load() 之后必须能读到磁盘上原有的数据")
    }

    /// 如果 flush() 没有真正落盘（比如编码器调用错了、isDirty 没置位、写入
    /// 静默失败），或者 load() 没能正确解码 binary plist，第二个 store 读到
    /// 的历史就会是空的或者数值不对，两个断言都会红。
    func testRoundTripPreservesArchiveAcrossStores() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let writer = MetricHistoryStore(fileURL: fileURL)
        await writer.load()
        for index in 0..<120 {
            await writer.record(
                .cpuUsage,
                value: 0.5,
                at: timestamp.addingTimeInterval(Double(index) * 15)
            )
        }
        try await writer.flush()

        let reader = MetricHistoryStore(fileURL: fileURL)
        await reader.load()
        let result = await reader.query(
            .cpuUsage,
            range: .hour,
            now: timestamp.addingTimeInterval(1_800)
        )
        XCTAssertFalse(result.points.isEmpty, "落盘后重新加载必须能读回聚合数据")
        XCTAssertTrue(
            result.points.allSatisfy { $0.value == 0.5 },
            "读回的聚合值不应该被破坏"
        )
    }

    /// 如果 persistIfNeeded() 还在用 JSONEncoder（没换成
    /// PropertyListEncoder + .binary），写出来的文件会以 "{" 开头而不是
    /// binary plist 的 "bplist" 魔数，断言会红。
    func testPersistedFileIsBinaryPropertyListNotJSON() async throws {
        let store = MetricHistoryStore(fileURL: fileURL)
        await store.load()
        await store.record(.cpuUsage, value: 0.5, at: Date())
        try await store.flush()

        let data = try Data(contentsOf: fileURL)
        XCTAssertEqual(data.prefix(6), Data("bplist".utf8))
    }

    /// 如果无法解析的文件被静默清零（没有改名保留），备份文件不存在，
    /// 第一个断言会红；如果实现是"复制"而不是"改名/移动"，原路径上会
    /// 残留一份，第二个断言会红；如果实现在改名的同时篡改了内容（例如
    /// 先删除再新建一个空文件当"备份"），第三个断言会红。
    func testCorruptFileIsPreservedAsBackupInsteadOfSilentlyDiscarded() async throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let corruptContent = Data("not a plist".utf8)
        try corruptContent.write(to: fileURL)

        let store = MetricHistoryStore(fileURL: fileURL)
        await store.load()

        let backup = fileURL.appendingPathExtension("corrupt")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: backup.path),
            "无法解析的历史文件必须留一份备份，不能静默丢弃"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileURL.path),
            "备份必须是改名/移动，原路径不该再残留一份"
        )
        XCTAssertEqual(
            try Data(contentsOf: backup), corruptContent,
            "备份的应该是原始内容，不是重新生成的占位文件"
        )
    }

    func testWriteDebounceIsFiveMinutes() {
        XCTAssertEqual(SamplingPolicy.historyWriteDebounce, .seconds(300))
    }

    /// 覆盖格式迁移路径：history-v2.json（旧格式）→ load() → history-v3.plist
    /// （新格式）。如果 load() 压根没有迁移分支，数据读不回来，第一个断言
    /// 会红；如果迁移读到了旧数据但没有落盘到新路径，第二/第三个断言会红；
    /// 如果旧文件被直接删除而不是改名保留，第四个断言会红（"已消失" 满足，
    /// 但第五个断言——`.migrated` 备份存在——会红，区分出"删除"和"改名"）。
    func testLegacyJSONArchiveIsMigratedToNewPlistAndOldFileIsRenamed() async throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacyURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("history-v2.json", isDirectory: false)
        var legacyArchive = MetricHistoryArchive()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        legacyArchive.record(.cpuUsage, value: 0.42, at: timestamp)
        try JSONEncoder().encode(legacyArchive).write(to: legacyURL)

        let store = MetricHistoryStore(fileURL: fileURL)
        await store.load()

        let result = await store.query(.cpuUsage, range: .hour, now: timestamp)
        XCTAssertEqual(result.points.map(\.value), [0.42], "迁移后数据必须完整读回")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fileURL.path),
            "迁移必须把数据落盘到新的 plist 路径"
        )
        let newData = try Data(contentsOf: fileURL)
        XCTAssertEqual(
            newData.prefix(6), Data("bplist".utf8),
            "迁移写出的新文件也必须是 binary plist，不是照抄旧格式"
        )
        // 上面的 query 读的是第一个 store 自己内存里的状态，即使 persistIfNeeded()
        // 把错误的内容写到了磁盘上也测不出来；这里独立解码磁盘上的字节，
        // 证明真正落盘的内容也是完整的迁移结果，不是巧合地内存对、磁盘错。
        let onDiskArchive = try PropertyListDecoder().decode(MetricHistoryArchive.self, from: newData)
        XCTAssertEqual(
            onDiskArchive.query(.cpuUsage, range: .hour, now: timestamp).points.map(\.value),
            [0.42],
            "磁盘上落盘的内容本身必须是完整迁移结果，不能只是内存状态碰巧正确"
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyURL.path),
            "旧文件不应该继续留在原路径"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: legacyURL.appendingPathExtension("migrated").path
            ),
            "旧文件必须是改名保留，不能直接删除"
        )
    }

    /// isLoaded 是迁移"只做一次"的保证机制。如果这道门槛被去掉，第二次
    /// load() 会重新尝试解析磁盘内容——这里磁盘上放的是解析不了的垃圾数据，
    /// 一旦重新解析就会触发 preserveUnreadableFile 把内存里刚 record() 但
    /// 还没 flush 的数据清空，断言就会红。
    func testSecondLoadCallIsNoOpAndDoesNotClobberInMemoryState() async throws {
        let store = MetricHistoryStore(fileURL: fileURL)
        await store.load() // 此时目录/文件都不存在，归档从空开始

        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        await store.record(.cpuUsage, value: 0.9, at: timestamp)
        // 故意不 flush：模拟这条记录只存在于内存、还没落盘的场景。

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("garbage".utf8).write(to: fileURL)

        await store.load()

        let result = await store.query(.cpuUsage, range: .hour, now: timestamp)
        XCTAssertEqual(
            result.points.map(\.value), [0.9],
            "load() 只应在首次调用时生效；重复调用不能用磁盘内容覆盖已经在内存里的状态"
        )
    }

    /// LynxBarTests 是 hosted unit test，`xcodebuild test` 会拉起真实的
    /// LynxBar.app 作为宿主进程。`AppDelegate.isRunningUnderXCTest` 就是用来
    /// 让 applicationDidFinishLaunching 在这种场景下跳过历史加载/迁移的
    /// 判定——不跳过的话，每次跑单测都会对用户真实的
    /// `~/Library/Application Support/LynxBar/` 做一次迁移/落盘。放在这个
    /// 文件而不是新建 AppDelegate 专属测试文件，是因为它保护的正是这份
    /// persistence 测试套件本身的数据安全边界。
    ///
    /// 如果实现坏了为什么会红：这个测试方法本身就是在真实的 XCTest 宿主
    /// 进程里执行的，`isRunningUnderXCTest` 在这里必须为 true。如果判定
    /// 用错了环境变量名、把 `!= nil` 误写成基于 `.isEmpty` 的判断（实测过
    /// 这个 key 的值是空字符串，不是 nil，所以 `.isEmpty` 会误判)、或者
    /// 判断方向被反转，这里都会读到 false，断言变红。
    ///
    /// 这个测试测不出的：把 `isRunningUnderXCTest` 硬编码成 `true` 也能让
    /// 这条断言通过，但那个方向的错误后果是"生产环境里也跳过历史加载"——
    /// 用户会立刻观察到历史图表永远是空的，是一个大到不可能被忽视的
    /// 显性 bug，不需要靠这条测试来兜底；这条测试专门锁住的是相反的、
    /// 危险得多的方向（测试环境里误判成生产环境，从而悄悄改用户数据）。
    @MainActor
    func testXCTestHostDetectionIsTrueWhileActuallyRunningUnderXCTest() {
        XCTAssertTrue(
            AppDelegate.isRunningUnderXCTest,
            "本方法就是在 XCTest 宿主进程里跑的，判定必须为 true；" +
            "为 false 意味着每次跑测试都会真的迁移/落盘用户的真实历史文件"
        )
    }
}
