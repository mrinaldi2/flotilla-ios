import XCTest
@testable import Flotilla

/// H-210: card questions can be answered (Reply opens a sheet) and dismissed;
/// a dismissal goes to the computer that holds the question.
final class H210Tests: XCTestCase {
    private func row(_ kind: Flotilla_Home_V1_AttentionKind, id: String, daemon: String = "") -> HomeAttentionRow {
        var row = HomeAttentionRow()
        row.kind = kind
        row.id = id
        row.daemonID = daemon
        return row
    }

    func testOnlyQuestionsCanBeDismissed() {
        XCTAssertTrue(Dismissal.allowed(row(.ownerQuestion, id: "owner_question:d-imac:q1")))
        XCTAssertFalse(Dismissal.allowed(row(.decision, id: "decision:d-mac:x")), "a decision clears when ruled")
        XCTAssertFalse(Dismissal.allowed(row(.permissionPrompt, id: "permission_prompt:d-mac:y")))
    }

    func testADismissalGoesToTheQuestionsComputer() {
        XCTAssertEqual(Dismissal.daemonId(of: row(.ownerQuestion, id: "owner_question:d-imac:q1", daemon: "d-imac")), "d-imac")
        XCTAssertEqual(Dismissal.daemonId(of: row(.ownerQuestion, id: "owner_question:d-win:q2")), "d-win",
                       "read from the row id when the row doesn't carry it")
        XCTAssertEqual(Dismissal.daemonId(of: row(.ownerQuestion, id: "garbage")), "")
    }

    func testTheReplySheetSaysWhoYouAnswer() {
        XCTAssertEqual(CommentWords.replyTitle("Desktop Dev"), "Reply to Desktop Dev")
        XCTAssertEqual(CommentWords.replyTitle("You"), "Reply to your comment")
    }
}
