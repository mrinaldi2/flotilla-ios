import SwiftProtobuf
import XCTest
@testable import Flotilla

/// H-202: a posted comment shows at once and is then confirmed, or fails
/// with a retry; replies sit under their comment; older services that send no
/// comment text still show that a comment is there.
final class ItemCommentsTests: XCTestCase {
    private func comment(_ id: String, _ author: String, _ body: String, replyTo: String? = nil, at: Int64 = 1) -> Hermes_Board_V1_ItemComment {
        var c = Hermes_Board_V1_ItemComment()
        c.id = id
        c.author = author
        c.body = body
        if let replyTo { c.replyTo = replyTo }
        c.at = Google_Protobuf_Timestamp(seconds: at)
        return c
    }

    // H-225 (desktop H-201 S4): a late "Couldn't post", then Retry, never posts twice.
    func testRetryFindsACommentThatLandedLateAndSendsNothing() async throws {
        let failed = PendingComment(body: "Ship it after the fix", replyTo: "c1", at: Date(timeIntervalSince1970: 1_000))
        var posts = 0
        var reads = 0
        let result = try await CommentThread.retry(failed, reread: {
            reads += 1
            return [self.comment("c1", "bot:dev", "Ready?"),
                    self.comment("c9", "device:phone", "Ship it after the fix", replyTo: "c1", at: 1_003)]
        }, post: { posts += 1 })
        XCTAssertEqual(result, .alreadyPosted)
        XCTAssertEqual(reads, 1, "the card is re-read first")
        XCTAssertEqual(posts, 0, "not posted twice")
    }

    func testRetryPostsWhenTheCardDoesNotHaveIt() async throws {
        let failed = PendingComment(body: "Ship it after the fix", replyTo: nil, at: Date(timeIntervalSince1970: 1_000))
        var posts = 0
        // The same words, but older, or under another comment, or by a bot: not this one.
        let result = try await CommentThread.retry(failed, reread: {
            [self.comment("old", "user", "Ship it after the fix", at: 500),
             self.comment("reply", "user", "Ship it after the fix", replyTo: "c1", at: 1_001),
             self.comment("bot", "bot:dev", "Ship it after the fix", at: 1_001)]
        }, post: { posts += 1 })
        XCTAssertEqual(result, .posted)
        XCTAssertEqual(posts, 1)
    }

    func testRetrySendsNothingWhenTheCardCannotBeRead() async {
        let failed = PendingComment(body: "Ship it", replyTo: nil)
        var posts = 0
        do {
            _ = try await CommentThread.retry(failed, reread: { throw URLError(.notConnectedToInternet) }, post: { posts += 1 })
            XCTFail("expected the read to fail")
        } catch {}
        XCTAssertEqual(posts, 0)
    }

    func testAPostedCommentShowsAtOnceAsSending() {
        let posted = PendingComment(body: "Ship it after the fix", replyTo: nil)
        let rows = CommentThread.rows(comments: [], history: [], pending: [posted])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].status, CommentRow.Status.sending)
        XCTAssertEqual(rows[0].body, "Ship it after the fix")
        XCTAssertEqual(rows[0].pendingId, posted.id)
    }

    func testTheBoardsCopyShowsPostedForAFewSeconds() {
        var posted = PendingComment(body: "Looks good", replyTo: nil)
        posted.state = .sent
        posted.sentAt = Date(timeIntervalSince1970: 1000)
        let board = [comment("c1", "device:phone", "Looks good")]
        let rows = CommentThread.rows(comments: board, history: [], pending: [posted])
        XCTAssertEqual(rows.map(\.id), ["c1"], "no duplicate once the board echoes it")
        XCTAssertEqual(rows[0].status, .sent, "QA-006: the board's copy says Posted")
        // Kept while Posted shows, then dropped, and the row is plain again.
        XCTAssertEqual(CommentThread.stillPending([posted], comments: board, now: Date(timeIntervalSince1970: 1002)).count, 1)
        let later = CommentThread.stillPending([posted], comments: board, now: Date(timeIntervalSince1970: 1005))
        XCTAssertTrue(later.isEmpty)
        XCTAssertEqual(CommentThread.rows(comments: board, history: [], pending: later)[0].status, .onBoard)
    }

    func testAConfirmedCommentStaysPostedWhenTheBoardSendsNoText() {
        var posted = PendingComment(body: "Looks good", replyTo: nil)
        posted.state = .sent
        let rows = CommentThread.rows(comments: [comment("c1", "user", "")], history: [], pending: [posted])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].status, .sent, "older service: our copy stays, marked Posted")
        XCTAssertNil(rows[0].body)
        XCTAssertEqual(CommentThread.stillPending([posted], comments: [comment("c1", "user", "")]).count, 1)
    }

    func testAFailedCommentKeepsItsTextAndReason() {
        var posted = PendingComment(body: "Hold this one", replyTo: nil)
        posted.state = .failed("Not connected to the Hermes service.")
        let rows = CommentThread.rows(comments: [], history: [], pending: [posted])
        XCTAssertEqual(rows[0].status, .failed("Not connected to the Hermes service."))
        XCTAssertEqual(rows[0].body, "Hold this one")
        XCTAssertEqual(CommentThread.stillPending([posted], comments: []).count, 1, "kept for Retry")
    }

    func testRepliesSitUnderTheirComment() {
        let board = [comment("c1", "bot:dev", "Which build?"),
                     comment("c2", "user", "The 0.17.4 one", replyTo: "c1", at: 2),
                     comment("c3", "bot:qa", "Verified", at: 3)]
        let groups = CommentThread.grouped(CommentThread.rows(comments: board, history: [], pending: []))
        XCTAssertEqual(groups.map(\.id), ["c1", "c3"])
        XCTAssertEqual(groups[0].replies.map(\.id), ["c2"])
    }

    func testAReplyToAnUnknownCommentStaysVisible() {
        let rows = CommentThread.rows(comments: [comment("c2", "user", "Yes", replyTo: "gone")], history: [], pending: [])
        XCTAssertEqual(CommentThread.grouped(rows).map(\.id), ["c2"])
    }

    func testAnOlderServiceWithoutCommentsShowsTheCommentedEvents() {
        var event = Hermes_Board_V1_ItemEvent()
        event.id = 7
        event.kind = .commented
        event.actor = "bot:dev"
        event.to = "c9"
        var moved = Hermes_Board_V1_ItemEvent()
        moved.kind = .moved
        let rows = CommentThread.rows(comments: [], history: [event, moved], pending: [])
        XCTAssertEqual(rows.map(\.id), ["c9"])
        XCTAssertNil(rows[0].body)
        XCTAssertEqual(rows[0].author, "bot:dev")
    }

    func testAnUnknownAuthorIsABotNeverAnId() {
        let names = ["dev": "Desktop Dev"]
        XCTAssertEqual(CommentWords.author("bot:dev") { names[$0] }, "Desktop Dev")
        XCTAssertEqual(CommentWords.author("bot:3f2a9c10-aaaa-bbbb-cccc-0123456789ab") { names[$0] }, "A bot")
        XCTAssertEqual(CommentWords.author("device:phone") { names[$0] }, "You")
        XCTAssertEqual(CommentWords.author("user") { names[$0] }, "You")
    }

    func testReplyingToYourOwnComment() {
        XCTAssertEqual(CommentWords.replying(to: "user") { _ in "You" }, "Replying to your comment")
        XCTAssertEqual(CommentWords.replying(to: "bot:dev") { _ in "Desktop Dev" }, "Replying to Desktop Dev")
    }

    func testThePostedLineNamesWhoWasTold() {
        XCTAssertEqual(CommentWords.posted(told: ["Desktop Dev", "Team Lead"]), "✓ Posted. Desktop Dev and Team Lead are told.")
        XCTAssertEqual(CommentWords.posted(told: ["Team Lead"]), "✓ Posted. Team Lead is told.")
        XCTAssertEqual(CommentWords.posted(told: []), "✓ Posted.")
    }

    func testAFailureSaysItCouldntPost() {
        XCTAssertEqual(CommentWords.couldntPost("The board for H-017 lives on mac. Comment on it from there."),
                       "Couldn’t post your comment. The board for H-017 lives on mac. Comment on it from there.")
    }
}
