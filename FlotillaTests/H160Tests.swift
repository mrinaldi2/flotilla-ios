import XCTest
@testable import Flotilla

/// H-160 (UX-029 / UX-031 follow-ups): the words for unread bots, a board kept
/// elsewhere and the project card.
final class H160Tests: XCTestCase {
    func testTheUnreadDotHasWords() {
        XCTAssertEqual(UnreadWords.visible(unread: 1, seenNewer: false), "1 new")
        XCTAssertEqual(UnreadWords.visible(unread: 3, seenNewer: true), "3 new")
        XCTAssertNil(UnreadWords.visible(unread: 0, seenNewer: true), "the thread says it's read")
        XCTAssertEqual(UnreadWords.visible(unread: nil, seenNewer: true), "New", "older service: activity only")
        XCTAssertNil(UnreadWords.visible(unread: nil, seenNewer: false))
        XCTAssertEqual(UnreadWords.spoken("Desktop Dev"), "New message from Desktop Dev")
    }

    func testABoardKeptElsewhereSaysWhere() {
        XCTAssertEqual(BoardWords.elsewhere("Studio Mac"),
                       "This project's board is kept on Studio Mac. Open it there, or link this computer to see it here.")
        XCTAssertEqual(BoardWords.elsewhere(nil),
                       "This project's board is kept on another computer. Open it there, or link this computer to see it here.")
        XCTAssertTrue(BoardWords.isElsewhere(DaemonError(code: "no_board", message: "open it there")))
        XCTAssertTrue(BoardWords.isElsewhere(DaemonError(code: "x", message:
            "This project is linked with another computer, so its board isn't started on its own.")))
        XCTAssertFalse(BoardWords.isElsewhere(DaemonError(code: "internal", message: "database is locked")))
    }

    func testTheMeetingsSegmentIsSpelledOut() {
        XCTAssertEqual(ProjectScreen.Segment.meetings.rawValue, "Meetings")
    }
}
