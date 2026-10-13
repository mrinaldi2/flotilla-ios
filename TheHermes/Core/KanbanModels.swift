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

    @ObservationIgnored private let service: BoardService
    @ObservationIgnored private let memory: BoardMemory
    @ObservationIgnored private var token: UUID?
    /// Pushes that arrived while the snapshot was on its way.
    @ObservationIgnored private var early: [BoardEvent] = []
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var again = false

    init(projectId: String, service: BoardService, memory: BoardMemory = BoardMemory()) {
        self.projectId = projectId
        self.service = service
        self.memory = memory
    }

    /// Starts following the board: listens, then watches.
    func start() async {
        if token == nil {
            token = service.listen(projectId: projectId) { [weak self] event in self?.received(event) }
        }
        await reload()
    }

    func stop() {
        if let token { service.stopListening(projectId: projectId, token) }
        token = nil
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
        } else {
            Task { await reload() }
        }
    }

    /// Shows another board and remembers it for this project.
    func select(board id: String) {
        guard var current = state else { return }
        current.select(id)
        state = current
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
        var move = Hermes_Board_V1_ItemMove()
        move.id = card.id
        move.to = chosen.key
        move.expectedVersion = card.version
        if chosen.needsReason || !reason.trimmed.isEmpty { move.reason = reason.trimmed }
        if chosen.needsOverride { move.overrideReason = overrideReason.trimmed }
        do {
            switch MoveOutcome(try await service.move(move)) {
            case .done:
                refusal = []
                phase = .moved(to: chosen.name)
            case .refused(let unmet):
                refusal = MoveOutcome.lines(unmet)
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
    var type = Hermes_Board_V1_ItemType.feature
    var boardId: String
    var description = ""
    private(set) var files: [File] = []
    var links: [String] = []
    /// "Uploading import-error.png…", while saving.
    private(set) var progress: String?
    private(set) var failure: String?

    @ObservationIgnored private let service: DraftService

    init(projectId: String, boardId: String, service: DraftService) {
        self.projectId = projectId
        self.boardId = boardId
        self.service = service
    }

    func add(name: String, data: Data) { files.append(File(name: name, data: data)) }
    func remove(_ id: UUID) { files.removeAll { $0.id == id } }

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
        var create = Hermes_Board_V1_ItemCreate()
        create.projectID = projectId
        create.type = type
        create.title = title.trimmed
        // Left out, the type's template fills the description.
        if !description.trimmed.isEmpty { create.description_p = description }
        if !boardId.isEmpty { create.boardID = boardId }
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
            var attach = Hermes_Board_V1_ItemAttach()
            attach.id = itemId
            attach.url = link
            do { _ = try await service.attach(attach) } catch { missing.append("\(link): \(error.localizedDescription)") }
        }
        return Saved(itemId: itemId, missing: missing)
    }

    private func upload(_ file: File, to itemId: String) async throws {
        let uploadId = AttachmentRules.uploadId()
        for chunk in AttachmentRules.chunks(file.data) {
            var upload = Hermes_Board_V1_AttachmentUpload()
            upload.itemID = itemId
            upload.uploadID = uploadId
            upload.offset = UInt64(chunk.offset)
            upload.data = chunk.data
            upload.total = UInt64(file.data.count)
            upload.name = file.name
            _ = try await service.upload(upload)
        }
        var attach = Hermes_Board_V1_ItemAttach()
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

    private func take(_ changes: Hermes_Board_V1_DraftChanges) {
        // Asked from the first revision, so the reply is the whole list.
        revisions = changes.revisions.sorted { $0.id < $1.id }
        seen = changes.seen
    }

    /// Puts one change back; the caller reloads the item.
    func undo(_ revision: DraftRevision, detail: BoardItemDetail) async throws {
        guard let undo = DraftUndo.of(revision, among: revisions, detail: detail) else { return }
        switch undo {
        case .update(let update):
            if case .conflict? = try await service.updateItem(update).outcome {
                throw DaemonError(code: "conflict", message: "\(itemId) changed meanwhile. Look again, then undo.")
            }
        case .detach(let attachmentId):
            _ = try await service.detach(itemId: itemId, attachmentId: attachmentId)
        case .unlink(let unlink):
            _ = try await service.unlink(unlink)
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
