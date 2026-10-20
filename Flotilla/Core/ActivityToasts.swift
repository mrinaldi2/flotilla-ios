import Foundation
import Observation

// Board activity as toasts (0.20, as the desktop since 0.19): what bots, the
// owner on another device and the daemon do on the boards, as a short stack
// that drops from the top anywhere in the app. Notices about one actor and
// one card within `groupWindow` fold into one toast, so a bot that moves a
// card and finishes its turn says so once; at most `maxToasts` show.

typealias BoardActivity = Flotilla_Home_V1_BoardActivity

/// One thing that happened: a glyph and a word, never colour alone.
struct ActivityLine: Equatable {
    let glyph: String
    let word: String
    let detail: String
}

struct ActivityNotice: Equatable {
    /// As history stores it (`bot:<id>`, `user`, `device:<id>`, `daemon`).
    let actor: String
    let actorLabel: String
    let computerId: String
    let projectId: String
    let itemId: String
    let itemTitle: String
    let line: ActivityLine
}

struct ActivityToast: Identifiable, Equatable {
    let id: Int
    let key: String
    let actorLabel: String
    let computerId: String
    let itemId: String
    var itemTitle: String
    var lines: [ActivityLine]
    var updatedAt: Date
}

enum ActivityWords {
    /// Who did it, as a toast names them.
    static func actor(_ actor: String, name: String, botName: (String) -> String?) -> String {
        if actor.hasPrefix("bot:") { return botName(String(actor.dropFirst(4))) ?? (name.isEmpty ? "A bot" : name) }
        if actor == "user" { return "You" }
        if actor.hasPrefix("device:") { return name.isEmpty ? "You, on another device" : "You, on \(name)" }
        return "Automatic"
    }

    private static func joined(_ parts: String...) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The line a `board_activity` push says, or nil for a kind this app doesn't know.
    static func line(_ a: BoardActivity) -> ActivityLine? {
        switch a.kind {
        case .moved:
            return ActivityLine(glyph: "→", word: "Moved", detail: joined("\(a.fromName) → \(a.toName)", a.note))
        case .assigned:
            return a.actor == "bot:\(a.assignee)"
                ? ActivityLine(glyph: "+", word: "Picked up", detail: "")
                : ActivityLine(glyph: "+", word: "Assigned", detail: "to \(a.assigneeName)")
        case .unassigned:
            return ActivityLine(glyph: "−", word: "Unassigned", detail: "")
        case .moveRefused:
            return ActivityLine(glyph: "⊘", word: "Couldn't move", detail: joined("to \(a.toName)", a.unmet.joined(separator: " ")))
        case .draftUpdated:
            return ActivityLine(glyph: "✎", word: "Updated the draft", detail: a.note)
        case .checked:
            return a.assignee.isEmpty
                ? ActivityLine(glyph: "◷", word: "Needs you", detail: a.note)
                : ActivityLine(glyph: "◷", word: "Asked \(a.assigneeName)", detail: a.note)
        default:
            return nil
        }
    }

    /// The notice for a push, or none: the owner's own action here already showed.
    static func notice(_ a: BoardActivity, computerId: String, botName: (String) -> String?) -> ActivityNotice? {
        guard !a.fromThisClient, let line = line(a) else { return nil }
        return ActivityNotice(actor: a.actor, actorLabel: actor(a.actor, name: a.actorName, botName: botName),
                              computerId: computerId, projectId: a.projectID, itemId: a.itemID, itemTitle: a.itemTitle, line: line)
    }
}

/// A turn starting or finishing on a card, from `bot_state` pushes: each
/// bot's running turn and its card, so an approval wait inside a turn isn't
/// a new start. A turn about no card, a chat, says nothing. A turn the
/// owner's answer started (`cause` "answer", 0.22) says it got the answer.
struct TurnTracker {
    private var open: [String: String] = [:]
    private static let inTurn: Set<BotState> = [.working, .waitingForUser, .waitingForApproval]

    mutating func notice(botId: String, state: BotState, itemId: String?, itemTitle: String?,
                         cause: String? = nil, bot: Bot?, computerId: String) -> ActivityNotice? {
        let running = open[botId]
        let turning = Self.inTurn.contains(state)
        let line: ActivityLine
        let item: String
        if turning, running == nil, let itemId {
            open[botId] = itemId
            line = ActivityLine(glyph: "●", word: cause == "answer" ? "Got your answer" : "Started",
                                detail: "working on it")
            item = itemId
        } else if !turning, let ended = itemId ?? running {
            open[botId] = nil
            line = ActivityLine(glyph: "✓", word: "Finished", detail: "a turn")
            item = ended
        } else {
            return nil
        }
        guard let bot else { return nil }
        return ActivityNotice(actor: "bot:\(botId)", actorLabel: bot.name, computerId: computerId,
                              projectId: bot.projectId, itemId: item, itemTitle: itemTitle ?? "", line: line)
    }
}

/// The toasts on screen, across every computer.
@MainActor
@Observable
final class ActivityFeed {
    static let groupWindow: TimeInterval = 10
    static let shownFor: TimeInterval = 8
    static let maxToasts = 3
    static let maxLines = 4
    /// The owner's switch in Settings.
    static let enabledKey = "boardActivityToasts"

    private(set) var toasts: [ActivityToast] = []
    @ObservationIgnored private var nextId = 1

    var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func add(_ notice: ActivityNotice, now: Date = Date()) {
        guard enabled else { return }
        let key = [notice.actor, notice.computerId, notice.projectId, notice.itemId].joined(separator: "\u{0}")
        let index = toasts.firstIndex { $0.key == key && now.timeIntervalSince($0.updatedAt) <= Self.groupWindow }
        var toast: ActivityToast
        if let index {
            toast = toasts.remove(at: index)
            if !notice.itemTitle.isEmpty { toast.itemTitle = notice.itemTitle }
            toast.lines = Array((toast.lines + [notice.line]).suffix(Self.maxLines))
            toast.updatedAt = now
        } else {
            toast = ActivityToast(id: nextId, key: key, actorLabel: notice.actorLabel, computerId: notice.computerId,
                                  itemId: notice.itemId, itemTitle: notice.itemTitle, lines: [notice.line], updatedAt: now)
            nextId += 1
        }
        toasts = Array(([toast] + toasts).prefix(Self.maxToasts))
    }

    /// Drops the toasts nothing has updated for `shownFor`.
    func expire(now: Date = Date()) {
        let kept = toasts.filter { now.timeIntervalSince($0.updatedAt) < Self.shownFor }
        if kept.count != toasts.count { toasts = kept }
    }

    func dismiss(_ id: Int) {
        toasts.removeAll { $0.id == id }
    }
}
