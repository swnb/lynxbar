import XCTest
@testable import LynxBar

final class DiskCleanupPolicyTests: XCTestCase {
    func testPathComponentsRejectStringPrefixCollision() {
        let root = TestDiskFactory.root()
        let outside = DiskFileObservation(
            sourceURL: URL(
                fileURLWithPath: "/Users/test/Downloads-old/file.bin"
            ),
            canonicalURL: URL(
                fileURLWithPath: "/Users/test/Downloads-old/file.bin"
            ),
            kind: .regularFile,
            fingerprint: TestDiskFactory.fingerprint(
                inode: 20,
                bytes: 2_000_000_000
            ),
            allocatedBytes: 2_000_000_000,
            isHidden: false,
            isLocal: true,
            isUbiquitous: false,
            isDownloaded: true,
            isReadable: true
        )

        let result = DiskCleanupPolicyEvaluator.evaluate(
            outside,
            root: root,
            policy: .v1,
            now: TestDiskFactory.now
        )

        XCTAssertEqual(result.failure, .outsideRoot)
    }

    func testPolicyRejectsHiddenCloudSymlinkAndHardLinkedEntries() {
        let root = TestDiskFactory.root()
        let fixtures: [(DiskFileObservation, DiskExclusionReason)] = [
            (
                TestDiskFactory.observation(
                    root: root,
                    name: ".hidden.bin",
                    inode: 21,
                    bytes: 2_000_000_000,
                    isHidden: true
                ),
                .hidden
            ),
            (
                TestDiskFactory.observation(
                    root: root,
                    name: "cloud.bin",
                    inode: 22,
                    bytes: 2_000_000_000,
                    isUbiquitous: true,
                    isDownloaded: false
                ),
                .cloudPlaceholder
            ),
            (
                TestDiskFactory.observation(
                    root: root,
                    name: "link",
                    inode: 23,
                    bytes: 2_000_000_000,
                    kind: .symbolicLink
                ),
                .symbolicLink
            ),
            (
                TestDiskFactory.observation(
                    root: root,
                    name: "shared.bin",
                    inode: 24,
                    bytes: 2_000_000_000,
                    links: 2
                ),
                .hardLinked
            ),
        ]

        for (observation, expected) in fixtures {
            let result = DiskCleanupPolicyEvaluator.evaluate(
                observation,
                root: root,
                policy: .v1,
                now: TestDiskFactory.now
            )
            XCTAssertEqual(result.failure, expected)
        }
    }

    func testPolicyClassifiesUnsupportedAndUnreadableEntryKinds() {
        let root = TestDiskFactory.root()
        let fixtures: [(DiskFileObservation, DiskExclusionReason)] = [
            (
                TestDiskFactory.observation(
                    root: root,
                    name: "folder",
                    inode: 40,
                    bytes: 0,
                    kind: .directory
                ),
                .directory
            ),
            (
                TestDiskFactory.observation(
                    root: root,
                    name: "archive.bundle",
                    inode: 41,
                    bytes: 2_000_000_000,
                    kind: .package
                ),
                .package
            ),
            (
                TestDiskFactory.observation(
                    root: root,
                    name: "Tool.app",
                    inode: 42,
                    bytes: 2_000_000_000,
                    kind: .application
                ),
                .application
            ),
            (
                TestDiskFactory.observation(
                    root: root,
                    name: "pipe",
                    inode: 43,
                    bytes: 2_000_000_000,
                    kind: .other
                ),
                .notRegular
            ),
            (
                TestDiskFactory.observation(
                    root: root,
                    name: "denied.bin",
                    inode: 44,
                    bytes: 2_000_000_000,
                    isReadable: false
                ),
                .inaccessible
            ),
            (
                TestDiskFactory.observation(
                    root: root,
                    name: "remote.bin",
                    inode: 45,
                    bytes: 2_000_000_000,
                    isLocal: false
                ),
                .nonLocal
            ),
        ]

        for (observation, expected) in fixtures {
            XCTAssertEqual(
                DiskCleanupPolicyEvaluator.evaluate(
                    observation,
                    root: root,
                    policy: .v1,
                    now: TestDiskFactory.now
                ).failure,
                expected
            )
        }
    }

    func testLogicalSizeIsAnExplicitFallbackEstimate() throws {
        let root = TestDiskFactory.root()
        let logicalBytes: UInt64 = 2_000_000_000
        let observed = TestDiskFactory.observation(
            root: root,
            name: "logical-only.bin",
            inode: 46,
            bytes: logicalBytes
        )
        let observation = DiskFileObservation(
            sourceURL: observed.sourceURL,
            canonicalURL: observed.canonicalURL,
            kind: observed.kind,
            fingerprint: observed.fingerprint,
            allocatedBytes: nil,
            isHidden: observed.isHidden,
            isLocal: observed.isLocal,
            isUbiquitous: observed.isUbiquitous,
            isDownloaded: observed.isDownloaded,
            isReadable: observed.isReadable
        )
        let candidate = try XCTUnwrap(
            DiskCleanupPolicyEvaluator.evaluate(
                observation,
                root: root,
                policy: .v1,
                now: TestDiskFactory.now
            ).success
        )

        XCTAssertEqual(candidate.logicalBytes, logicalBytes)
        XCTAssertEqual(candidate.allocatedBytesEstimate, logicalBytes)
    }

    func testLargeAndOldLargeRulesRemainExplainable() {
        let root = TestDiskFactory.root()
        let large = TestDiskFactory.observation(
            root: root,
            name: "large.bin",
            inode: 30,
            bytes: DiskScanPolicy.v1.largeFileBytes
        )
        let old = TestDiskFactory.observation(
            root: root,
            name: "old.bin",
            inode: 31,
            bytes: DiskScanPolicy.v1.oldFileMinimumBytes,
            ageDays: 100
        )
        let small = TestDiskFactory.observation(
            root: root,
            name: "small.bin",
            inode: 32,
            bytes: 1_000,
            ageDays: 1_000
        )

        XCTAssertEqual(
            DiskCleanupPolicyEvaluator.evaluate(
                large,
                root: root,
                policy: .v1,
                now: TestDiskFactory.now
            ).success?.rule,
            .large
        )
        XCTAssertEqual(
            DiskCleanupPolicyEvaluator.evaluate(
                old,
                root: root,
                policy: .v1,
                now: TestDiskFactory.now
            ).success?.rule,
            .oldAndLarge
        )
        XCTAssertEqual(
            DiskCleanupPolicyEvaluator.evaluate(
                small,
                root: root,
                policy: .v1,
                now: TestDiskFactory.now
            ).failure,
            .belowThreshold
        )
    }

    func testLiveRootPolicyAllowsNarrowHomeDescendantButRejectsBroadRoots()
        async throws {
        let manager = FileManager()
        let fixture = manager.temporaryDirectory.appendingPathComponent(
            "lynxbar-cleanup-root-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = fixture.appendingPathComponent("home", isDirectory: true)
        let downloads = home.appendingPathComponent(
            "Downloads",
            isDirectory: true
        )
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let outside = fixture.appendingPathComponent(
            "another-user",
            isDirectory: true
        )
        let externalRoot = fixture.appendingPathComponent(
            "External",
            isDirectory: true
        )
        let externalFolder = externalRoot.appendingPathComponent(
            "Exports",
            isDirectory: true
        )
        let rootLink = fixture.appendingPathComponent(
            "downloads-link",
            isDirectory: true
        )
        try manager.createDirectory(
            at: downloads,
            withIntermediateDirectories: true
        )
        try manager.createDirectory(
            at: library,
            withIntermediateDirectories: true
        )
        try manager.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        try manager.createDirectory(
            at: externalFolder,
            withIntermediateDirectories: true
        )
        try manager.createSymbolicLink(
            at: rootLink,
            withDestinationURL: downloads
        )
        defer { try? manager.removeItem(at: fixture) }
        let reader = LocalDiskReadAdapter(homeURL: home)

        _ = try await reader.validateRoot(DiskScanRequest(rootURL: downloads))
        await assertRootRejected(reader, url: home, reason: .homeRoot)
        await assertRootRejected(reader, url: library, reason: .userLibrary)
        await assertRootRejected(
            reader,
            url: URL(fileURLWithPath: "/"),
            reason: .volumeRoot
        )
        await assertRootRejected(
            reader,
            url: outside,
            reason: .outsideAllowedScope
        )
        await assertRootRejected(
            reader,
            url: rootLink,
            reason: .symbolicLink
        )

        let externalReader = LocalDiskReadAdapter(
            homeURL: home,
            mountedVolumeRoots: [
                URL(fileURLWithPath: "/"),
                externalRoot,
            ]
        )
        _ = try await externalReader.validateRoot(
            DiskScanRequest(rootURL: externalFolder)
        )
        await assertRootRejected(
            externalReader,
            url: externalRoot,
            reason: .volumeRoot
        )
    }

    func testCapacityDeltaSaturatesWithoutProducingInt64Min() {
        let verification = DiskCapacityVerification(
            beforeBytes: UInt64.max,
            afterBytes: 0
        )

        XCTAssertEqual(verification.observedDelta, -Int64.max)
        if let delta = verification.observedDelta {
            XCTAssertEqual(abs(delta), Int64.max)
        } else {
            XCTFail("Expected a saturated delta")
        }
    }

    private func assertRootRejected(
        _ reader: LocalDiskReadAdapter,
        url: URL,
        reason: DiskRootRejectionReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await reader.validateRoot(DiskScanRequest(rootURL: url))
            XCTFail("Expected root rejection", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? DiskCleanupError,
                .unsafeRoot(reason),
                file: file,
                line: line
            )
        }
    }
}

private extension Result {
    var success: Success? {
        guard case .success(let value) = self else { return nil }
        return value
    }

    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
