import XCTest
@testable import Flotilla

/// Assigning a card from the phone (`item_assign`): who it can go to, and
/// what a refusal says.
final class CardAssignTests: XCTestCase {
    private func bot(_ id: String, _ name: String, project: String = "p", temporary: Bool = false) -> Bot {
        Bot(["id": id, "name": name, "project_id": project, "temporary": temporary])
    }

    func testACardGoesToTheProjectsOwnBotsNotItsWorkers() {
        let bots = [bot("b2", "Writer"), bot("b1", "ML engineer"), bot("w", "Worker 1", temporary: true), bot("x", "Other", project: "q")]
        XCTAssertEqual(CardAssign.candidates(bots, projectId: "p").map(\.id), ["b1", "b2"])
    }

    func testARefusalSaysWhyAndADoneEditSaysNothing() {
        var done = Flotilla_Board_V1_EditResult()
        done.done = Flotilla_Board_V1_Item()
        XCTAssertNil(CardAssign.failure(done))
        var refused = Flotilla_Board_V1_EditResult()
        var unmet = Flotilla_Board_V1_Unmet()
        unmet.text = "Only the lead or the owner can."
        refused.refused.unmet = [unmet]
        XCTAssertEqual(CardAssign.failure(refused), "Only the lead or the owner can.")
        var conflict = Flotilla_Board_V1_EditResult()
        conflict.conflict = Flotilla_Board_V1_Item()
        XCTAssertEqual(CardAssign.failure(conflict), "The card changed meanwhile. Try again.")
    }
}
