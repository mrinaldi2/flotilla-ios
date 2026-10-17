import XCTest
@testable import Flotilla

/// Board glance, phase 2 (0.20): a column as a sheet (case 5), pull-down
/// search, and what Delete says first (case 6).
@MainActor
final class GlanceActionsTests: XCTestCase {
    private func column(_ key: String, _ kind: Flotilla_Board_V1_ColumnKind, _ category: Flotilla_Board_V1_ColumnCategory,
                        visible: Bool = true) -> BoardColumnRow {
        var column = BoardColumnRow()
        column.key = key
        column.name = key.capitalized
        column.kind = kind
        column.category = category
        column.visible = visible
        return column
    }

    private var simpleReview: [BoardColumnRow] {
        [column("todo", .open, .inbox), column("doing", .active, .doing), column("review", .active, .doing),
         column("done", .done, .done), column("cancelled", .cancelled, .cancelled, visible: false)]
    }

    func testReviewApprovesToDoneAndSendsBackToDoing() {
        XCTAssertTrue(ColumnActions.isReview("review", in: simpleReview))
        XCTAssertFalse(ColumnActions.isReview("doing", in: simpleReview))
        XCTAssertEqual(ColumnActions.approve(in: simpleReview), "done")
        XCTAssertEqual(ColumnActions.sendBack(from: "review", in: simpleReview), "doing")
    }

    func testAReleaseGatedReviewIsFoundByItsCategory() {
        let gated = [column("inbox", .open, .inbox), column("doing", .active, .doing), column("code-review", .active, .review),
                     column("done", .done, .done)]
        XCTAssertTrue(ColumnActions.isReview("code-review", in: gated))
        XCTAssertEqual(ColumnActions.sendBack(from: "code-review", in: gated), "doing")
    }

    func testTheSheetSaysWhatWaits() {
        XCTAssertEqual(ColumnActions.header(project: "PhD", count: 2, review: true), "PhD · 2 cards wait for you")
        XCTAssertEqual(ColumnActions.header(project: "PhD", count: 1, review: true), "PhD · 1 card waits for you")
        XCTAssertEqual(ColumnActions.header(project: "PhD", count: 0, review: true), "PhD · 0 cards")
        XCTAssertEqual(ColumnActions.header(project: "PhD", count: 3, review: false), "PhD · 3 cards")
    }

    private func card(_ name: String, bots: UInt32 = 0) -> HomeCard {
        var row = HomeRow()
        row.projectID = name
        row.name = name
        row.bots = bots
        return HomeCard(row: row, computerId: "mac", staleNames: [], staleSince: nil)
    }

    func testSearchMatchesEveryWordOfTheName() {
        XCTAssertTrue(BoardGlance.matches(card("Recipe Box"), search: ""))
        XCTAssertTrue(BoardGlance.matches(card("Recipe Box"), search: "box"))
        XCTAssertTrue(BoardGlance.matches(card("Recipe Box"), search: "rec bo"))
        XCTAssertFalse(BoardGlance.matches(card("Recipe Box"), search: "tax"))
    }

    func testDeleteSaysWhereAndThatFilesGoToTheTrash() {
        XCTAssertEqual(DeleteWords.message(card("PhD", bots: 3), computer: "This Mac"),
                       "PhD is deleted on This Mac. Its 3 bots stop, and what it left on disk moves to the Trash, where it can be put back.")
        XCTAssertEqual(DeleteWords.message(card("PhD"), computer: "This Mac"),
                       "PhD is deleted on This Mac, and what it left on disk moves to the Trash, where it can be put back.")
    }
}
