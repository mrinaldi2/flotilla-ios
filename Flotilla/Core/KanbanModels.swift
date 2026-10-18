import Foundation
import Observation

// The view models of the phone's board (K7). Each takes a service protocol,
// so the tests drive them with a fake daemon.

/// One project's board on screen: watched, kept current by pushes, read
/// again when a push says it must be or the link comes back.
@MainActor @Observable
final class BoardModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
        /// The service answered that this computer doesn't keep the board.
        case elsewhere
    }

    /// The chip that lists the drafts instead of a column.
    static let draftsTab = "\u{1}drafts"

    let projectId: String
    private(set) var state: BoardState?
    private(set) var phase = Phase.loading
    /// The column (or the drafts tray) on screen.
    var tab = ""
    /// The last move or a refetch failing, said quietly over the board.
    var notice: String?
    /// The labels picked in the filter bar, for the board on screen.
    var filter = LabelFilter()

    @ObservationIgnored private let service: BoardService
    @ObservationIgnored private let memory: BoardMemory
    @ObservationIgnored private var token: UUID?
    /// A home with questions (0.22): their pushes don't carry the card, so a
    /// card's open count is read again from the board when one changes.
    @ObservationIgnored private let questions: QuestionService?
    @ObservationIgnored private var questionToken: UUID?
    /// Pushes that arrived while the snapshot was on its way.
    @ObservationIgnored private var early: [BoardEvent] = []
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var again = false

    init(projectId: String, service: BoardService, memory: BoardMemory = BoardMemory(), questions: QuestionService? = nil) {
        self.projectId = projectId
        self.service = service
        self.memory = memory
        self.questions = questions
    }

    /// Starts following the board: listens, then watches.
    func start() async {
        if token == nil {
            token = service.listen(projectId: projectId) { [weak self] event in self?.received(event) }
        }
        if let questions, questionToken == nil {
            questionToken = await questions.followQuestions(projectId: projectId) { [weak self] change in self?.questionChanged(change) }
        }
        await reload()
    }

    func stop() {
        if let token { service.stopListening(projectId: projectId, token) }
        token = nil
        if let questionToken { questions?.unfollowQuestions(projectId: projectId, questionToken) }
        questionToken = nil
    }

    /// A question on one of the board's cards was asked, answered or dismissed: its count is read again.
    func questionChanged(_ change: QuestionChange) {
        guard change.hasQuestion, change.question.hasItemID,
              state?.snapshot.cards.contains(where: { $0.id == change.question.itemID }) ?? false else { return }
        Task { await reload() }
    }

    /// Reads the board again (`board_watch`, so pushes continue from it). A
    /// reload asked for while one runs runs once more after it.
    func reload() async {
        if loading { again = true; return }
        loading = true
        defer { loading = false }
        repeat {
            again = false
            do {
                let snapshot = try await service.watchBoard(projectId: projectId)
                take(snapshot)
            } catch {
                if state == nil {
                    phase = BoardWords.isElsewhere(error) ? .elsewhere : .failed(error.localizedDescription)
                } else {
                    notice = "Couldn’t refresh the board. \(error.localizedDescription)"
                }
            }
        } while again
    }

    private func take(_ snapshot: BoardSnapshot) {
        let previous = state?.selected
        var fresh = BoardState(snapshot: snapshot, remembered: previous ?? memory.board(for: projectId))
        // Pushes the snapshot already holds are skipped; the rest follow it.
        let pending = early.filter { $0.seq > snapshot.seq }.sorted { $0.seq < $1.seq }
        early = []
        var stale = false
        for event in pending where !fresh.apply(event) { stale = true }
        state = fresh
        phase = .loaded
        notice = nil
        keepFilter(fresh)
        if tab.isEmpty || (tab != Self.draftsTab && !fresh.columns.contains { $0.key == tab }) { tab = fresh.startColumn }
        if tab == Self.draftsTab && !fresh.hasBoards { tab = fresh.startColumn }
        // A push the snapshot couldn't take: read once more.
        if stale { again = true }
    }

    /// A push for this project: applied, or the board is read again.
    func received(_ event: BoardEvent) {
        guard var current = state, !loading else {
            early.append(event)
            return
        }
        if current.apply(event) {
            state = current
            keepFilter(current)
        } else {
            Task { await reload() }
        }
    }

    /// Drops picked labels the board no longer offers (another board, a value
    /// gone); untouched while nothing is picked, so a push redraws nothing more.
    private func keepFilter(_ state: BoardState) {
        guard filter.isOn else { return }
        var kept = filter
        kept.keep(only: state.labelGroups())
        if kept != filter { filter = kept }
    }

    /// Shows another board and remembers it for this project.
    func select(board id: String) {
        guard var current = state else { return }
        current.select(id)
        state = current
        keepFilter(current)
        memory.remember(current.selected, for: projectId)
        if tab != Self.draftsTab { tab = current.startColumn }
    }
}

/// "Move to…": the columns with the daemon's refusals checked first, then
/// the move itself, with a reason or an override only when a rule wants one.
@MainActor @Observable
final class MoveModel {
    enum Phase: Equatable {
        case checking
        case ready
        case sending
        case failed(String)
        case moved(to: String)
    }

    let card: BoardCard
    private(set) var options: [MoveOption] = []
    private(set) var phase = Phase.checking
    var target: String?
    var reason = ""
    var overrideReason = ""
    /// The daemon's answer to the last try, when it refused.
    private(set) var refusal: [String] = []
    /// The last try was refused for want of code research (0.21, `start.research`).
    private(set) var heldForResearch = false

    @ObservationIgnored private let service: BoardService

    init(card: BoardCard, service: BoardService) {
        self.card = card
        self.service = service
    }

    var chosen: MoveOption? { options.first { $0.key == target } }

    /// Whether Move can be pressed: an allowed column, with what it asks for.
    var canMove: Bool {
        guard let chosen, chosen.allowed, phase == .ready else { return false }
        if chosen.needsReason && reason.trimmed.isEmpty { return false }
        if chosen.needsOverride && overrideReason.trimmed.isEmpty { return false }
        return true
    }

    func check(columns: [BoardColumnRow]) async {
        phase = .checking
        do {
            let result = try await service.moveCheck(itemId: card.id)
            options = MoveOption.options(result, columns: columns, from: card.columnKey)
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Sends the move. A refusal or a conflict keeps the sheet open, saying why.
    func move(columns: [BoardColumnRow]) async {
        guard let chosen, canMove else { return }
        phase = .sending
        var move = Flotilla_Board_V1_ItemMove()
        move.id = card.id
        move.to = chosen.key
        move.expectedVersion = card.version
        if chosen.needsReason || !reason.trimmed.isEmpty { move.reason = reason.trimmed }
        if chosen.needsOverride { move.overrideReason = overrideReason.trimmed }
        do {
            switch MoveOutcome(try await service.move(move)) {
            case .done:
                refusal = []
                heldForResearch = false
                phase = .moved(to: chosen.name)
            case .refused(let unmet):
                refusal = MoveOutcome.lines(unmet)
                heldForResearch = unmet.contains { $0.code == CodeResearch.unmetCode }
                phase = .ready
            case .conflict:
                refusal = ["\(card.id) changed meanwhile. The columns are checked again."]
                await check(columns: columns)
            }
        } catch {
            refusal = [error.localizedDescription]
            phase = .ready
        }
    }
}

/// The New item form (+): a draft with its title, type, board, description,
/// files and links. Saving creates the draft, uploads each file in chunks
/// and attaches it.
@MainActor @Observable
final class QuickAddModel {
    struct File: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let data: Data
        /// Why the home won't take it, said on the file at once.
        var problem: String?
        var isImage: Bool { AttachmentRules.isImage(name) }

        init(name: String, data: Data) {
            self.name = name
            self.data = data
            problem = AttachmentRules.refusal(name: name, bytes: Int64(data.count))
        }
    }

    struct Saved: Equatable {
        let itemId: String
        /// Files or links the draft was saved without, and why.
        let missing: [String]
    }

    let projectId: String
    var title = ""
    /// Task on a 0.21 home (`item_types_v2`); Feature on an older one.
    var type: Flotilla_Board_V1_ItemType
    /// The types this home takes, in the picker's order.
    let types: [(Flotilla_Board_V1_ItemType, String)]
    var boardId: String
    /// The plan node the card belongs to (0.21, "Belongs to"); empty for none.
    var planNodeId = ""
    /// The project's plan, when it has one: the nodes a card can belong to.
    private(set) var planNodes: [PlanNode] = []
    var description = ""
    /// Labels picked from the board's groups (`platform:ios`); never platforms.
    private(set) var labels: [String] = []
    private(set) var files: [File] = []
    var links: [String] = []
    /// "Uploading import-error.png…", while saving.
    private(set) var progress: String?
    private(set) var failure: String?

    @ObservationIgnored private let service: DraftService
    @ObservationIgnored private let plan: PlanService?

    /// `itemTypesV2`: the home takes the 0.21 card types. `plan`: the home
    /// serves the plan (`plan_v1`), so a card can belong to a node.
    init(projectId: String, boardId: String, service: DraftService, itemTypesV2: Bool = false, plan: PlanService? = nil) {
        self.projectId = projectId
        self.boardId = boardId
        self.service = service
        self.plan = plan
        types = CardTypes.offered(v2: itemTypesV2)
        type = CardTypes.defaultType(v2: itemTypesV2)
    }

    /// Reads the plan for "Belongs to"; a project without one shows no row.
    func loadPlan() async {
        guard let plan, let tree = try? await plan.planTree(projectId: projectId), tree.enabled else { return }
        planNodes = tree.nodes
    }

    /// Whether "Belongs to" shows: the project plans, and has nodes to pick.
    var plans: Bool { !planNodes.isEmpty }

    /// The nodes a card can belong to, on any board: picking one picks its board.
    var homes: [PlanRow] { PlanOutline.homes(in: planNodes) }

    var planNode: PlanNode? { planNodes.first { $0.id == planNodeId } }

    /// A node picked: its board goes with it.
    func belong(to nodeId: String) {
        planNodeId = nodeId
        if let node = planNode, node.hasBoardID, !node.boardID.isEmpty { boardId = node.boardID }
    }

    /// Another board picked: a node of another board no longer applies.
    func boardChanged() {
        if let node = planNode, node.boardID != boardId { planNodeId = "" }
    }

    func add(name: String, data: Data) { files.append(File(name: name, data: data)) }
    func remove(_ id: UUID) { files.removeAll { $0.id == id } }

    func toggle(label: String) {
        if let index = labels.firstIndex(of: label) { labels.remove(at: index) } else { labels.append(label) }
    }

    /// Another board picked: keeps only the labels its groups offer.
    func keepLabels(offered groups: [LabelGroupView]) {
        let offered = Set(groups.flatMap { group in group.values.map(group.label) })
        labels.removeAll { !offered.contains($0) }
    }

    var totalProblem: String? { AttachmentRules.totalRefusal(files.reduce(0) { $0 + Int64($1.data.count) }) }

    var canSave: Bool {
        !title.trimmed.isEmpty && progress == nil && files.allSatisfy { $0.problem == nil } && totalProblem == nil
    }

    /// Creates the draft, then attaches each file and link. A file that fails
    /// after the draft exists is named in `missing`; the draft is kept.
    func save() async -> Saved? {
        guard canSave else { return nil }
        failure = nil
        progress = "Saving the draft…"
        defer { progress = nil }
        var create = Flotilla_Board_V1_ItemCreate()
        create.projectID = projectId
        create.type = type
        create.title = title.trimmed
        // Left out, the type's template fills the description.
        if !description.trimmed.isEmpty { create.description_p = description }
        if !boardId.isEmpty { create.boardID = boardId }
        create.labels = labels
        if !planNodeId.isEmpty { create.planNodeID = planNodeId }
        create.draft = true
        let itemId: String
        do {
            let result = try await service.createItem(create)
            switch result.outcome {
            case .done(let item)?:
                itemId = item.id
            case .refused(let refused)?:
                failure = MoveOutcome.lines(refused.unmet).joined(separator: "\n")
                return nil
            case .conflict?, nil:
                failure = "The draft wasn’t saved. Try again."
                return nil
            }
        } catch {
            failure = error.localizedDescription
            return nil
        }
        var missing: [String] = []
        for file in files {
            progress = "Uploading \(file.name)…"
            do {
                try await upload(file, to: itemId)
            } catch {
                missing.append("\(file.name): \(error.localizedDescription)")
            }
        }
        for link in links.map(\.trimmed) where !link.isEmpty {
            var attach = Flotilla_Board_V1_ItemAttach()
            attach.id = itemId
            attach.url = link
            do { _ = try await service.attach(attach) } catch { missing.append("\(link): \(error.localizedDescription)") }
        }
        return Saved(itemId: itemId, missing: missing)
    }

    private func upload(_ file: File, to itemId: String) async throws {
        let uploadId = AttachmentRules.uploadId()
        for chunk in AttachmentRules.chunks(file.data) {
            var upload = Flotilla_Board_V1_AttachmentUpload()
            upload.itemID = itemId
            upload.uploadID = uploadId
            upload.offset = UInt64(chunk.offset)
            upload.data = chunk.data
            upload.total = UInt64(file.data.count)
            upload.name = file.name
            _ = try await service.upload(upload)
        }
        var attach = Flotilla_Board_V1_ItemAttach()
        attach.id = itemId
        attach.uploadID = uploadId
        attach.name = file.name
        _ = try await service.attach(attach)
    }
}

/// A draft's review: its revisions, what the owner hasn't seen, per-change
/// Undo, and Finalize or Discard (only the owner, from a paired device).
@MainActor @Observable
final class DraftModel {
    let itemId: String
    private(set) var revisions: [DraftRevision] = []
    private(set) var seen: Int64 = 0
    private(set) var loaded = false
    /// The changes taken back from this screen: "↶ Undone", no second Undo.
    private(set) var undone: Set<Int64> = []
    var failure: String?

    @ObservationIgnored private let service: DraftService

    init(itemId: String, service: DraftService) {
        self.itemId = itemId
        self.service = service
    }

    /// Newest first, for the review list.
    var newestFirst: [DraftRevision] { revisions.reversed() }
    func isNew(_ revision: DraftRevision) -> Bool { revision.id > seen && revision.actor.hasPrefix("bot:") }

    /// Every revision; the owner's "last looked" stays as it is.
    func load() async {
        do {
            take(try await service.draftChanges(itemId: itemId, markSeen: false))
        } catch {
            failure = error.localizedDescription
        }
        loaded = true
    }

    /// The owner looked: clears the draft's Needs you row.
    func markSeen() async {
        guard revisions.contains(where: isNew) else { return }
        do { take(try await service.draftChanges(itemId: itemId, markSeen: true)) } catch { failure = error.localizedDescription }
    }

    private func take(_ changes: Flotilla_Board_V1_DraftChanges) {
        // Asked from the first revision, so the reply is the whole list.
        revisions = changes.revisions.sorted { $0.id < $1.id }
        seen = changes.seen
    }

    /// Takes one change back with `item_draft_undo` (K5), on any change:
    /// the home puts the field back, or removes or restores the attachment
    /// or link, as a revision of the owner's own. The caller reloads the item.
    func undo(_ revision: DraftRevision, version: UInt64) async throws {
        let result = try await service.undo(itemId: itemId, version: version, revision: revision.id)
        switch result.outcome {
        case .done?:
            undone.insert(revision.id)
        case .refused(let refused)?:
            throw DaemonError(code: "refused", message: MoveOutcome.lines(refused.unmet).joined(separator: " "))
        case .conflict?, nil:
            throw DaemonError(code: "conflict", message: "\(itemId) changed meanwhile. Look again, then undo.")
        }
        await load()
    }

    /// Finalize marks the changes seen (apps doc), then puts the draft live.
    func finalize(version: UInt64, column: String?) async -> MoveOutcome? {
        await markSeen()
        do {
            return MoveOutcome(try await service.finalize(itemId: itemId, version: version, column: column))
        } catch {
            failure = error.localizedDescription
            return nil
        }
    }

    func discard(version: UInt64, reason: String) async -> Bool {
        do {
            let result = try await service.discard(itemId: itemId, version: version, reason: reason.trimmed)
            switch result.outcome {
            case .done?: return true
            case .refused(let refused)?: failure = MoveOutcome.lines(refused.unmet).joined(separator: "\n")
            case .conflict?, nil: failure = "\(itemId) changed meanwhile. Look again, then discard."
            }
        } catch {
            failure = error.localizedDescription
        }
        return false
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
