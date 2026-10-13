import SwiftProtobuf
import XCTest
@testable import TheHermes

/// A daemon for the board's view models: answers from what the test set,
/// records what was asked.
@MainActor
final class FakeKanban: BoardService, DraftService {
    var snapshots: [BoardSnapshot] = []
    var watchError: Error?
    private(set) var watches = 0
    private(set) var handlers: [UUID: (BoardEvent) -> Void] = [:]
    var check = Hermes_Board_V1_MoveCheck()
    var moveResult = Hermes_Board_V1_MoveResult()
    private(set) var moves: [Hermes_Board_V1_ItemMove] = []
    var createResult = Hermes_Board_V1_EditResult()
    private(set) var creates: [Hermes_Board_V1_ItemCreate] = []
    private(set) var uploads: [Hermes_Board_V1_AttachmentUpload] = []
    private(set) var attaches: [Hermes_Board_V1_ItemAttach] = []
    var attachError: Error?
    var changes = Hermes_Board_V1_DraftChanges()
    private(set) var changeCalls: [Bool] = []
    var finalizeResult = Hermes_Board_V1_MoveResult()
    private(set) var finalized: [(String, String?)] = []
    var discardResult = Hermes_Board_V1_EditResult()
    var undoResult = Hermes_Board_V1_EditResult()
    private(set) var undos: [(version: UInt64, revision: Int64)] = []
    /// Called during `watchBoard`, before it answers: pushes that overtake the reply.
    var duringWatch: (() -> Void)?

    func watchBoard(projectId: String) async throws -> BoardSnapshot {
        watches += 1
        duringWatch?()
        duringWatch = nil
        if let watchError { throw watchError }
        return snapshots.count > 1 ? snapshots.removeFirst() : snapshots[0]
    }

    func listen(projectId: String, _ handler: @escaping (BoardEvent) -> Void) -> UUID {
        let token = UUID()
        handlers[token] = handler
        return token
    }

    func stopListening(projectId: String, _ token: UUID) { handlers[token] = nil }
    func push(_ event: BoardEvent) { for handler in handlers.values { handler(event) } }

    func moveCheck(itemId: String) async throws -> Hermes_Board_V1_MoveCheck { check }

    func move(_ move: Hermes_Board_V1_ItemMove) async throws -> Hermes_Board_V1_MoveResult {
        moves.append(move)
        return moveResult
    }

    func createItem(_ create: Hermes_Board_V1_ItemCreate) async throws -> Hermes_Board_V1_EditResult {
        creates.append(create)
        return createResult
    }

    func upload(_ chunk: Hermes_Board_V1_AttachmentUpload) async throws -> UInt64 {
        uploads.append(chunk)
        return chunk.offset + UInt64(chunk.data.count)
    }

    func attach(_ attach: Hermes_Board_V1_ItemAttach) async throws -> BoardItemDetail {
        attaches.append(attach)
        if let attachError { throw attachError }
        return BoardItemDetail()
    }

    func draftChanges(itemId: String, markSeen: Bool) async throws -> Hermes_Board_V1_DraftChanges {
        changeCalls.append(markSeen)
        var answer = changes
        if markSeen { answer.seen = changes.revisions.last?.id ?? changes.seen; changes.seen = answer.seen }
        return answer
    }

    func invite(itemId: String, botId: String?) async throws -> BoardItemDetail { BoardItemDetail() }

    func finalize(itemId: String, version: UInt64, column: String?) async throws -> Hermes_Board_V1_MoveResult {
        finalized.append((itemId, column))
        return finalizeResult
    }

    func discard(itemId: String, version: UInt64, reason: String) async throws -> Hermes_Board_V1_EditResult { discardResult }

    func undo(itemId: String, version: UInt64, revision: Int64) async throws -> Hermes_Board_V1_EditResult {
        undos.append((version, revision))
        return undoResult
    }
}

@MainActor
final class KanbanModelTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "KanbanModelTests-\(UUID().uuidString)")
    }

    /// Waits for work a model started in a task of its own.
    private func eventually(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), what)
    }

    private func event(_ seq: UInt64, _ kind: Hermes_Board_V1_BoardEventKind, card id: String? = nil, column: String = "todo") -> BoardEvent {
        var event = BoardEvent()
        event.projectID = "p1"
        event.seq = seq
        event.kind = kind
        if let id {
            event.itemID = id
            var card = BoardCard()
            card.id = id
            card.columnKey = column
            card.boardID = "b-main"
            event.card = card
        }
        return event
    }

    // MARK: Board

    func testTheBoardOpensOnTheRememberedBoardAndFollowsPushes() async throws {
        let fake = FakeKanban()
        fake.snapshots = [try KanbanLogicTests.snapshot019()]
        let memory = BoardMemory(defaults: defaults)
        memory.remember("b-research", for: "p1")
        let model = BoardModel(projectId: "p1", service: fake, memory: memory)
        await model.start()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.state?.selected, "b-research")
        XCTAssertEqual(model.tab, "rs-todo", "a column of the board on screen")

        model.select(board: "b-main")
        XCTAssertEqual(memory.board(for: "p1"), "b-main", "remembered per project")
        XCTAssertEqual(model.tab, "doing", "the first column in progress")

        fake.push(event(11, .itemMoved, card: "RB-1", column: "done"))
        XCTAssertEqual(model.state?.cards(in: "done").map(\.id), ["RB-1"], "applied at once, no reload")
        XCTAssertEqual(fake.watches, 1)

        model.stop()
        XCTAssertTrue(fake.handlers.isEmpty, "no longer listening")
    }

    func testAGapReadsTheBoardAgain() async throws {
        let fake = FakeKanban()
        var later = try KanbanLogicTests.snapshot019()
        later.seq = 20
        fake.snapshots = [try KanbanLogicTests.snapshot019(), later]
        let model = BoardModel(projectId: "p1", service: fake, memory: BoardMemory(defaults: defaults))
        await model.start()
        fake.push(event(15, .itemRemoved, card: "RB-1"))
        await eventually("read again") { fake.watches == 2 && model.state?.snapshot.seq == 20 }
        fake.push(event(21, .columnsChanged))
        await eventually("a structure change reads it again") { fake.watches == 3 }
    }

    func testPushesThatOvertakeTheSnapshotFollowIt() async throws {
        let fake = FakeKanban()
        fake.snapshots = [try KanbanLogicTests.snapshot019()]
        let model = BoardModel(projectId: "p1", service: fake, memory: BoardMemory(defaults: defaults))
        // seq 10 is in the snapshot already; 11 follows it.
        fake.duringWatch = { [weak fake] in
            fake?.push(self.event(10, .itemRemoved, card: "RB-1"))
            fake?.push(self.event(11, .itemUpserted, card: "RB-12"))
        }
        await model.start()
        XCTAssertEqual(model.state?.snapshot.seq, 11)
        XCTAssertEqual(model.state?.cards(in: "todo").map(\.id), ["RB-12"])
        XCTAssertEqual(model.state?.cards(in: "doing").map(\.id), ["RB-1"], "the push the snapshot held is skipped")
        XCTAssertEqual(fake.watches, 1)
    }

    func testABoardKeptElsewhereSaysSo() async {
        let fake = FakeKanban()
        fake.watchError = DaemonError(code: "no_board", message: "This project's board is linked with another computer.")
        let model = BoardModel(projectId: "p1", service: fake, memory: BoardMemory(defaults: defaults))
        await model.start()
        XCTAssertEqual(model.phase, .elsewhere)
    }

    func testA018BoardHasNoDraftsTab() async throws {
        let fake = FakeKanban()
        fake.snapshots = [try BoardSnapshot(jsonString: KanbanDecodingTests.snapshot018)]
        let model = BoardModel(projectId: "p1", service: fake, memory: BoardMemory(defaults: defaults))
        model.tab = BoardModel.draftsTab
        await model.start()
        XCTAssertEqual(model.state?.hasBoards, false)
        XCTAssertEqual(model.tab, "doing")
    }

    // MARK: Move

    private func columns() throws -> [BoardColumnRow] { BoardState(snapshot: try KanbanLogicTests.snapshot019()).allColumns }

    private func unmet(_ code: String, _ text: String, fix: String? = nil) -> BoardUnmet {
        var unmet = BoardUnmet()
        unmet.code = code
        unmet.text = text
        if let fix { unmet.fix = fix }
        return unmet
    }

    func testAMoveAsksForAReasonOnlyWhenARuleDoesAndSaysARefusal() async throws {
        let fake = FakeKanban()
        var todo = Hermes_Board_V1_ColumnCheck()
        todo.columnKey = "todo"
        todo.unmet = [unmet("reason.required", "Give a reason.")]
        var done = Hermes_Board_V1_ColumnCheck()
        done.columnKey = "done"
        fake.check.columns = [todo, done]
        var card = BoardCard()
        card.id = "RB-1"
        card.columnKey = "doing"
        card.version = 3
        let model = MoveModel(card: card, service: fake)
        await model.check(columns: try columns())
        XCTAssertEqual(model.options.map(\.key), ["todo", "done"])

        model.target = "todo"
        XCTAssertFalse(model.canMove, "the reason is missing")
        model.reason = "  Back to the queue "
        XCTAssertTrue(model.canMove)

        var refused = Hermes_Board_V1_MoveRefused()
        refused.unmet = [unmet("rule.link", "Done needs a PR.", fix: "Link the PR first.")]
        fake.moveResult.outcome = .refused(refused)
        await model.move(columns: try columns())
        XCTAssertEqual(model.refusal, ["Done needs a PR. Link the PR first."])
        XCTAssertEqual(model.phase, .ready, "the sheet stays, saying why")
        XCTAssertEqual(fake.moves.last?.reason, "Back to the queue")
        XCTAssertEqual(fake.moves.last?.expectedVersion, 3)
        XCTAssertFalse(fake.moves.last?.hasOverrideReason ?? true)

        fake.moveResult.outcome = .done(Hermes_Board_V1_Item())
        await model.move(columns: try columns())
        XCTAssertEqual(model.phase, .moved(to: "To do"))
    }

    // MARK: Quick add

    func testQuickAddSavesADraftThenUploadsAndAttachesEachFile() async {
        let fake = FakeKanban()
        var item = Hermes_Board_V1_Item()
        item.id = "RB-21"
        fake.createResult.outcome = .done(item)
        let model = QuickAddModel(projectId: "p1", boardId: "b-research", service: fake)
        XCTAssertFalse(model.canSave, "a title first")
        model.title = " Import breaks "
        model.type = .bug
        model.add(name: "shot.png", data: Data(repeating: 1, count: 600_000))
        model.links = ["https://example.com/spec"]
        XCTAssertTrue(model.canSave)

        let saved = await model.save()
        XCTAssertEqual(saved, QuickAddModel.Saved(itemId: "RB-21", missing: []))
        let create = fake.creates.first
        XCTAssertEqual(create?.title, "Import breaks")
        XCTAssertEqual(create?.type, .bug)
        XCTAssertEqual(create?.boardID, "b-research")
        XCTAssertEqual(create?.draft, true)
        XCTAssertFalse(create?.hasDescription_p ?? true, "left out, so the template fills it")
        XCTAssertEqual(create?.labels, [], "no labels picked")
        XCTAssertEqual(create?.platforms, [], "never platforms")
        XCTAssertEqual(fake.uploads.map(\.offset), [0, 524_288])
        XCTAssertEqual(Set(fake.uploads.map(\.uploadID)).count, 1, "one upload id for the file's chunks")
        XCTAssertEqual(fake.uploads.first?.total, 600_000)
        XCTAssertEqual(fake.attaches.first?.uploadID, fake.uploads.first?.uploadID)
        XCTAssertEqual(fake.attaches.last?.url, "https://example.com/spec")
    }

    func testAFileTheHomeWontTakeBlocksSavingAndAFailedAttachIsNamed() async {
        let fake = FakeKanban()
        var item = Hermes_Board_V1_Item()
        item.id = "RB-22"
        fake.createResult.outcome = .done(item)
        let model = QuickAddModel(projectId: "p1", boardId: "", service: fake)
        model.title = "Logs"
        model.add(name: "dump.zip", data: Data([1, 2]))
        XCTAssertNotNil(model.files.first?.problem)
        XCTAssertFalse(model.canSave)
        model.remove(model.files[0].id)
        model.add(name: "app.log", data: Data([1, 2]))
        fake.attachError = DaemonError(code: "invalid_request", message: "too large for this item")
        let saved = await model.save()
        XCTAssertEqual(saved?.itemId, "RB-22", "the draft is kept")
        XCTAssertEqual(saved?.missing, ["app.log: too large for this item"])
        XCTAssertFalse(fake.creates.first?.hasBoardID ?? true, "no board named: the default one")
    }

    func testQuickAddSendsTheLabelsPickedFromTheBoardsGroupsAndNoPlatforms() async {
        let fake = FakeKanban()
        var item = Hermes_Board_V1_Item()
        item.id = "RB-23"
        fake.createResult.outcome = .done(item)
        let model = QuickAddModel(projectId: "p1", boardId: "b-main", service: fake)
        model.title = "Scaling"
        model.toggle(label: "platform:ios")
        model.toggle(label: "course:main")
        model.toggle(label: "platform:desktop")
        model.toggle(label: "platform:desktop")
        XCTAssertEqual(model.labels, ["platform:ios", "course:main"])
        // Another board: only what its groups offer stays.
        model.boardId = "b-research"
        model.keepLabels(offered: [LabelGroupView(name: "course", values: ["main", "dessert"])])
        XCTAssertEqual(model.labels, ["course:main"])
        _ = await model.save()
        XCTAssertEqual(fake.creates.first?.labels, ["course:main"])
        XCTAssertEqual(fake.creates.first?.platforms, [], "a 0.19 home reads platforms from labels")
        XCTAssertEqual(fake.creates.first?.boardID, "b-research")
    }

    func testTheFilterFollowsTheBoardOnScreen() async throws {
        let fake = FakeKanban()
        var snapshot = try KanbanLogicTests.snapshot019()
        snapshot.cards[0].labels = ["platform:ios"]
        snapshot.cards[1].labels = ["topic:flour"]
        fake.snapshots = [snapshot]
        let model = BoardModel(projectId: "p1", service: fake, memory: BoardMemory(defaults: defaults))
        await model.start()
        model.filter.toggle("platform:ios")
        XCTAssertEqual(model.state?.cards(in: "doing", matching: model.filter).map(\.id), ["RB-1"])
        model.select(board: "b-research")
        XCTAssertFalse(model.filter.isOn, "Research offers no platform group: the filter goes")
    }

    func testARefusedDraftSaysWhy() async {
        let fake = FakeKanban()
        var refused = Hermes_Board_V1_MoveRefused()
        refused.unmet = [unmet("new.title", "It needs a title.")]
        fake.createResult.outcome = .refused(refused)
        let model = QuickAddModel(projectId: "p1", boardId: "", service: fake)
        model.title = "x"
        let saved = await model.save()
        XCTAssertNil(saved)
        XCTAssertEqual(model.failure, "It needs a title.")
    }

    // MARK: Draft review

    private func revision(_ id: Int64, by actor: String) -> DraftRevision {
        var r = DraftRevision()
        r.id = id
        r.actor = actor
        r.field = "title"
        r.from = "a\(id)"
        r.to = "b\(id)"
        return r
    }

    func testTheReviewMarksSeenOnlyWhatABotChangedAndFinalizeMarksItToo() async {
        let fake = FakeKanban()
        fake.changes.revisions = [revision(1, by: "device:d1"), revision(2, by: "bot:b-lead")]
        fake.changes.seen = 1
        let model = DraftModel(itemId: "RB-9", service: fake)
        await model.load()
        XCTAssertEqual(model.newestFirst.map(\.id), [2, 1])
        XCTAssertTrue(model.isNew(model.revisions[1]))
        XCTAssertFalse(model.isNew(model.revisions[0]), "the owner's own change isn't news")
        XCTAssertEqual(fake.changeCalls, [false])

        fake.finalizeResult.outcome = .done(Hermes_Board_V1_Item())
        let outcome = await model.finalize(version: 6, column: "todo")
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(fake.changeCalls, [false, true], "finalize marks the changes seen")
        XCTAssertEqual(model.seen, 2)
        XCTAssertEqual(fake.finalized.first?.1, "todo")

        await model.markSeen()
        XCTAssertEqual(fake.changeCalls, [false, true], "nothing new: not asked again")
    }

    func testUndoAsksTheHomeForAnyChangeAndSaysARefusal() async throws {
        let fake = FakeKanban()
        // Two changes to the title, an attachment, and the owner's own: each has its Undo.
        fake.changes.revisions = [revision(1, by: "bot:b-lead"), revision(2, by: "bot:b-lead"), revision(3, by: "device:d1")]
        let model = DraftModel(itemId: "RB-9", service: fake)
        await model.load()
        fake.undoResult.outcome = .done(Hermes_Board_V1_Item())
        try await model.undo(model.revisions[0], version: 4)
        XCTAssertEqual(fake.undos.first?.version, 4)
        XCTAssertEqual(fake.undos.first?.revision, 1, "an earlier change too, not only a field's latest")
        XCTAssertEqual(model.undone, [1])
        XCTAssertEqual(fake.changeCalls, [false, false], "the changes are read again")

        var refused = Hermes_Board_V1_MoveRefused()
        refused.unmet = [unmet("draft.live", "RB-9 is not a draft any more; edit it instead.")]
        fake.undoResult.outcome = .refused(refused)
        do {
            try await model.undo(model.revisions[2], version: 5)
            XCTFail("refused")
        } catch {
            XCTAssertEqual(error.localizedDescription, "RB-9 is not a draft any more; edit it instead.")
        }
        fake.undoResult.outcome = .conflict(Hermes_Board_V1_Item())
        do {
            try await model.undo(model.revisions[1], version: 5)
            XCTFail("conflict")
        } catch {
            XCTAssertEqual(error.localizedDescription, "RB-9 changed meanwhile. Look again, then undo.")
        }
        XCTAssertEqual(model.undone, [1], "only what was taken back")

        fake.discardResult.outcome = .conflict(Hermes_Board_V1_Item())
        let discarded = await model.discard(version: 4, reason: "dup")
        XCTAssertFalse(discarded)
        XCTAssertEqual(model.failure, "RB-9 changed meanwhile. Look again, then discard.")
    }
}
