import SwiftProtobuf
import XCTest
@testable import TheHermes

/// K7: the phone reads a 0.19 daemon's boards, drafts and attachments from
/// the daemon's own golden fixtures, and still reads a 0.18 snapshot, which
/// names no boards: one board, no drafts.
@MainActor
final class KanbanDecodingTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("contract/fixtures/board")

    private func envelope(_ name: String) throws -> Hermes_Wire_V1_Envelope {
        let text = try String(contentsOf: Self.fixtures.appendingPathComponent("messages/\(name).json"), encoding: .utf8)
        return try Hermes_Wire_V1_Envelope(jsonString: text)
    }

    private func response(_ name: String) throws -> Hermes_Board_V1_BoardResponse.OneOf_Response {
        guard case .boardResponse(let response)? = try envelope(name).body, let answer = response.response else {
            throw DaemonError(code: "fixture", message: "\(name) is not a board response")
        }
        return answer
    }

    /// A 0.18 home's snapshot: no boards, no kinds, no board ids, no drafts.
    static let snapshot018 = """
    {"settings": {"projectId": "p1", "key": "H", "homeDaemonId": "d-mac", "version": "3"},
     "columns": [
      {"projectId": "p1", "key": "inbox", "name": "Inbox", "ord": 0, "category": "COLUMN_CATEGORY_INBOX", "visible": true},
      {"projectId": "p1", "key": "ready", "name": "Ready", "ord": 1, "category": "COLUMN_CATEGORY_READY", "visible": true},
      {"projectId": "p1", "key": "doing", "name": "Doing", "ord": 2, "category": "COLUMN_CATEGORY_DOING", "wipLimit": 3, "visible": true},
      {"projectId": "p1", "key": "done", "name": "Done", "ord": 7, "category": "COLUMN_CATEGORY_DONE", "visible": true},
      {"projectId": "p1", "key": "cancelled", "name": "Cancelled", "ord": 8, "category": "COLUMN_CATEGORY_CANCELLED", "visible": false}],
     "cards": [
      {"id": "H-2", "type": "ITEM_TYPE_BUG", "title": "Second", "rank": "b", "columnKey": "doing", "version": "4"},
      {"id": "H-1", "type": "ITEM_TYPE_FEATURE", "title": "First", "rank": "a", "columnKey": "doing", "version": "2"},
      {"id": "H-3", "type": "ITEM_TYPE_CHORE", "title": "Third", "rank": "a", "columnKey": "inbox", "version": "1"}],
     "seq": "40"}
    """

    func testA018SnapshotIsOneBoardWithKindsFromCategories() throws {
        let snapshot = try BoardSnapshot(jsonString: Self.snapshot018)
        let state = BoardState(snapshot: snapshot, remembered: "p1/other")
        XCTAssertFalse(state.hasBoards, "no boards: no picker, no drafts, no quick add")
        XCTAssertEqual(state.selected, "")
        XCTAssertNil(state.board)
        XCTAssertEqual(state.columns.map(\.key), ["inbox", "ready", "doing", "done"], "the hidden column is left out")
        XCTAssertEqual(state.allColumns.count, 5)
        XCTAssertEqual(state.allColumns.map(\.effectiveKind), [.open, .open, .active, .done, .cancelled])
        XCTAssertEqual(state.startColumn, "doing")
        XCTAssertEqual(state.cards(in: "doing").map(\.id), ["H-1", "H-2"], "rank order")
        XCTAssertTrue(state.drafts.isEmpty)
        XCTAssertEqual(state.firstOpenColumn?.key, "inbox")
        XCTAssertEqual(state.columns[2].chip(count: 2), "Doing 2/3")
    }

    func testA018SnapshotSurvivesTheBinaryWire() throws {
        let snapshot = try BoardSnapshot(jsonString: Self.snapshot018)
        var response = Hermes_Board_V1_BoardResponse()
        response.response = .board(snapshot)
        var envelope = Hermes_Wire_V1_Envelope()
        envelope.reqID = 3
        envelope.body = .boardResponse(response)
        let decoded = try Hermes_Wire_V1_Envelope(serializedBytes: try envelope.serializedData())
        guard case .boardResponse(let back)? = decoded.body, case .board(let board)? = back.response else { return XCTFail("not a board") }
        XCTAssertTrue(board.boards.isEmpty)
        XCTAssertEqual(board.cards.map(\.boardID), ["", "", ""], "no board ids from a 0.18 home")
        XCTAssertEqual(BoardState(snapshot: board).cards(in: "doing").count, 2, "an empty board id is on the one board")
    }

    func testA018ItemHasNoStateAndNoAttachments() throws {
        let item = try BoardItemDetail(jsonString: """
        {"item": {"id": "H-1", "title": "First", "columnKey": "doing", "version": "2"}}
        """)
        XCTAssertEqual(item.item.state, "", "empty means live")
        XCTAssertTrue(item.attachments.isEmpty)
        XCTAssertTrue(item.invited.isEmpty)
    }

    func testThe019BoardFixtureCarriesDraftsOffTheColumns() throws {
        guard case .board(let snapshot) = try response("response.board") else { return XCTFail("not a board") }
        XCTAssertEqual(snapshot.seq, 12)
        XCTAssertEqual(snapshot.columns.first?.effectiveKind, .active)
        XCTAssertEqual(snapshot.columns.first?.boardID, "p1/main")
        let state = BoardState(snapshot: snapshot)
        XCTAssertEqual(state.drafts.map(\.id), ["RB-020"])
        XCTAssertTrue(state.cards(in: "todo").isEmpty, "a draft keeps a column key but is on no column")
    }

    func testTheDraftChangedPushFixtureFillsTheTray() throws {
        guard case .boardPush(let push)? = try envelope("push.board_event.draft_changed").body,
              case .boardEvent(let event)? = push.push else { return XCTFail("not a board push") }
        var snapshot = try BoardSnapshot(jsonString: Self.snapshot018)
        snapshot.seq = event.seq - 1
        var state = BoardState(snapshot: snapshot)
        XCTAssertTrue(state.apply(event))
        XCTAssertEqual(state.snapshot.drafts.map(\.id), ["RB-020"])
        XCTAssertTrue(state.cards(in: "todo").isEmpty)
    }

    func testTheItemFixtureCarriesItsAttachments() throws {
        guard case .item(let detail) = try response("response.item") else { return XCTFail("not an item") }
        XCTAssertEqual(detail.item.state, "live")
        let image = try XCTUnwrap(detail.attachments.first)
        XCTAssertEqual(image.kind, "image")
        XCTAssertEqual(AttachmentWords.line(image), "PNG image · \(AttachmentRules.size(48213))")
        XCTAssertEqual(AttachmentWords.addedBy(image) { _ in nil }, "Added by You")
    }

    func testTheDraftChangesFixtureReadsAsWords() throws {
        guard case .draftChanges(let changes) = try response("response.draft_changes") else { return XCTFail("not draft changes") }
        let revision = try XCTUnwrap(changes.revisions.first)
        XCTAssertEqual(DraftWords.change(revision), "Acceptance criteria: 2 now")
        XCTAssertEqual(DraftWords.author(revision.actor) { $0 == "b-lead" ? "Lead" : nil }, "Lead")
        XCTAssertNil(DraftWords.unseenLine(changes.revisions, seen: changes.seen) { _ in "Lead" }, "seen up to 7")
        XCTAssertEqual(DraftWords.unseenLine(changes.revisions, seen: 0) { _ in "Lead" }, "1 change by Lead since you looked")
    }

    func testTheMoveCheckFixtureBecomesOptions() throws {
        guard case .moveCheck(let check) = try response("response.move_check") else { return XCTFail("not a move check") }
        var review = BoardColumnRow()
        review.key = "review"
        review.name = "Review"
        review.visible = true
        var inbox = review
        inbox.key = "inbox"
        inbox.name = "Inbox"
        var doing = review
        doing.key = "doing"
        let options = MoveOption.options(check, columns: [inbox, doing, review], from: "doing")
        XCTAssertEqual(options.map(\.key), ["inbox", "review"], "board order, the card's own column left out")
        XCTAssertTrue(options[0].allowed)
        XCTAssertEqual(options[0].verdict, "✓ Can move")
        XCTAssertFalse(options[1].allowed)
        XCTAssertEqual(options[1].verdict, "⛔ Not allowed")
        XCTAssertEqual(MoveOutcome.lines(options[1].refusals), ["The reviewer can't be the assignee. Pick another reviewer."])
    }

    func testTheStructureFixtureNamesItsProposal() throws {
        guard case .structure(let result) = try response("response.structure") else { return XCTFail("not a structure result") }
        XCTAssertEqual(result.outcome, .proposalID("bp1"))
        XCTAssertEqual(result.boardID, "b1")
    }

    func testTheMovedFixturesBecomeOutcomes() throws {
        guard case .moved(let done) = try response("response.moved.done"),
              case .moved(let refused) = try response("response.moved.refused"),
              case .moved(let conflict) = try response("response.moved.conflict") else { return XCTFail("not moves") }
        XCTAssertEqual(MoveOutcome(done), .done)
        guard case .refused(let unmet) = MoveOutcome(refused) else { return XCTFail("not refused") }
        XCTAssertFalse(unmet.isEmpty)
        XCTAssertEqual(MoveOutcome(conflict), .conflict)
    }
}

/// The board's state and pushes, moves, proposals, draft words and undo, attachments.
@MainActor
final class KanbanLogicTests: XCTestCase {
    static func snapshot019() throws -> BoardSnapshot {
        try BoardSnapshot(jsonString: """
        {"settings": {"projectId": "p1", "key": "RB"},
         "boards": [
          {"id": "b-research", "projectId": "p1", "name": "Research", "key": "RS", "ord": 2, "flow": "custom", "version": "1"},
          {"id": "b-main", "projectId": "p1", "name": "Main", "key": "RB", "ord": 1, "isDefault": true, "flow": "custom", "version": "4"},
          {"id": "b-old", "projectId": "p1", "name": "Old", "key": "OLD", "ord": 0, "archived": true}],
         "columns": [
          {"key": "todo", "name": "To do", "ord": 0, "visible": true, "boardId": "b-main", "kind": "COLUMN_KIND_OPEN"},
          {"key": "doing", "name": "Doing", "ord": 1, "wipLimit": 3, "visible": true, "boardId": "b-main", "kind": "COLUMN_KIND_ACTIVE"},
          {"key": "done", "name": "Done", "ord": 2, "visible": true, "boardId": "b-main", "kind": "COLUMN_KIND_DONE"},
          {"key": "rs-todo", "name": "Ideas", "ord": 0, "visible": true, "boardId": "b-research", "kind": "COLUMN_KIND_OPEN"}],
         "cards": [
          {"id": "RB-1", "title": "Main card", "rank": "a", "columnKey": "doing", "boardId": "b-main", "version": "1"},
          {"id": "RS-1", "title": "Research card", "rank": "a", "columnKey": "rs-todo", "boardId": "b-research", "version": "1"}],
         "drafts": [{"id": "RB-9", "title": "A draft", "columnKey": "todo", "boardId": "b-main", "draft": true, "version": "2"}],
         "seq": "10"}
        """)
    }

    private func event(_ seq: UInt64, _ kind: Hermes_Board_V1_BoardEventKind, _ id: String, card: BoardCard? = nil) -> BoardEvent {
        var event = BoardEvent()
        event.projectID = "p1"
        event.seq = seq
        event.kind = kind
        event.itemID = id
        if let card { event.card = card }
        return event
    }

    private func card(_ id: String, column: String, board: String = "b-main", draft: Bool = false) -> BoardCard {
        var card = BoardCard()
        card.id = id
        card.title = id
        card.columnKey = column
        card.boardID = board
        card.draft = draft
        card.rank = "m"
        return card
    }

    func testBoardsAreOpenOnesDefaultFirstAndTheChoiceIsRemembered() throws {
        let snapshot = try Self.snapshot019()
        let fresh = BoardState(snapshot: snapshot)
        XCTAssertTrue(fresh.hasBoards)
        XCTAssertEqual(fresh.boards.map(\.name), ["Main", "Research"], "archived left out, default first")
        XCTAssertEqual(fresh.selected, "b-main")
        XCTAssertEqual(fresh.columns.map(\.key), ["todo", "doing", "done"])
        XCTAssertEqual(fresh.cards(in: "doing").map(\.id), ["RB-1"])
        XCTAssertEqual(fresh.drafts.map(\.id), ["RB-9"])
        XCTAssertEqual(fresh.boardName(of: fresh.drafts[0]), "Main", "named, since the project has two boards")

        var research = BoardState(snapshot: snapshot, remembered: "b-research")
        XCTAssertEqual(research.columns.map(\.name), ["Ideas"])
        XCTAssertEqual(research.cards(in: "rs-todo").map(\.id), ["RS-1"])
        research.select("b-old")
        XCTAssertEqual(research.selected, "b-research", "an archived board can't be picked")
        XCTAssertEqual(BoardState(snapshot: snapshot, remembered: "b-old").selected, "b-main", "a remembered board now archived falls back")
    }

    func testPushesApplyInSequence() throws {
        var state = BoardState(snapshot: try Self.snapshot019())
        XCTAssertTrue(state.apply(event(11, .itemMoved, "RB-1", card: card("RB-1", column: "done"))))
        XCTAssertEqual(state.cards(in: "done").map(\.id), ["RB-1"])
        XCTAssertTrue(state.cards(in: "doing").isEmpty)
        XCTAssertTrue(state.apply(event(12, .itemUpserted, "RB-10", card: card("RB-10", column: "todo"))))
        XCTAssertEqual(state.cards(in: "todo").map(\.id), ["RB-10"])
        XCTAssertTrue(state.apply(event(13, .draftChanged, "RB-11", card: card("RB-11", column: "todo", draft: true))))
        XCTAssertEqual(state.drafts.map(\.id), ["RB-9", "RB-11"])
        // Finalized: off the tray, then on the board as an upsert.
        XCTAssertTrue(state.apply(event(14, .draftChanged, "RB-9")))
        XCTAssertTrue(state.apply(event(15, .itemUpserted, "RB-9", card: card("RB-9", column: "todo"))))
        XCTAssertEqual(state.drafts.map(\.id), ["RB-11"])
        XCTAssertEqual(Set(state.cards(in: "todo").map(\.id)), ["RB-9", "RB-10"])
        XCTAssertTrue(state.apply(event(16, .itemRemoved, "RB-10")))
        XCTAssertEqual(state.cards(in: "todo").map(\.id), ["RB-9"])
        XCTAssertEqual(state.snapshot.seq, 16)
    }

    func testAGapAStructureChangeOrARestartAsksForTheBoardAgain() throws {
        var state = BoardState(snapshot: try Self.snapshot019())
        XCTAssertFalse(state.apply(event(12, .itemRemoved, "RB-1")), "a gap")
        XCTAssertFalse(state.apply(event(3, .itemRemoved, "RB-1")), "a lower number: the daemon restarted")
        XCTAssertFalse(state.apply(event(11, .columnsChanged, "")))
        XCTAssertFalse(state.apply(event(11, .settingsChanged, "")))
        XCTAssertFalse(state.apply(event(11, .resync, "")))
        XCTAssertFalse(state.apply(event(11, .itemUpserted, "RB-1")), "a card the daemon couldn't read back")
        XCTAssertEqual(state.snapshot.seq, 10, "nothing applied")
        XCTAssertEqual(state.cards(in: "doing").map(\.id), ["RB-1"])
    }

    func testMoveOptionsAskForAReasonOrAnOverrideOnlyWhenARuleDoes() {
        var check = Hermes_Board_V1_MoveCheck()
        func column(_ key: String, _ codes: [String]) -> Hermes_Board_V1_ColumnCheck {
            var c = Hermes_Board_V1_ColumnCheck()
            c.columnKey = key
            c.unmet = codes.map { code in
                var unmet = BoardUnmet()
                unmet.code = code
                unmet.text = "\(code) text."
                return unmet
            }
            return c
        }
        check.columns = [column("todo", ["reason.required"]), column("done", ["wip.full", "reason.required"]), column("rs-todo", [])]
        var todo = BoardColumnRow()
        todo.key = "todo"
        todo.name = "To do"
        todo.visible = true
        var done = todo
        done.key = "done"
        done.name = "Done"
        done.visible = false
        let options = MoveOption.options(check, columns: [todo, done], from: "doing")
        XCTAssertEqual(options.map(\.key), ["todo", "done"], "another board's column is left out")
        XCTAssertTrue(options[0].allowed)
        XCTAssertEqual(options[0].verdict, "✎ Needs a reason")
        XCTAssertEqual(options[1].verdict, "✎ Needs a reason and an override")
        XCTAssertFalse(options[1].visible)
    }

    func testAProposalIsReadFromItsDecision() {
        let proposal = BoardProposal(title: "Board change proposed for Main: add column “QA” with rules assignee_set",
                                     body: "Lead proposes to add column “QA” with rules assignee_set on board Main.\n\n"
                                         + "Approve or decline it in Needs you; nothing changes until you do. Proposal 1b2c-33d4-e5.")
        XCTAssertEqual(proposal?.id, "1b2c-33d4-e5")
        XCTAssertEqual(proposal?.boardName, "Main")
        XCTAssertEqual(proposal?.summary, "add column “QA” with rules assignee_set")
        XCTAssertEqual(proposal?.columnChange, .add("QA"))
        var todo = BoardColumnRow()
        todo.key = "todo"
        todo.name = "To do"
        var review = todo
        review.key = "review"
        review.name = "Review"
        let strips = proposal?.strips(before: [todo, review])
        XCTAssertEqual(strips?.after, ["To do", "Review", "+ QA"])
        let removal = BoardProposal(title: "Board change proposed for Main: remove column review", body: "… Proposal bp1.")
        XCTAssertEqual(removal?.strips(before: [todo, review])?.after, ["To do", "− Review"])
        XCTAssertNil(BoardProposal(title: "Which accent colour?", body: "Proposal bp1."), "not a board change")
        XCTAssertNil(BoardProposal(title: "Board change proposed for Main: rename", body: "No id here."))
        XCTAssertNil(BoardProposal(title: "Board change proposed for Main: rename the board to “X”", body: "Proposal bp1.")?.columnChange)
    }

    // MARK: Drafts

    private func revision(_ id: Int64, _ field: String, from: String?, to: String?, by actor: String = "bot:b-lead") -> DraftRevision {
        var r = DraftRevision()
        r.id = id
        r.itemID = "RB-9"
        r.actor = actor
        r.field = field
        if let from { r.from = from }
        if let to { r.to = to }
        return r
    }

    private func draftDetail() -> BoardItemDetail {
        var detail = BoardItemDetail()
        detail.item.id = "RB-9"
        detail.item.version = 6
        detail.item.state = "draft"
        var shot = ItemAttachment()
        shot.id = "a1"
        shot.name = "shot.png"
        detail.attachments = [shot]
        var link = Hermes_Board_V1_ItemLink()
        link.kind = .artifact
        link.ref = "specs/RB-9.md"
        detail.links = [link]
        return detail
    }

    func testDraftChangesInWords() {
        XCTAssertEqual(DraftWords.change(revision(1, "title", from: "Import", to: "Import recipes")), "Title: “Import” → “Import recipes”")
        XCTAssertEqual(DraftWords.change(revision(2, "attachment", from: nil, to: "shot.png")), "Attached shot.png")
        XCTAssertEqual(DraftWords.change(revision(3, "link", from: nil, to: "artifact:specs/RB-9.md")), "Linked specs/RB-9.md")
        XCTAssertEqual(DraftWords.change(revision(4, "link", from: nil, to: "item:blocks:RB-2")), "Linked RB-2")
        XCTAssertEqual(DraftWords.change(revision(5, "size", from: "", to: "M")), "Size: M")
        XCTAssertEqual(DraftWords.change(revision(6, "priority", from: "P2", to: "P1")), "Priority: P2 → P1")
        XCTAssertEqual(DraftWords.change(revision(7, "description", from: "", to: "x")), "Wrote the description")
        let revisions = [revision(1, "title", from: "a", to: "b", by: "device:d1"), revision(2, "title", from: "b", to: "c"),
                         revision(3, "size", from: "", to: "M", by: "bot:b-dev")]
        let names = ["b-lead": "Lead", "b-dev": "Dev"]
        XCTAssertEqual(DraftWords.unseenLine(revisions, seen: 1) { names[$0] }, "2 changes by Lead and Dev since you looked")
        XCTAssertNil(DraftWords.unseenLine(revisions, seen: 3) { names[$0] })
        XCTAssertEqual(DraftWords.author("device:d1") { _ in nil }, "You")
    }

    func testUndoPutsTheFieldBackOnlyFromItsLatestChange() {
        let detail = draftDetail()
        let first = revision(1, "title", from: "Import", to: "Import recipes")
        let second = revision(2, "title", from: "Import recipes", to: "Import recipes from sites")
        let all = [first, second]
        XCTAssertNil(DraftUndo.of(first, among: all, detail: detail), "a later change to the title comes first")
        guard case .update(let update)? = DraftUndo.of(second, among: all, detail: detail) else { return XCTFail("no undo") }
        XCTAssertEqual(update.id, "RB-9")
        XCTAssertEqual(update.expectedVersion, 6)
        XCTAssertEqual(update.title, "Import recipes")
        XCTAssertFalse(update.hasDescription_p, "only the field undone")

        let ac = revision(3, "acceptance_criteria", from: "Cups\nGrams", to: "Cups\nGrams\nSpoons")
        guard case .update(let acUpdate)? = DraftUndo.of(ac, among: [ac], detail: detail) else { return XCTFail("no undo") }
        XCTAssertTrue(acUpdate.hasAcceptanceCriteria)
        XCTAssertEqual(acUpdate.acceptanceCriteria.values, ["Cups", "Grams"])

        let labels = revision(4, "labels", from: "", to: "ui")
        guard case .update(let labelUpdate)? = DraftUndo.of(labels, among: [labels], detail: detail) else { return XCTFail("no undo") }
        XCTAssertTrue(labelUpdate.hasLabels, "an empty list is sent, so the labels clear")
        XCTAssertEqual(labelUpdate.labels.values, [])

        XCTAssertNil(DraftUndo.of(revision(5, "size", from: "", to: "M"), among: [], detail: detail), "an edit can't clear a size")
        XCTAssertEqual(DraftUndo.of(revision(6, "attachment", from: nil, to: "shot.png"), among: [], detail: detail),
                       .detach(attachmentId: "a1"))
        XCTAssertNil(DraftUndo.of(revision(7, "attachment", from: "old.png", to: nil), among: [], detail: detail), "a removal stays")
        guard case .unlink(let unlink)? = DraftUndo.of(revision(8, "link", from: nil, to: "artifact:specs/RB-9.md"), among: [], detail: detail)
        else { return XCTFail("no unlink") }
        XCTAssertEqual(unlink.kind, .artifact)
        XCTAssertEqual(unlink.ref, "specs/RB-9.md")
        XCTAssertNil(DraftUndo.of(revision(9, "link", from: nil, to: "thread:b-lead"), among: [], detail: detail), "the discussion stays linked")
    }

    // MARK: Attachments

    func testAttachmentRulesRefuseAtOnce() {
        XCTAssertNil(AttachmentRules.refusal(name: "shot.PNG", bytes: 1_000))
        XCTAssertNil(AttachmentRules.refusal(name: "notes.md", bytes: 20 * 1024 * 1024))
        XCTAssertNotNil(AttachmentRules.refusal(name: "IMG_1.HEIC", bytes: 1_000))
        XCTAssertEqual(AttachmentRules.refusal(name: "a.zip", bytes: 10),
                       "A .zip file can't be attached: PNG, JPEG, WebP, GIF, PDF, Markdown, text or log only.")
        XCTAssertNotNil(AttachmentRules.refusal(name: "big.jpg", bytes: AttachmentRules.imageCap + 1))
        XCTAssertNil(AttachmentRules.refusal(name: "big.pdf", bytes: AttachmentRules.imageCap + 1), "a file's cap is 25 MB")
        XCTAssertNotNil(AttachmentRules.totalRefusal(AttachmentRules.itemCap + 1))
        let uploadId = AttachmentRules.uploadId()
        XCTAssertTrue(uploadId.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } && uploadId.count <= 64)
    }

    func testAFileGoesInChunksOfAtMost512KiB() {
        let data = Data(repeating: 7, count: 1_200_000)
        let chunks = AttachmentRules.chunks(data)
        XCTAssertEqual(chunks.map(\.offset), [0, 524_288, 1_048_576])
        XCTAssertEqual(chunks.map(\.data.count), [524_288, 524_288, 151_424])
        XCTAssertTrue(AttachmentRules.chunks(Data()).isEmpty)
    }

    func testInlineImagesBecomeWordsAndARemovedOneAPlaceholder() {
        var shot = ItemAttachment()
        shot.id = "a1"
        shot.name = "shot.png"
        var gone = ItemAttachment()
        gone.id = "a2"
        gone.name = "old.png"
        gone.removed = true
        let text = "See ![the error](attachment:a1) and ![](attachment:a2), not ![x](https://e.com/x.png)."
        XCTAssertEqual(AttachmentText.inline(text, attachments: [shot, gone]),
                       "See 🖼 *image: the error, under Attachments* and ⊘ *removed image: old.png*, not ![x](https://e.com/x.png).")
        XCTAssertEqual(AttachmentText.inline("plain", attachments: []), "plain")
    }

    func testKindsAreAGlyphAndAWord() {
        XCTAssertEqual(ColumnKindWords.chip(.open), "○ open")
        XCTAssertEqual(ColumnKindWords.chip(.active), "◐ active")
        XCTAssertEqual(ColumnKindWords.chip(.done), "● done")
        XCTAssertEqual(ColumnKindWords.chip(.cancelled), "⊘ cancelled")
    }
}
