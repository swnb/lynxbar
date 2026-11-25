import XCTest
@testable import LynxBar

final class SessionActionLedgerTests: XCTestCase {
    func testLedgerRetainsExactCurrentSessionTruthButNewInstanceIsEmpty()
        async {
        let planID = UUID()
        let result = DiskCleanupItemResult(
            candidateID: UUID(),
            displayName: "recoverable.bin",
            status: .staged,
            stagedBytes: 2_000_000_000,
            trashURL: URL(
                fileURLWithPath: "/Users/test/.Trash/recoverable.bin"
            ),
            errorCategory: nil
        )
        let currentSession = SessionActionLedger()
        await currentSession.append(result, planID: planID)

        let currentEntries = await currentSession.entries(for: planID)
        XCTAssertEqual(currentEntries, [result])

        let restartedSession = SessionActionLedger()
        let restartedEntries = await restartedSession.entries(for: planID)
        XCTAssertEqual(restartedEntries, [])
    }
}
