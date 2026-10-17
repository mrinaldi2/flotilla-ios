import Foundation

// The 0.19 kanban on the phone (K7): several boards per project, live
// pushes, moves with the daemon's own refusals, drafts and their revisions.
// Everything here is plain data and words, so the tests read it without a
// daemon. A 0.18 home sends no `boards`: the project then has one board,
// every column and card is on it, and drafts and attachments don't exist.

typealias KanbanBoard = Flotilla_Board_V1_Board
typealias BoardColumnRow = Flotilla_Board_V1_BoardColumn
typealias ItemAttachment = Flotilla_Board_V1_ItemAttachment
typealias DraftRevision = Flotilla_Board_V1_DraftRevision
typealias BoardEvent = Flotilla_Board_V1_BoardEvent
typealias BoardUnmet = Flotilla_Board_V1_Unmet

extension Flotilla_Board_V1_BoardColumn {
    /// What the column means to the board. A 0.18 home sends no kind, so it
    /// comes from the category, as the daemon's own migration maps it.
    var effectiveKind: Flotilla_Board_V1_ColumnKind {
        if kind != .unspecified { return kind }
        switch category {
        case .inbox, .ready: return .open
        case .done: return .done
        case .cancelled: return .cancelled
        case .doing, .review, .verify, .approval, .deploying: return .active
        case .unspecified, .UNRECOGNIZED: return .open
        }
    }

    /// "Doing 2/3", "To do 4".
    func chip(count: Int) -> String {
        hasWipLimit ? "\(name) \(count)/\(wipLimit)" : "\(name) \(count)"
    }
}

/// A column kind in the glossary's words: a glyph and a word, never colour alone.
enum ColumnKindWords {
    static func chip(_ kind: Flotilla_Board_V1_ColumnKind) -> String {
        switch kind {
        case .active: "◐ active"
        case .done: "● done"
        case .cancelled: "⊘ cancelled"
        case .open, .unspecified, .UNRECOGNIZED: "○ open"
        }
    }
}

// MARK: A project's boards

/// A project's boards as the phone shows them: the one picked, its columns
/// and cards, and the project's drafts. It follows `board_event` pushes and
/// says when it can't, so the caller refetches.
struct BoardState: Equatable {
    var snapshot: BoardSnapshot
    /// The board on screen; empty for a 0.18 home's single board.
    var selected: String

    init(snapshot: BoardSnapshot, remembered: String? = nil) {
        self.snapshot = snapshot
        selected = Self.choose(remembered: remembered, in: snapshot)
    }

    /// The daemon names its boards (0.19): the picker, drafts and quick add apply.
    var hasBoards: Bool { !snapshot.boards.isEmpty }

    /// Open boards, the default first, then by their order.
    var boards: [KanbanBoard] {
        snapshot.boards.filter { !$0.archived }.sorted { a, b in
            if a.isDefault != b.isDefault { return a.isDefault }
            return a.ord < b.ord
        }
    }

    var board: KanbanBoard? { boards.first { $0.id == selected } }

    /// The remembered board if it is still open, else the default one.
    static func choose(remembered: String?, in snapshot: BoardSnapshot) -> String {
        let open = snapshot.boards.filter { !$0.archived }
        if let remembered, open.contains(where: { $0.id == remembered }) { return remembered }
        return open.first(where: \.isDefault)?.id ?? open.min { $0.ord < $1.ord }?.id ?? ""
    }

    /// Picks another board, if there is one by that id.
    mutating func select(_ id: String) {
        if boards.contains(where: { $0.id == id }) { selected = id }
    }

    private func onBoard(_ boardId: String) -> Bool {
        selected.isEmpty || boardId.isEmpty || boardId == selected
    }

    /// Every column of the board on screen, hidden ones included, in board order.
    var allColumns: [BoardColumnRow] {
        snapshot.columns.filter { onBoard($0.boardID) }.sorted { $0.ord < $1.ord }
    }

    /// The columns the chips show.
    var columns: [BoardColumnRow] { allColumns.filter(\.visible) }

    /// A column's cards in rank order.
    func cards(in column: String) -> [BoardCard] {
        snapshot.cards.filter { $0.columnKey == column && !$0.draft && onBoard($0.boardID) }
            .sorted { $0.rank < $1.rank }
    }

    /// The project's open drafts, newest id last; the tray shows them all.
    var drafts: [BoardCard] { snapshot.drafts.filter(\.draft) }

    /// The board a card is on, named when the project has more than one.
    func boardName(of card: BoardCard) -> String? {
        guard boards.count > 1 else { return nil }
        return snapshot.boards.first { $0.id == card.boardID }?.name
    }

    /// Where a draft goes by default: the board's first open column.
    var firstOpenColumn: BoardColumnRow? {
        allColumns.first { $0.effectiveKind == .open && $0.visible } ?? allColumns.first { $0.effectiveKind == .open }
    }

    /// The column a list opens on: the first one in progress, else the first.
    var startColumn: String {
        columns.first { $0.effectiveKind == .active }?.key ?? columns.first?.key ?? ""
    }

    /// Applies one push. False when the board must be read again: a gap in
    /// the sequence (or a lower number: the daemon restarted), a structure
    /// or settings change, a resync, or a card the daemon couldn't read back.
    mutating func apply(_ event: BoardEvent) -> Bool {
        guard event.seq == snapshot.seq + 1 else { return false }
        switch event.kind {
        case .itemUpserted, .itemMoved:
            guard event.hasCard else { return false }
            upsert(event.card)
        case .itemRemoved:
            snapshot.cards.removeAll { $0.id == event.itemID }
            snapshot.drafts.removeAll { $0.id == event.itemID }
        case .draftChanged:
            if event.hasCard, event.card.draft {
                if let index = snapshot.drafts.firstIndex(where: { $0.id == event.card.id }) {
                    snapshot.drafts[index] = event.card
                } else {
                    snapshot.drafts.append(event.card)
                }
            } else {
                // Finalized or discarded: off the tray (a finalized one also comes as an upsert).
                snapshot.drafts.removeAll { $0.id == event.itemID }
            }
        case .columnsChanged, .settingsChanged, .resync, .unspecified, .UNRECOGNIZED:
            return false
        }
        snapshot.seq = event.seq
        return true
    }

    private mutating func upsert(_ card: BoardCard) {
        if card.draft {
            if let index = snapshot.drafts.firstIndex(where: { $0.id == card.id }) { snapshot.drafts[index] = card } else { snapshot.drafts.append(card) }
            return
        }
        snapshot.drafts.removeAll { $0.id == card.id }
        if let index = snapshot.cards.firstIndex(where: { $0.id == card.id }) {
            snapshot.cards[index] = card
        } else {
            snapshot.cards.append(card)
        }
    }
}

/// The board picked per project, kept between launches (apps doc: "remembers
/// the last board per project").
struct BoardMemory {
    var defaults: UserDefaults = .standard

    private func key(_ projectId: String) -> String { "kanban.board.\(projectId)" }
    func board(for projectId: String) -> String? { defaults.string(forKey: key(projectId)) }
    func remember(_ boardId: String, for projectId: String) {
        guard !boardId.isEmpty else { return }
        defaults.set(boardId, forKey: key(projectId))
    }
}

// MARK: Moving a card

/// One column a card could go to, with what the daemon says stands in the way.
struct MoveOption: Identifiable, Equatable {
    let key: String
    let name: String
    let visible: Bool
    let unmet: [BoardUnmet]

    var id: String { key }
    /// The move needs a reason (a rework, a cancel).
    var needsReason: Bool { unmet.contains { $0.code == MoveOption.reasonCode } }
    /// The column is at its WIP limit: the owner may go past it with a reason.
    var needsOverride: Bool { unmet.contains { $0.code == MoveOption.wipCode } }
    /// What no field here can answer: the move is refused as it stands.
    var refusals: [BoardUnmet] { unmet.filter { ![MoveOption.reasonCode, MoveOption.wipCode].contains($0.code) } }
    var allowed: Bool { refusals.isEmpty }

    static let reasonCode = "reason.required"
    static let wipCode = "wip.full"

    /// The board's columns but the card's own, in board order, each with its
    /// unmet guards from `item_move_check`. A column the check didn't name is
    /// on another board and left out.
    static func options(_ check: Flotilla_Board_V1_MoveCheck, columns: [BoardColumnRow], from current: String) -> [MoveOption] {
        let checked = Dictionary(check.columns.map { ($0.columnKey, $0.unmet) }, uniquingKeysWith: { first, _ in first })
        return columns.compactMap { column in
            guard column.key != current, let unmet = checked[column.key] else { return nil }
            return MoveOption(key: column.key, name: column.name, visible: column.visible, unmet: unmet)
        }
    }

    /// "✓ Can move", "✎ Needs a reason", "⛔ 2 rules not met": a glyph and words.
    var verdict: String {
        if !allowed { return refusals.count == 1 ? "⛔ Not allowed" : "⛔ \(refusals.count) rules not met" }
        switch (needsReason, needsOverride) {
        case (true, true): return "✎ Needs a reason and an override"
        case (true, false): return "✎ Needs a reason"
        case (false, true): return "✎ Full: needs an override reason"
        case (false, false): return "✓ Can move"
        }
    }
}

/// How a move or a finalize came out, in words for the sheet.
enum MoveOutcome: Equatable {
    case done
    case refused([BoardUnmet])
    /// The card changed meanwhile: check again.
    case conflict

    init(_ result: Flotilla_Board_V1_MoveResult) {
        switch result.outcome {
        case .done?: self = .done
        case .refused(let refused)?: self = .refused(refused.unmet)
        case .conflict?, nil: self = .conflict
        }
    }

    /// One line per unmet rule, with its fix: "Review needs a PR. Link the PR first."
    static func lines(_ unmet: [BoardUnmet]) -> [String] {
        unmet.map { $0.hasFix && !$0.fix.isEmpty ? "\($0.text) \($0.fix)" : $0.text }
    }
}

// MARK: Drafts

/// Words for a draft's revisions (K4b): who changed what.
enum DraftWords {
    /// "Lead", "You", or "A bot".
    static func author(_ actor: String, botName: (String) -> String?) -> String {
        if actor.hasPrefix("bot:") { return botName(String(actor.dropFirst(4))) ?? "A bot" }
        return "You"
    }

    /// "Title: “Import” → “Import recipes”", "Attached import-error.png".
    static func change(_ r: DraftRevision) -> String {
        let from = r.hasFrom ? r.from : ""
        let to = r.hasTo ? r.to : ""
        switch r.field {
        case "title": return "Title: “\(from)” → “\(to)”"
        case "description": return from.isEmpty ? "Wrote the description" : "Changed the description"
        case "acceptance_criteria":
            let count = to.split(separator: "\n").count
            return count == 0 ? "Removed the acceptance criteria" : "Acceptance criteria: \(count) now"
        case "attachment": return to.isEmpty ? "Removed \(from)" : "Attached \(to)"
        case "link": return to.isEmpty ? "Unlinked \(linkWords(from))" : "Linked \(linkWords(to))"
        case "labels": return to.isEmpty ? "Removed the labels" : "Labels: \(to)"
        case "parent": return to.isEmpty ? "No longer under \(from)" : "Under \(to)"
        case "type", "size", "priority":
            let name = r.field.capitalizedFirst
            return from.isEmpty ? "\(name): \(to)" : (to.isEmpty ? "\(name) cleared" : "\(name): \(from) → \(to)")
        default:
            return "Changed \(r.field.replacingOccurrences(of: "_", with: " "))"
        }
    }

    /// How the daemon stores a link's kind, longest first: "item:blocks" before "item".
    private static let linkKinds = ["item:duplicates", "item:relates", "item:blocks", "decision", "artifact", "meeting",
                                    "branch", "thread", "task", "pr"]

    /// "artifact:specs/RB-20.md" → "specs/RB-20.md".
    private static func linkWords(_ stored: String) -> String {
        let kind = linkKinds.first { stored.hasPrefix("\($0):") }
        return kind.map { String(stored.dropFirst($0.count + 1)) } ?? stored
    }

    /// "3 changes by Lead since you looked": the bots' unseen revisions.
    static func unseenLine(_ revisions: [DraftRevision], seen: Int64, botName: (String) -> String?) -> String? {
        let unseen = revisions.filter { $0.id > seen && $0.actor.hasPrefix("bot:") }
        guard !unseen.isEmpty else { return nil }
        let names = unseen.map { author($0.actor, botName: botName) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let count = unseen.count == 1 ? "1 change" : "\(unseen.count) changes"
        return "\(count) by \(ListFormatter.localizedString(byJoining: names)) since you looked"
    }
}

// MARK: Attachments

/// What the home takes (K4b): the type allowlist and the caps. The home's
/// settings may differ; it refuses what it doesn't take, and the phone shows
/// that too. Checked here first so a wrong file is refused at once.
enum AttachmentRules {
    static let imageCap: Int64 = 10 * 1024 * 1024
    static let fileCap: Int64 = 25 * 1024 * 1024
    static let itemCap: Int64 = 100 * 1024 * 1024
    /// At most this much per `attachment_upload` chunk (the frame cap is 1 MiB).
    static let chunkSize = 512 * 1024
    static let images: Set<String> = ["png", "jpg", "jpeg", "webp", "gif"]
    static let files: Set<String> = ["pdf", "md", "txt", "log"]

    static func ext(_ name: String) -> String { (name as NSString).pathExtension.lowercased() }
    static func isImage(_ name: String) -> Bool { images.contains(ext(name)) }

    /// Why the home would refuse a file of this name and size, or nil.
    static func refusal(name: String, bytes: Int64) -> String? {
        let ext = ext(name)
        if ext == "heic" || ext == "heif" { return "HEIC photos are sent as JPEG; add it again from Photos." }
        guard images.contains(ext) || files.contains(ext) else {
            return "A .\(ext.isEmpty ? "?" : ext) file can't be attached: PNG, JPEG, WebP, GIF, PDF, Markdown, text or log only."
        }
        let cap = images.contains(ext) ? imageCap : fileCap
        if bytes > cap { return "Too large: \(size(bytes)), and the most is \(size(cap))." }
        return nil
    }

    /// Why the files together are too much for one item, or nil.
    static func totalRefusal(_ total: Int64) -> String? {
        total > itemCap ? "Together they are \(size(total)); an item takes at most \(size(itemCap))." : nil
    }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    /// The chunks to send: offsets and slices of at most `chunkSize`.
    static func chunks(_ data: Data, size: Int = chunkSize) -> [(offset: Int, data: Data)] {
        guard !data.isEmpty else { return [] }
        return stride(from: 0, to: data.count, by: size).map { start in
            let lower = data.startIndex + start
            return (start, data.subdata(in: lower..<min(lower + size, data.endIndex)))
        }
    }

    /// An upload id the daemon takes: letters, digits and '-', 1 to 64.
    static func uploadId() -> String { UUID().uuidString.lowercased() }
}

/// An attachment as the item view lists it: "import-error.png · PNG image · 47 KB".
enum AttachmentWords {
    static func line(_ a: ItemAttachment) -> String {
        if a.kind == "doc" { return a.url.isEmpty ? "Project document" : "Link" }
        let type = AttachmentRules.ext(a.name).uppercased()
        let what = a.kind == "image" ? "\(type) image" : (type.isEmpty ? "File" : "\(type) file")
        return "\(what) · \(AttachmentRules.size(Int64(a.bytes)))"
    }

    /// Who added it: "Added by Lead".
    static func addedBy(_ a: ItemAttachment, botName: (String) -> String?) -> String {
        "Added by \(DraftWords.author(a.addedBy, botName: botName))"
    }
}
