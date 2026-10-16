import XCTest
@testable import Flotilla

/// H-200: a release's items show their real state, as the desktop Releases
/// tab does, never the raw "pending" verdict. Fixtures are real releases
/// from desktop 0.17.3's board (Fixtures/releases).
final class ReleaseStateTests: XCTestCase {
    private func release(_ name: String) throws -> Release {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"), "\(name).json in the test bundle")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? JSONDict)
        return Release(json)
    }

    private let names = ["fbd9be47-cd55-487d-bdbe-7f5176a0bee4": "Team Lead", "6f22b3da-1a3e-4766-ad8a-3ad6db00e43d": "Desktop Dev"]
    private func states(_ release: Release) -> [String: Release.ItemState] {
        Dictionary(uniqueKeysWithValues: release.items.map { ($0.itemId, release.state(of: $0) { self.names[$0] }) })
    }

    func testAPlannedReleaseShowsEachItemsLiveState() throws {
        let planned = try release("planned-0.17.4")
        XCTAssertTrue(planned.showsProgress)
        let rows = states(planned)
        XCTAssertEqual(rows["H-155"]?.pill, "○ Still in progress")
        XCTAssertEqual(rows["H-155"]?.meta, "Inbox · Unassigned · ☑ 0/3 AC")
        XCTAssertEqual(rows["H-174"]?.pill, "✓ Ready for the release")
        XCTAssertEqual(rows["H-174"]?.tone, .ready)
        XCTAssertEqual(rows["H-174"]?.meta, "Verify · Desktop Dev · ☑ 1/1 AC")
        XCTAssertTrue(rows["H-174"]?.title.hasPrefix("H-174 · VR story") ?? false)
        XCTAssertEqual(planned.readinessLine, "7 of 14 items ready · Not built yet · Tested on 0 of 3 computers")
        XCTAssertFalse(rows.values.contains { $0.pill?.lowercased().contains("pending") ?? false })
    }

    func testASubmittedReleaseWaitsForTheOwner() throws {
        let submitted = try release("submitted-ios-0.5.0")
        XCTAssertFalse(submitted.showsProgress, "submitted: the ruling, not the progress")
        for row in states(submitted).values {
            XCTAssertEqual(row.pill, "✓ Included", "it ships unless left out, as desktop (UX-036)")
            XCTAssertEqual(row.tone, .ready)
            XCTAssertTrue(row.meta?.hasPrefix("Awaiting owner") ?? false)
        }
    }

    func testADeployedReleaseShowsItsItemsIncludedAndDone() throws {
        let deployed = try release("deployed-0.17.3")
        XCTAssertEqual(deployed.status, "deployed")
        let rows = states(deployed)
        XCTAssertEqual(rows["H-167"]?.pill, "✓ Included")
        XCTAssertEqual(rows["H-167"]?.tone, .ready)
        XCTAssertEqual(rows["H-167"]?.meta, "Done · Team Lead · ☑ 3/3 AC")
        XCTAssertEqual(rows["H-189"]?.pill, "✓ Included")
        XCTAssertEqual(deployed.statusWords.0, "0.17.3 live")
    }

    func testAnApprovedReleaseShowsItsRulings() throws {
        let approved = try release("approved-ios-0.5.0")
        XCTAssertEqual(Set(states(approved).values.map(\.pill)), ["✓ Included"])
    }

    func testLeftOutItemsSayWhereTheyWent() {
        let release = Release([
            "id": "r", "name": "x", "status": "repackaging",
            "items": [["item_id": "A", "verdict": "hold", "owner_note": NSNull()],
                      ["item_id": "B", "verdict": "rework", "owner_note": "Crashes on launch"]],
            "plan": [],
        ])
        let rows = Dictionary(uniqueKeysWithValues: release.items.map { ($0.itemId, release.state(of: $0) { _ in nil }) })
        XCTAssertEqual(rows["A"]?.pill, "⤼ Left out · waits for the next package")
        XCTAssertEqual(rows["B"]?.pill, "⤼ Left out · back to Doing")
        XCTAssertEqual(rows["B"]?.meta, "“Crashes on launch”")
    }

    func testAnUnruledItemOutsideReviewSaysNothing() {
        let release = Release(["id": "r", "name": "x", "status": "held",
                               "items": [["item_id": "A", "verdict": "pending"]], "plan": []])
        let row = release.state(of: release.items[0]) { _ in nil }
        XCTAssertNil(row.pill, "no raw “pending”")
        XCTAssertEqual(row.title, "A")
    }
}
