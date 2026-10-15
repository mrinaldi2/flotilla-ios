import XCTest
@testable import Flotilla

/// H-118 AC3 (UX-023 decision 2): publishing or confirming a ruling whose
/// option grants extras asks for Face ID first, and a refusal sends nothing.
@MainActor
final class OwnerAuthTests: XCTestCase {
    private func store(ruling: String?) -> AppStore {
        let store = AppStore(defaults: ComputerDefaults(id: "test-owner-auth"))
        store.bots = [Bot(["id": "b-devops", "project_id": "p1", "name": "DevOps"])]
        var d: JSONDict = [
            "id": "d1", "project_id": "p1", "kind": "choice", "title": "Install 0.17.1?", "body": "",
            "state": ruling == nil ? "open" : "answered", "priority": "normal",
            "options": [
                ["key": "grant", "label": "Grant", "grants": [["bot": "b-devops", "extra": "install"]], "grants_sha": "abc"],
                ["key": "wait", "label": "Not yet"],
            ],
        ]
        if let ruling { d["ruling"] = ["option": ruling, "text": "x", "answered_by": "owner"] }
        store.decisions = [Decision(d)]
        return store
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "ownerAuthStub")
        super.tearDown()
    }

    func testTheFaceIDReasonNamesWhatIsGranted() throws {
        let store = store(ruling: nil)
        let decision = try XCTUnwrap(store.decisions.first)
        XCTAssertEqual(store.grantsReason(decision, option: "grant", action: .publish),
                       "Publish this ruling? It grants DevOps: install.")
        XCTAssertEqual(store.grantsReason(decision, option: "grant", action: .confirm),
                       "Confirm this ruling? It grants DevOps: install.", "the verb follows the action (UX-032)")
        XCTAssertNil(store.grantsReason(decision, option: "wait", action: .publish), "an option without grants asks nothing")
        XCTAssertNil(store.grantsReason(decision, option: nil, action: .publish), "nothing picked or drafted")
    }

    func testARefusedFaceIDPublishesNothing() async {
        UserDefaults.standard.set("fail", forKey: "ownerAuthStub")
        let store = store(ruling: "grant")
        do {
            try await store.publish("d1")
            XCTFail("publishing a granting ruling must ask first")
        } catch {
            XCTAssertEqual(error as? OwnerAuth.Failure, .cancelled(.publish))
            XCTAssertEqual(error.localizedDescription, "Not published. Nothing was sent.")
        }
        do {
            try await store.answerAndPublish("d1", option: "grant", text: "Grant", reason: nil)
            XCTFail("answering with a granting option must ask before it sends the draft")
        } catch {
            XCTAssertEqual(error as? OwnerAuth.Failure, .cancelled(.publish))
        }
        do {
            try await store.confirmRuling(store.decisions[0])
            XCTFail("confirming a relayed granting ruling must ask first")
        } catch {
            XCTAssertEqual(error as? OwnerAuth.Failure, .cancelled(.confirm))
            XCTAssertEqual(error.localizedDescription, "Not confirmed. Nothing was sent.")
        }
    }

    func testANonGrantingRulingNeverAsks() async throws {
        UserDefaults.standard.set("fail", forKey: "ownerAuthStub")
        let store = store(ruling: "wait")
        try await store.confirmGrants(store.decisions[0], option: nil, action: .publish)
        try await store.confirmGrants(store.decisions[0], option: "wait", action: .confirm)
    }

    func testUnavailableNamesWhereToRule() {
        XCTAssertEqual(OwnerAuth.Failure.unavailable(computer: "Studio Mac").localizedDescription,
                       "Set up Face ID or a passcode on this device to rule on access, or do it on Studio Mac, in the Flotilla app.")
        XCTAssertEqual(OwnerAuth.Failure.unavailable(computer: "").localizedDescription,
                       "Set up Face ID or a passcode on this device to rule on access, or do it on your computer, in the Flotilla app.")
    }
}
