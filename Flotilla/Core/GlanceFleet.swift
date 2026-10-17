import Foundation

// Board glance (0.20, phase 2): what a daemon with the Board glance
// additions says about a project's bots (`overview_bots`), a bot that has
// stopped (`attention_bot_stopped`) and its computers' presence. Older
// daemons send none of it: phase 1's counts and Doing cards stand in.

typealias HomeBotBrief = Flotilla_Home_V1_BotBrief

extension AppStore {
    /// `ProjectRow.bot_list`, `Member.online` and `Member.last_seen_at`.
    var hasOverviewBots: Bool { capabilities.contains("overview_bots") }
}

/// A project's bots by what they are doing, from its bot list.
struct FleetCounts: Equatable {
    var working = 0
    var waiting = 0
    var stopped = 0
    var idle = 0
    var offline = 0

    /// The list holds at most 24 bots; `total` is every bot, so the ones it
    /// cut count as idle.
    init(_ bots: [HomeBotBrief], total: Int) {
        for bot in bots {
            switch bot.status {
            case .working: working += 1
            case .waiting: waiting += 1
            case .stopped, .failed: stopped += 1
            case .offline: offline += 1
            case .idle, .unspecified, .UNRECOGNIZED: idle += 1
            }
        }
        idle += max(0, total - bots.count)
    }

    /// "2 working · 1 waiting · 1 stopped · 3 idle · 2 offline"; "0 idle" when
    /// nothing else applies.
    var words: String {
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if stopped > 0 { parts.append("\(stopped) stopped") }
        if idle > 0 || parts.isEmpty && offline == 0 { parts.append("\(idle) idle") }
        if offline > 0 { parts.append("\(offline) offline") }
        return parts.joined(separator: " · ")
    }

    /// "4 bots: 2 working, 1 stopped, 1 idle."
    func sentence(bots: Int) -> String {
        let all = "\(bots) bot\(bots == 1 ? "" : "s")"
        if working + waiting + stopped + offline == 0 { return "\(all), all idle." }
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if stopped > 0 { parts.append("\(stopped) stopped") }
        if idle > 0 { parts.append("\(idle) idle") }
        if offline > 0 { parts.append("\(offline) offline") }
        return "\(all): " + parts.joined(separator: ", ") + "."
    }
}

enum GlanceFleet {
    /// The avatars a card shows from its bot list (§1): who is at work or
    /// waits on you, else the lead; at most four, in the list's order.
    static func shown(_ bots: [HomeBotBrief], limit: Int = 4) -> [HomeBotBrief] {
        let busy = bots.filter { [.working, .waiting, .failed, .stopped].contains($0.status) }
        if !busy.isEmpty { return Array(busy.prefix(limit)) }
        return Array(bots.filter(\.lead).prefix(1))
    }

    /// When an offline computer was last seen: the latest `last_seen_at` of
    /// the row's offline members; nil from a daemon that doesn't say.
    static func lastSeen(_ row: HomeRow, among daemonIds: Set<String>) -> Date? {
        row.members
            .filter { !$0.online && $0.hasLastSeenAt && daemonIds.contains($0.daemonID) }
            .map(\.lastSeenAt.date)
            .max()
    }
}

/// A `bot_stopped` row (BG-Rules §2): the bot, why it stopped, and whether
/// Restart helps.
enum StoppedBot {
    /// Why it isn't running, the row's `bot_state`.
    enum Reason: Equatable {
        case crashed, stopped, authFailed, rateLimited

        init(_ state: String) {
            switch state {
            case "crashed": self = .crashed
            case "auth_failed": self = .authFailed
            case "rate_limited": self = .rateLimited
            default: self = .stopped
            }
        }
    }

    static func reason(_ row: HomeAttentionRow) -> Reason? {
        row.kind == .botStopped ? Reason(row.botState) : nil
    }

    /// Restart brings a crashed or stopped bot back; one that can't sign in
    /// or is rate limited needs something else first.
    static func restarts(_ row: HomeAttentionRow) -> Bool {
        switch reason(row) {
        case .crashed?, .stopped?: true
        default: false
        }
    }

    /// What the owner does instead, on `place` (the bot's computer).
    static func advice(_ row: HomeAttentionRow, on place: String) -> String? {
        switch reason(row) {
        case .authFailed?: "Sign its engine in again on \(place), then restart it there."
        case .rateLimited?: "It has hit its plan's limit. It starts again by itself when the limit lifts."
        default: nil
        }
    }

    /// The asks on a card, a stopped bot first (§1), the rest in the
    /// daemon's order.
    static func first(_ rows: [HomeAttentionRow]) -> [HomeAttentionRow] {
        rows.filter { $0.kind == .botStopped } + rows.filter { $0.kind != .botStopped }
    }
}

extension Fleet {
    /// Restarts the bot a `bot_stopped` row names: on its own computer when
    /// the phone talks to it, else through its stand-in on the computer that
    /// answered for the card, which forwards it.
    func restart(_ row: HomeAttentionRow, answeredBy computerId: String) async throws {
        guard case .bot(let ref)? = row.target else {
            throw DaemonError(code: "invalid_request", message: "This row names no bot to restart.")
        }
        if let own = computer(daemonId: ref.daemonID) {
            try await own.store.restartBot(ref.botID)
            await home.refresh(own, force: true)
            return
        }
        guard let answering = computer(id: computerId),
              let standIn = answering.store.bots.first(where: { $0.originDaemonId == ref.daemonID && $0.originBotId == ref.botID })
        else {
            throw DaemonError(code: "unavailable", message: "Connect to the computer \(ref.name) runs on to restart it.")
        }
        try await answering.store.restartBot(standIn.id)
        await home.refresh(answering, force: true)
    }

    /// Whether Restart can be sent for the row now, or why not.
    func restartUnavailable(_ row: HomeAttentionRow, answeredBy computerId: String) -> String? {
        guard case .bot(let ref)? = row.target else { return "No bot to restart" }
        let target = computer(daemonId: ref.daemonID) ?? computer(id: computerId)
        guard let target else { return "Not connected to its computer" }
        guard target.store.status == .connected else { return "Not connected to \(target.name)" }
        guard target.store.canRestart else { return "Restart needs control of \(target.name)" }
        return nil
    }
}
