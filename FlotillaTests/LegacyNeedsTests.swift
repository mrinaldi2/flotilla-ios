import XCTest
@testable import Flotilla

/// An older daemon (no projects_overview) still lists every bot waiting on the
/// owner in Needs you, as 0.4.x Home did (H-129 M6, QA-004).
@MainActor
final class LegacyNeedsTests: XCTestCase {
    func testABotWaitingOnItsTerminalApprovalIsListed() {
        let store = AppStore(defaults: ComputerDefaults(id: "test-legacy-needs"))
        store.daemonId = "d1"
        store.projects = [Project(["id": "p1", "name": "Aurora"])]
        store.bots = [Bot(["id": "b1", "project_id": "p1", "name": "Designer"]),
                      Bot(["id": "b2", "project_id": "p1", "name": "Writer"]),
                      Bot(["id": "b3", "project_id": "p2", "name": "Elsewhere"])]
        store.approvals = ["b1": Approval(tool: "Bash").line, "b2": Approval(tool: nil).line, "b3": "Needs approval"]

        let row = store.legacyRows().first { $0.projectID == "p1" }
        XCTAssertEqual(row?.attention.count, 2)
        XCTAssertEqual(row?.attention.byKind["bot_waiting"], 2)

        let rows = store.legacyAttention(projectId: "p1")
        XCTAssertEqual(Set(rows.map(\.title)), ["Designer wants to run Bash", "Writer needs approval"])
        XCTAssertTrue(rows.allSatisfy { $0.kind == .botWaiting })
        guard case .bot(let ref)? = rows.first?.target else { return XCTFail("a bot_waiting row targets its bot") }
        XCTAssertEqual(ref.daemonID, "d1")
    }
}
