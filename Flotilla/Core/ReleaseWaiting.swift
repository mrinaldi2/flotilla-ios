import Foundation

// H-248 (iOS half of H-247, UX-048): what blocks a release that only the owner
// can give. Every release payload carries `owner_blockers` (frozen shape):
// [{kind, id, title, item_id, bot, computer, created_at}], optional values null;
// a missing field means an older service.

/// One thing the release waits on.
struct OwnerBlocker: Identifiable, Equatable {
    enum Kind: String, Equatable {
        /// The owner's ruling on the package (awaiting_owner). id: the release's decision.
        case ruling
        /// An owner action (Run card). id: the action.
        case run
        case decision
        /// A bot's question to the owner. id: the comment.
        case question
        /// A permission request. id: the request.
        case permission

        /// UX-048: ruling → run/decision/permission → question.
        var group: Int {
            switch self {
            case .ruling: 0
            case .run, .decision, .permission: 1
            case .question: 2
            }
        }
    }

    let kind: Kind
    let id: String
    /// Raw text; the copy is written around it (version, reason, title, comment, tool).
    let title: String
    let itemId: String?
    /// A bot id; nil for a ruling.
    let botId: String?
    /// The run target, or the bot's computer for a permission.
    let computer: String?
    let createdAt: Date?

    init?(_ d: JSONDict) {
        guard let kind = Kind(rawValue: d.str("kind")), !d.str("id").isEmpty else { return nil }
        self.kind = kind
        id = d.str("id")
        title = d.str("title")
        itemId = d.optStr("item_id").flatMap { $0.isEmpty ? nil : $0 }
        botId = d.optStr("bot").flatMap { $0.isEmpty ? nil : $0 }
        computer = d.optStr("computer").flatMap { $0.isEmpty ? nil : $0 }
        createdAt = d.date("created_at")
    }

    /// The release's blockers in UX-048's order; nil on a service without the field.
    static func list(_ release: JSONDict) -> [OwnerBlocker]? {
        guard release["owner_blockers"] != nil else { return nil }
        return ordered(release.list("owner_blockers").compactMap(OwnerBlocker.init))
    }

    /// Ruling, then Run cards, decisions and permission requests, then questions;
    /// oldest first within each group.
    static func ordered(_ blockers: [OwnerBlocker]) -> [OwnerBlocker] {
        blockers.enumerated().sorted { a, b in
            if a.element.kind.group != b.element.kind.group { return a.element.kind.group < b.element.kind.group }
            let ta = a.element.createdAt ?? .distantPast, tb = b.element.createdAt ?? .distantPast
            return ta != tb ? ta < tb : a.offset < b.offset
        }.map(\.element)
    }
}

/// What a row's button does (UX-048 §Buttons).
enum BlockerAction: Equatable {
    /// Run without phone support: no button, the row says where to run it.
    case none
    /// Answer a decision: its screen.
    case openDecision(String)
    /// Answer a question: the card, with "Reply to <bot>" on that comment (H-210).
    case reply(itemId: String, commentId: String)
    /// Review a permission request: the bot, with the request on top.
    case reviewPermission(botId: String)
    /// Review… the ruling: the release review on this screen (UX-040).
    case reviewRuling

    static func of(_ blocker: OwnerBlocker) -> BlockerAction {
        switch blocker.kind {
        case .ruling: return .reviewRuling
        case .run: return .none
        case .decision: return .openDecision(blocker.id)
        case .question:
            guard let item = blocker.itemId else { return .none }
            return .reply(itemId: item, commentId: blocker.id)
        case .permission:
            guard let bot = blocker.botId else { return .none }
            return .reviewPermission(botId: bot)
        }
    }

    /// The button's text, also the row's accessibility action.
    var label: String? {
        switch self {
        case .none: nil
        case .openDecision, .reply: "Answer"
        case .reviewPermission: "Review"
        case .reviewRuling: "Review…"
        }
    }
}

/// UX-048's words.
enum WaitingWords {
    static let shown = 3

    /// "▲ Waiting for you · 2"
    static func header(_ count: Int) -> String { "▲ Waiting for you · \(count)" }

    static func more(_ hidden: Int) -> String { "+\(hidden) more" }

    /// The row's title. `bot` is the bot's name, when known.
    static func title(_ blocker: OwnerBlocker, bot: String?) -> String {
        switch blocker.kind {
        case .ruling: "◐ Test \(blocker.title) and rule on it"
        case .decision: "◆ Decide: \(blocker.title)"
        case .question: "? \(bot ?? "A bot") asks: \(blocker.title)"
        case .run: "▶ \(bot ?? "A bot") asks you to run a command on \(blocker.computer ?? "its computer")"
        case .permission: "\(bot ?? "A bot") wants to run \(blocker.title)"
        }
    }

    /// "who · where · time". A Run card: "on H-244 · 25m", then where to run it.
    static func meta(_ blocker: OwnerBlocker, bot: String?, computer: String, now: Date = Date()) -> String {
        if blocker.kind == .run {
            let first = [blocker.itemId.map { "on \($0)" }, blocker.createdAt.map { age($0, now: now) }]
                .compactMap { $0 }.joined(separator: " · ")
            let run = runOn(blocker.computer ?? computer)
            return first.isEmpty ? run : "\(first)\n\(run)"
        }
        let parts = [bot, blocker.computer ?? (computer.isEmpty ? nil : computer),
                     blocker.createdAt?.relative]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    /// "25m", "3h", "2d": how long it has waited.
    static func age(_ date: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 60 { return "\(max(minutes, 1))m" }
        if minutes < 24 * 60 { return "\(minutes / 60)h" }
        return "\(minutes / (24 * 60))d"
    }

    static func runOn(_ computer: String) -> String {
        "Run it on \(computer.isEmpty ? "its computer" : computer), in The Hermes app."
    }

    /// Progress, on a service without owner_blockers.
    static let olderService = "Open Needs you to see what waits for you."

    /// The Projects card's release pill (needs HomeOverview.ReleaseBrief.owner_blocker_count, H-247).
    static func projectsPill(_ version: String) -> String { "◐ \(version) waits for you" }
}

/// A `release_updated` push: that release's owner_blockers changed.
struct ReleaseUpdate: Equatable {
    let releaseId: String
    let id = UUID()
}

/// Progress's first line (UX-048 §3): who the release waits on now, never a raw state.
enum ReleaseNow {
    struct Line: Equatable {
        let text: String
        /// It names an owner item: tapping goes to its row in "Waiting for you".
        let waitsForYou: Bool
    }

    static let platformNames = ["desktop-mac": "Mac", "desktop-win": "Windows", "desktop-linux": "Linux", "ios": "iPhone"]

    /// Released or stopped: no "Now:" line, and no pointer to Needs you.
    static let settled: Set = ["deployed", "rejected", "cancelled", "rolled_back", "held"]

    static func shows(_ release: Release) -> Bool { !settled.contains(release.status) }

    /// A service without owner_blockers can't say what waits for you: point to
    /// Needs you, under the "Now:" line (UX-048, QA-014).
    static func pointsToNeedsYou(_ release: Release) -> Bool { release.ownerBlockers == nil && shows(release) }

    static func line(_ release: Release, botName: (String) -> String? = { _ in nil }) -> Line {
        // Something waits for you: the first owner item.
        if let first = release.ownerBlockers?.first {
            // The ruling names the release itself: no card after it.
            let item = first.kind == .ruling ? "" : (first.itemId.map { " (\($0))" } ?? "")
            return Line(text: "Now: waiting for you to \(ask(first, botName: botName))\(item).", waitsForYou: true)
        }
        // Items not ready yet.
        let open = release.plan.filter { !$0.ready }
        if ["planned", "assembling"].contains(release.status), !open.isEmpty {
            let named = open.prefix(2).map { "\($0.itemId) in \($0.columnName)" }
            let rest = open.count > 2 ? ", +\(open.count - 2)" : ""
            let noun = open.count == 1 ? "item" : "items"
            return Line(text: "Now: \(open.count) \(noun) still in progress (\(named.joined(separator: ", "))\(rest)).", waitsForYou: false)
        }
        // Building.
        if release.status == "assembling" || release.status == "repackaging" {
            let names = release.platforms.map { platformNames[$0] ?? $0 }
            let what = names.isEmpty ? "the packages"
                : "the \(ListFormatter.localizedString(byJoining: names)) package\(names.count == 1 ? "" : "s")"
            return Line(text: "Now: DevOps is building \(what).", waitsForYou: false)
        }
        // Testing.
        if release.status == "built", let next = release.testsRequired.first(where: { !release.testsPassed.contains($0) }) {
            let total = release.testsRequired.count
            return Line(text: "Now: testing on \(next) (\(release.testsPassed.count) of \(total) computer\(total == 1 ? "" : "s")).",
                        waitsForYou: false)
        }
        // Rolling out.
        if ["deploying", "partially_deployed"].contains(release.status), !release.deploysTo.isEmpty {
            let done = Set(release.deployedOn).intersection(release.deploysTo).count
            return Line(text: "Now: rolling out, \(done) of \(release.deploysTo.count) computers updated.", waitsForYou: false)
        }
        return Line(text: "Now: nothing is blocking it.", waitsForYou: false)
    }

    /// What the owner is to do, as a lowercase verb phrase: "run a command on mac".
    static func ask(_ blocker: OwnerBlocker, botName: (String) -> String?) -> String {
        let bot = blocker.botId.flatMap(botName) ?? "a bot"
        switch blocker.kind {
        case .ruling: return "test \(blocker.title) and rule on it"
        case .run: return "run a command on \(blocker.computer ?? "its computer")"
        case .decision: return "decide \(blocker.title)"
        case .question: return "answer \(bot)"
        case .permission: return "review \(blocker.title)"
        }
    }
}
