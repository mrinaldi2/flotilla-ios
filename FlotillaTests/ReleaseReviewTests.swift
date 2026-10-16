import XCTest
@testable import Flotilla

/// H-160 AC4: the owner rules a release on the phone with the desktop's
/// verdicts and words (UX-023 screen 2, UX-008).
final class ReleaseReviewTests: XCTestCase {
    private let release = Release([
        "id": "r1", "name": "desktop-0.17.0", "display_version": "0.17.0", "status": "awaiting_owner", "version": 4,
        "can_rule": true, "created_by": "devops",
        "items": [["item_id": "H-117", "verdict": "pending"], ["item_id": "H-081", "verdict": "pending"],
                  ["item_id": "H-102", "verdict": "pending"]],
        "plan": [],
    ])

    func testApprovalShipsWhatIsntLeftOut() {
        let verdicts = ReleaseReview.approval(release, leftOut: ["H-102": LeftOut(verdict: .rework, note: "font on win-pc"),
                                                               "H-081": LeftOut(verdict: .hold, note: "")])
        XCTAssertEqual(verdicts.map { $0.str("verdict") }, ["ship", "hold", "rework"])
        XCTAssertEqual(verdicts[2].str("note"), "font on win-pc")
        XCTAssertNil(verdicts[1]["note"], "an empty note isn't sent")
        XCTAssertEqual(release.revision, 4, "sent back as expected_version")
    }

    func testRejectionCarriesTheReasonAndWhereEachGoes() {
        let verdicts = ReleaseReview.rejection(release, reason: "Crashes on launch", returns: ["H-081": .hold])
        XCTAssertEqual(verdicts.map { $0.str("verdict") }, ["rework", "hold", "rework"])
        XCTAssertTrue(verdicts.allSatisfy { $0.str("note") == "Crashes on launch" })
        XCTAssertFalse(verdicts.contains { $0.str("verdict") == "ship" })
        XCTAssertNil(ReleaseReview.rejectHint(["H-117": .rework, "H-081": .hold, "H-102": .hold], items: 3))
        XCTAssertEqual(ReleaseReview.rejectHint(["H-117": .hold, "H-081": .hold, "H-102": .hold], items: 3),
                       "With every item back to Ready, the package is held rather than rejected.")
    }

    func testTheWordsFollowTheDesktop() {
        XCTAssertEqual(ReleaseReview.approveButton(release, leftOut: 1), "Approve 2 of 3 items")
        XCTAssertEqual(ReleaseReview.approveButton(release, leftOut: 0), "Approve 0.17.0")
        XCTAssertEqual(ReleaseReview.approveQuestion(release, leftOut: 1), "Approve 2 of 3 items?")
        XCTAssertEqual(ReleaseReview.approving(release, leftOut: 1), "Approving 2 of 3 items of 0.17.0")
        XCTAssertEqual(ReleaseReview.approving(release, leftOut: 0), "Approving 0.17.0")
        XCTAssertEqual(ReleaseReview.leftOutLine(1), "1 item left out · DevOps repackages the rest")
        XCTAssertNil(ReleaseReview.leftOutLine(0))
        XCTAssertEqual(ReleaseReview.outWords(LeftOut(verdict: .rework, note: "font on win-pc")), "Left out · back to Doing: “font on win-pc”")
        XCTAssertEqual(ReleaseReview.outWords(LeftOut(verdict: .hold, note: "")), "Left out · waits for the next package")
        XCTAssertEqual(ReleaseReview.approveBody(release, leftOut: 0), "DevOps rolls 0.17.0 out to each computer, one at a time, starting now.")
        XCTAssertTrue(ReleaseReview.approveBody(release, leftOut: 1).hasPrefix("DevOps repackages the 2 approved items without the rest"))
    }

    func testWhoMayRule() {
        XCTAssertNil(ReleaseReview.cannotRule(release, canApprove: true))
        XCTAssertEqual(ReleaseReview.cannotRule(release, canApprove: false),
                       "This device can't rule on releases: it doesn't have approve access.")
        let elsewhere = Release(["id": "r", "name": "x", "status": "awaiting_owner", "can_rule": false, "rule_on": "Studio Mac"])
        XCTAssertEqual(ReleaseReview.cannotRule(elsewhere, canApprove: true),
                       "You can approve, hold or reject this package only from a device connected directly to Studio Mac.")
    }

    func testFaceIDRefusalsSayWhatDidntHappen() {
        XCTAssertEqual(OwnerAuth.Failure.cancelled(.approve).localizedDescription, "Not approved. Nothing was sent.")
        XCTAssertEqual(OwnerAuth.Failure.cancelled(.reject).localizedDescription, "Not rejected. Nothing was sent.")
    }

    func testHoldReminders() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(ReleaseReview.Remind.never.date(from: now))
        XCTAssertEqual(ReleaseReview.Remind.tomorrow.date(from: now)?.timeIntervalSince(now), 86_400)
        XCTAssertEqual(ReleaseReview.Remind.allCases.map(\.rawValue), ["Don't remind me", "Tomorrow", "In 3 days", "Next week"])
    }
}
