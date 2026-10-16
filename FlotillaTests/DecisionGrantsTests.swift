import XCTest
@testable import Flotilla

/// H-118: an option that grants permission extras shows them, and a ruling
/// on it echoes the sha of the grants shown (H-117, ARCH-R51 M2).
final class DecisionGrantsTests: XCTestCase {
    private func decision(ruling: String? = nil) -> Decision {
        var d: JSONDict = [
            "id": "d1", "project_id": "p1", "kind": "choice", "title": "Ship 0.17?", "body": "",
            "state": ruling == nil ? "open" : "answered", "priority": "normal",
            "options": [
                ["key": "ship", "label": "Ship", "description": "",
                 "grants": [["bot": "b-devops", "extra": "install"], ["bot": "b-devops", "extra": "daemon_restart"],
                            ["bot": "b-tester", "extra": "install"]],
                 "grants_sha": "abc123"],
                ["key": "hold", "label": "Hold", "description": NSNull()],
            ],
        ]
        if let ruling { d["ruling"] = ["option": ruling, "text": "Ship", "answered_by": "owner"] }
        return Decision(d)
    }

    func testOptionsReadTheirGrants() {
        let options = decision().options
        XCTAssertEqual(options[0].grants.count, 3)
        XCTAssertEqual(options[0].grantsSha, "abc123")
        XCTAssertTrue(options[1].grants.isEmpty)
        XCTAssertNil(options[1].grantsSha)
    }

    func testGrantWordsGroupByBot() {
        let names = ["b-devops": "DevOps", "b-tester": "Tester"]
        let words = OptionGrant.words(decision().options[0].grants) { names[$0] ?? $0 }
        XCTAssertEqual(words, "Grants DevOps: install, daemon restart · Tester: install")
    }

    func testOnlyAGrantingOptionSendsASha() {
        let d = decision()
        XCTAssertEqual(d.grantsSha(for: "ship"), "abc123")
        XCTAssertEqual(d.grantsSha(for: "SHIP"), "abc123", "keys match as the daemon does, ignoring case")
        XCTAssertNil(d.grantsSha(for: "hold"))
        XCTAssertNil(d.grantsSha(for: nil), "nothing picked or drafted")
    }

    func testPublishingADraftUsesTheDraftedOption() {
        XCTAssertEqual(decision(ruling: "ship").grantsSha(for: nil), "abc123")
        XCTAssertNil(decision(ruling: "hold").grantsSha(for: nil))
    }

    func testTheHelloOffersDecisionGrants() {
        XCTAssertTrue(DaemonClient.features.contains("decision_grants"))
    }
}
