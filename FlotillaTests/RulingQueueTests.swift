import XCTest
@testable import Flotilla

/// UX-040 / CE on H-160 AC4: an approval waits out its Undo app-wide, then
/// reports what happened; a version conflict says the package changed.
@MainActor
final class RulingQueueTests: XCTestCase {
    private let release = Release(["id": "r1", "name": "x", "display_version": "0.17.0", "status": "awaiting_owner",
                                   "version": 4, "items": [["item_id": "A"], ["item_id": "B"], ["item_id": "C"]]])

    private func settle(_ queue: RulingQueue) async {
        for _ in 0..<100 where queue.outcome == nil { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testItSendsAfterTheWaitAndSaysSo() async {
        let queue = RulingQueue()
        var sent = 0
        queue.approve(release, leftOut: 1, wait: .milliseconds(50)) { sent += 1; return self.release }
        XCTAssertEqual(queue.pending?.label, "Approving 2 of 3 items of 0.17.0", "the bar shows while Undo is possible")
        await settle(queue)
        XCTAssertEqual(sent, 1)
        XCTAssertNil(queue.pending)
        XCTAssertEqual(queue.outcome?.text, "2 of 3 items of 0.17.0 approved. DevOps repackages them next.")
        XCTAssertEqual(queue.outcome?.ok, true)
    }

    func testUndoSendsNothing() async {
        let queue = RulingQueue()
        var sent = 0
        queue.approve(release, leftOut: 0, wait: .milliseconds(80)) { sent += 1; return self.release }
        queue.undo()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(sent, 0)
        XCTAssertNil(queue.pending)
        XCTAssertEqual(queue.outcome?.text, "Undone. Nothing was sent.")
    }

    func testUndoKeepsTheLeaveOutChoices() async {
        // H-225 (QA-008 D3): only a ruling that went, or a changed package, spends them.
        let queue = RulingQueue()
        queue.approve(release, leftOut: 1, wait: .milliseconds(80)) { self.release }
        queue.undo()
        XCTAssertEqual(queue.outcome?.undone, true)
        XCTAssertEqual(queue.outcome?.clearsChoices, false, "Undo keeps what was left out")

        queue.approve(release, leftOut: 1, wait: .milliseconds(10)) { self.release }
        await settle(queue)
        XCTAssertEqual(queue.outcome?.clearsChoices, true, "approved: the choices are spent")
    }

    func testAVersionConflictSaysThePackageChanged() async {
        let queue = RulingQueue()
        queue.approve(release, leftOut: 0, wait: .milliseconds(10)) {
            throw DaemonError(code: "conflict", message: "the package changed since you reviewed it")
        }
        await settle(queue)
        XCTAssertEqual(queue.outcome?.changed, true)
        XCTAssertEqual(queue.outcome?.ok, false)
        XCTAssertEqual(queue.outcome?.text, "0.17.0 changed while you were reviewing it. Nothing was sent. Check it again, then rule.")
    }

    func testAnotherRefusalKeepsItsReason() async {
        let queue = RulingQueue()
        queue.approve(release, leftOut: 0, wait: .milliseconds(10)) {
            throw DaemonError(code: "forbidden", message: "rule on it in the release review")
        }
        await settle(queue)
        XCTAssertEqual(queue.outcome?.changed, false)
        XCTAssertEqual(queue.outcome?.text, "Couldn't approve 0.17.0: rule on it in the release review")
    }

    func testAWholeApprovalSaysTheRolloutIsNext() async {
        let queue = RulingQueue()
        queue.approve(release, leftOut: 0, wait: .milliseconds(10)) { self.release }
        await settle(queue)
        XCTAssertEqual(queue.outcome?.text, "0.17.0 approved. DevOps rolls it out next.")
        XCTAssertEqual(OwnerAuth.Failure.cancelled(.approve).localizedDescription, "Not approved. Nothing was sent.",
                       "a cancelled Face ID keeps its own words")
    }

    func testConflictDetection() {
        XCTAssertTrue(RulingWords.isConflict(DaemonError(code: "conflict", message: "x")))
        XCTAssertTrue(RulingWords.isConflict(DaemonError(code: "invalid", message: "expected_version 3 is stale")))
        XCTAssertFalse(RulingWords.isConflict(DaemonError(code: "forbidden", message: "no approve grant")))
    }

    func testTheFallbackNamesTheComputerThatKeepsTheBoard() {
        let unnamed = Release(["id": "r", "name": "x", "status": "awaiting_owner", "can_rule": false])
        XCTAssertEqual(ReleaseReview.cannotRule(unnamed, canApprove: true),
                       "You can approve, hold or reject this package only from a device connected directly to the computer that keeps this board.")
    }
}
