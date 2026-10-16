import Foundation

// Board glance (0.20, phase 1): the Projects tab shows each project as its
// board, its fleet and the one thing it needs from you. Needs you is a filter
// on that tab, not a tab of its own (BG-Rules §3). The rules live here, apart
// from the views, so the tests hold them.

typealias HomeColumn = Flotilla_Home_V1_ColumnCount

/// The app's tabs (BG-Rules, decided 16 Oct): Projects · Chat · Settings.
enum AppTab: Hashable {
    case projects, chat, settings
}

/// The Projects tab's filter chips (§3).
enum HomeFilter: String, CaseIterable, Identifiable {
    case all, needsYou, working, quiet

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .needsYou: "Needs you"
        case .working: "Working"
        case .quiet: "Quiet"
        }
    }
}

/// Where a project sits on the tab, top to bottom (§3).
enum HomeGroup: Int, Comparable {
    case needsYou, working, idle, quiet

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// The one state pill on a card (§2): a glyph and a word.
enum ProjectState: Equatable {
    case readOnly, needsYou(Int), setUp, working, idle

    var glyph: String {
        switch self {
        case .readOnly: "⌁"
        case .needsYou: "!"
        case .setUp: "+"
        case .working: "◔"
        case .idle: "○"
        }
    }

    var word: String {
        switch self {
        case .readOnly: "Read only"
        case .needsYou: "Needs you"
        case .setUp: "Set up"
        case .working: "Working"
        case .idle: "Idle"
        }
    }

    /// "! Needs you · 5"; one thing waiting needs no number.
    var pill: String {
        if case .needsYou(let count) = self, count > 1 { return "\(glyph) \(word) · \(count)" }
        return "\(glyph) \(word)"
    }

    /// The pill as VoiceOver says it: the word, never the glyph.
    var spoken: String {
        if case .needsYou(let count) = self, count > 1 { return "\(word), \(count) things" }
        return word
    }
}

enum BoardGlance {
    /// Nothing to do for this long: a slim row under Quiet.
    static let quietAfter: TimeInterval = 24 * 60 * 60
    /// Filter chips from this many projects; with fewer, what needs you already leads.
    static let filtersFrom = 5

    /// The board's home answers only from what it last sent (§5): the card
    /// shows that and its actions wait. A linked computer away elsewhere leaves
    /// the card as it is, with a line saying so.
    static func isReadOnly(_ card: HomeCard) -> Bool {
        let row = card.row
        guard !card.offline.isEmpty else { return false }
        if !row.boardHome.isEmpty { return card.offline.contains(row.boardHome) }
        let members = Set(row.members.map(\.daemonID))
        return !members.isEmpty && members.isSubset(of: card.offline)
    }

    /// Read only, then Needs you, then Set up (no board, no bots), Working, Idle.
    static func state(_ card: HomeCard) -> ProjectState {
        let row = card.row
        if isReadOnly(card) { return .readOnly }
        if row.attention.count > 0 { return .needsYou(Int(row.attention.count)) }
        if row.columns.isEmpty, row.bots == 0 { return .setUp }
        if row.botsWorking > 0 { return .working }
        return .idle
    }

    /// Nothing waits, nothing runs, and nothing happened for a day. A project
    /// that never said when it was last active, or is still being set up,
    /// stays a full card.
    static func isQuiet(_ row: HomeRow, now: Date) -> Bool {
        guard row.attention.count == 0, row.botsWorking == 0, row.botsWaiting == 0, row.hasLastActivityAt else { return false }
        if row.columns.isEmpty, row.bots == 0 { return false }
        return now.timeIntervalSince(row.lastActivityAt.date) >= quietAfter
    }

    static func group(_ card: HomeCard, now: Date = Date()) -> HomeGroup {
        let row = card.row
        if row.attention.count > 0 { return .needsYou }
        if row.botsWorking > 0 { return .working }
        if isQuiet(row, now: now) { return .quiet }
        return .idle
    }

    /// Needs you first, a stopped bot's project ahead (§3), then the home's
    /// rank (score, then the oldest ask); then Working, the rest and Quiet,
    /// each pinned first and then by name, so cards stay put while bots work.
    static func ordered(_ cards: [HomeCard], now: Date = Date()) -> [HomeCard] {
        let groups = cards.map { group($0, now: now) }
        let stopped = cards.map { ($0.row.attention.byKind["bot_stopped"] ?? 0) > 0 }
        return cards.indices.sorted { a, b in
            if groups[a] != groups[b] { return groups[a] < groups[b] }
            if groups[a] == .needsYou, stopped[a] != stopped[b] { return stopped[a] }
            if groups[a] != .needsYou {
                let (ra, rb) = (cards[a].row, cards[b].row)
                if ra.pinned != rb.pinned { return ra.pinned }
                let order = ra.name.localizedStandardCompare(rb.name)
                if order != .orderedSame { return order == .orderedAscending }
            }
            return a < b
        }.map { cards[$0] }
    }

    static func matches(_ card: HomeCard, _ filter: HomeFilter, now: Date = Date()) -> Bool {
        switch filter {
        case .all: true
        case .needsYou: group(card, now: now) == .needsYou
        case .working: group(card, now: now) == .working
        case .quiet: group(card, now: now) == .quiet
        }
    }

    /// Each chip's number: All counts every project, the others their group.
    static func counts(_ cards: [HomeCard], now: Date = Date()) -> [HomeFilter: Int] {
        Dictionary(uniqueKeysWithValues: HomeFilter.allCases.map { filter in
            (filter, cards.filter { matches($0, filter, now: now) }.count)
        })
    }

    /// The chips show from five projects, and whenever a filter other than All
    /// is on, so it can be turned off again.
    static func showsFilters(projects: Int, filter: HomeFilter) -> Bool {
        projects >= filtersFrom || filter != .all
    }
}

// MARK: Mini board

/// One segment of a card's mini board (§4).
struct BoardSegment: Equatable {
    /// Lighter to darker in board order, so columns differ in more than hue.
    enum Shade: Equatable {
        case todo, ready, doing, review, verify, done, cancelled, more
    }

    let name: String
    let count: Int
    let shade: Shade
    /// The columns it stands for: one, or several folded into "+N more".
    var columns = 1
}

enum MiniBoard {
    static let maxSegments = 5

    static func shade(_ column: HomeColumn, at index: Int, of total: Int) -> BoardSegment.Shade {
        // A custom board's Review is an active column like Doing; the
        // presets name it `review`, and it is the owner's (§4).
        if column.key == "review" { return .review }
        return switch column.category.lowercased() {
        case "inbox": .todo
        case "ready": .ready
        case "doing", "deploying": .doing
        case "review": .review
        case "verify", "approval": .verify
        case "done": .done
        case "cancelled": .cancelled
        // A category this app doesn't know: by position, first to last.
        default: index == total - 1 ? .done : index == 0 ? .todo : .doing
        }
    }

    /// Every column in board order, up to five. A board with more keeps Done
    /// last, the owner's Review, Doing and its first column in sight, and folds
    /// the rest into one "+N more" just before Done.
    static func segments(_ columns: [HomeColumn]) -> [BoardSegment] {
        // Hidden columns (a preset's Cancelled) are left out (§4).
        let columns = columns.filter { !$0.hidden }
        let all = columns.enumerated().map { index, column in
            BoardSegment(name: column.name, count: Int(column.count), shade: shade(column, at: index, of: columns.count))
        }
        guard all.count > maxSegments else { return all }
        let doneIndex = all.lastIndex { $0.shade == .done } ?? all.count - 1
        let rest = all.indices.filter { $0 != doneIndex }
        func priority(_ index: Int) -> Int {
            switch columns[index].category.lowercased() {
            case "review": 0
            case "doing": 1
            default: index == rest.first ? 2 : 3
            }
        }
        let kept = Set(rest.sorted { (priority($0), $0) < (priority($1), $1) }.prefix(maxSegments - 2))
        let folded = rest.filter { !kept.contains($0) }
        var shown = rest.filter(kept.contains).map { all[$0] }
        shown.append(BoardSegment(name: "+\(folded.count) more", count: folded.reduce(0) { $0 + all[$1].count },
                                  shade: .more, columns: folded.count))
        shown.append(all[doneIndex])
        return shown
    }

    /// "9 To do, 3 Doing, 2 Review, 21 Done", as VoiceOver reads the bar.
    static func spoken(_ segments: [BoardSegment]) -> String {
        guard !segments.isEmpty else { return "No board yet" }
        return segments.map { segment in
            segment.shade == .more ? "\(segment.count) in \(segment.columns) more columns" : "\(segment.count) \(segment.name)"
        }.joined(separator: ", ")
    }
}

// MARK: Words

enum GlanceWords {
    /// "2 working · 12 idle", "1 working · 1 waiting · 3 idle", "No bots yet".
    static func fleet(_ row: HomeRow, readOnly: Bool = false) -> String {
        guard row.bots > 0 else { return "No bots yet" }
        if readOnly { return "\(row.bots) bot\(row.bots == 1 ? "" : "s") · status unknown" }
        if !row.botList.isEmpty { return FleetCounts(row.botList, total: Int(row.bots)).words }
        let (working, waiting) = (Int(row.botsWorking), Int(row.botsWaiting))
        let idle = max(0, Int(row.bots) - working - waiting)
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if idle > 0 || parts.isEmpty { parts.append("\(idle) idle") }
        return parts.joined(separator: " · ")
    }

    /// The fleet as a sentence, for large text and VoiceOver: "2 bots working, 12 idle."
    static func fleetSentence(_ row: HomeRow, readOnly: Bool = false) -> String {
        guard row.bots > 0 else { return "No bots yet." }
        let bots = "\(row.bots) bot\(row.bots == 1 ? "" : "s")"
        if readOnly { return "\(bots), status unknown." }
        if !row.botList.isEmpty { return FleetCounts(row.botList, total: Int(row.bots)).sentence(bots: Int(row.bots)) }
        let (working, waiting) = (Int(row.botsWorking), Int(row.botsWaiting))
        let idle = max(0, Int(row.bots) - working - waiting)
        if working == 0, waiting == 0 { return "\(bots), all idle." }
        var parts: [String] = []
        if working > 0 { parts.append("\(working) bot\(working == 1 ? "" : "s") working") }
        if waiting > 0 { parts.append(parts.isEmpty ? "\(waiting) bot\(waiting == 1 ? "" : "s") waiting" : "\(waiting) waiting") }
        if idle > 0 { parts.append("\(idle) idle") }
        return parts.joined(separator: ", ") + "."
    }

    /// How long ago, in a slim row's room: "5 min", "3 h", "3 d", "2 w", "1 mo", "1 y".
    static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60), hours = Int(seconds / 3600), days = Int(seconds / 86_400)
        if minutes < 1 { return "now" }
        if hours < 1 { return "\(minutes) min" }
        if days < 1 { return "\(hours) h" }
        if days < 7 { return "\(days) d" }
        if days < 30 { return "\(days / 7) w" }
        if days < 365 { return "\(days / 30) mo" }
        return "\(days / 365) y"
    }

    /// A quiet project's row: "16 cards · 3 d".
    static func quietMeta(_ row: HomeRow, now: Date = Date()) -> String {
        let cards = row.columns.reduce(0) { $0 + Int($1.count) }
        var parts = ["\(cards) card\(cards == 1 ? "" : "s")"]
        if row.hasLastActivityAt { parts.append(age(row.lastActivityAt.date, now: now)) }
        return parts.joined(separator: " · ")
    }

    /// "imac is offline", for the line a card shows while a computer is away.
    static func offline(_ card: HomeCard) -> String? {
        guard !card.staleNames.isEmpty else { return nil }
        let names = ListFormatter.localizedString(byJoining: card.staleNames)
        return "\(names) \(card.staleNames.count > 1 ? "are" : "is") offline"
    }

    /// "Last seen 10:42 · board as of then".
    static func lastSeen(_ card: HomeCard, readOnly: Bool) -> String? {
        // When the computer was last seen, from 0.20; before, when it last answered.
        let seen = GlanceFleet.lastSeen(card.row, among: card.offline) ?? card.staleSince
        guard let since = seen else { return readOnly ? "Showing its board as last seen" : nil }
        let time = "Last seen \(since.formatted(date: .omitted, time: .shortened))"
        return readOnly ? "\(time) · board as of then" : time
    }

    /// The line under the tab's title: "7 projects · 2 things need you".
    static func summary(projects: Int, needs: Int, working: Int, offline: Int) -> String {
        var parts = ["\(projects) project\(projects == 1 ? "" : "s")"]
        if needs > 0 {
            parts.append("\(needs) thing\(needs == 1 ? " needs" : "s need") you")
        } else if working > 0 {
            parts.append("\(working) bot\(working == 1 ? "" : "s") working")
        }
        if offline > 0 { parts.append("\(offline) computer\(offline == 1 ? "" : "s") offline") }
        return parts.joined(separator: " · ")
    }

    /// A project's tile: two letters, "Ph" for PhD, "RB" for Recipe Box,
    /// "Ta" for Tax 2026 (words of letters make the initials).
    static func monogram(_ name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }
        let lettered = words.filter { $0.first?.isLetter == true }
        if lettered.count > 1 { return lettered.prefix(2).map { $0.prefix(1).uppercased() }.joined() }
        guard let first = lettered.first ?? words.first else { return "?" }
        return first.prefix(1).uppercased() + first.dropFirst().prefix(1).lowercased()
    }

    /// The same project gets the same colour on every launch and every
    /// device: FNV-1a over its id, not Swift's per-launch hash.
    static func paletteIndex(_ seed: String, count: Int) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in seed.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(max(count, 1)))
    }
}

// MARK: Asks

/// The one action an ask offers (§1), named for what it opens.
enum AskAction {
    static func label(_ row: HomeAttentionRow, opens destination: NeedsDestination) -> String {
        // Something the phone can only explain, not do: say so.
        if case .note = destination { return "Details" }
        switch row.kind {
        case .botStopped: return StoppedBot.restarts(row) ? "Restart" : "Details"
        case .ownerQuestion: return "Answer"
        case .decision: return "Decide"
        case .permissionPrompt: return "Approve"
        case .releaseAwaiting, .draftUpdated, .prReview: return "Review"
        default: return "Open"
        }
    }
}

extension NeedsDestination {
    /// The computer its screen talks to; nil for a note.
    var computerId: String? {
        switch self {
        case .decision(let id, _), .bot(let id, _, _), .item(let id, _), .reply(let id, _, _), .release(let id, _): id
        case .note: nil
        }
    }
}

// MARK: Routes

/// Where something that used to open the Needs you tab lands now (0.20):
/// Projects, with the Needs you filter on and, when there is one, its screen
/// pushed on top.
struct HomeLanding: Equatable {
    var tab: AppTab = .projects
    /// Nil leaves the filter as it is.
    var filter: HomeFilter? = .needsYou
    var push: NeedsDestination?
}

enum HomeRoute {
    /// ⌘⇧N, "See all in Needs you", "Open Needs you to see what waits for you."
    static let needsYou = HomeLanding()

    /// A decision's notification or toast.
    static func decision(_ id: String, on computerId: String) -> HomeLanding {
        HomeLanding(push: .decision(computerId: computerId, decisionId: id))
    }

    /// A permission prompt whose bot the notification didn't name: its bot
    /// once the phone knows it; a terminal command is answered only on its
    /// own computer (H-108), and its read-only card heads the tab.
    static func permissionCard(on computerId: String, botId: String?) -> HomeLanding {
        guard let botId, botId != "terminal" else { return needsYou }
        return HomeLanding(push: .bot(computerId: computerId, botId: botId, chat: false))
    }

    /// A release to look at (QA captures: -releaseStub).
    static func release(_ id: String, on computerId: String) -> HomeLanding {
        HomeLanding(push: .release(computerId: computerId, releaseId: id))
    }

    /// Screenshots of a tab, `-openTab needs|chat|settings`: "needs" still
    /// means what waits for you, so scripts and tests keep their meaning.
    static func tab(named name: String?) -> HomeLanding? {
        switch name {
        case "needs": needsYou
        case "projects": HomeLanding(filter: nil)
        case "chat": HomeLanding(tab: .chat, filter: nil)
        case "settings": HomeLanding(tab: .settings, filter: nil)
        default: nil
        }
    }
}
