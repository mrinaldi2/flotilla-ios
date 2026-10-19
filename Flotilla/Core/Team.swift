import Foundation

// The team on demand (0.23.0, capability `team_on_demand_v1`): most of a
// project's bots sleep until there is work, at most `max_running_bots` run at
// once on a computer, and a wake with no free slot waits in a queue. A bot is
// always on or on demand (`set_bot_presence`); the owner wakes one
// (`wake_bot`, also when opening its chat) or sends it to sleep
// (`sleep_bot`). `team_status` and the `team_updated` push say how many run
// and who waits. An older daemon sends none of it, and its bots stay as they
// were: always on.

/// The 0.23 capabilities, each gating its own part.
enum Capability023 {
    /// Presence, Asleep and Waiting for a slot, wake and sleep, the running
    /// cap and its queue, the Product and Architect roles, assigning by role.
    static let teamOnDemand = "team_on_demand_v1"
    /// The project mirror and worktrees per card: nothing the phone shows yet.
    static let repoMirror = "repo_mirror_v1"
}

extension AppStore {
    var hasTeamOnDemand: Bool { capabilities.contains(Capability023.teamOnDemand) }
}

/// Whether a bot runs all the time or sleeps until there is work.
enum BotPresence: String, CaseIterable, Identifiable {
    case alwaysOn = "always_on"
    case onDemand = "on_demand"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .alwaysOn: "Always on"
        case .onDemand: "On demand"
        }
    }
}

/// A wake waiting for a running slot, as `team_status` lists it.
struct TeamWake: Identifiable, Equatable {
    let botId: String
    let projectId: String
    /// `owner`, `lead`, `card`, `task`, `message`, `review` or `routine`.
    let reason: String
    let itemId: String?
    /// `P0` to `P3`, for card work.
    let priority: String?
    /// A P0 bug: it goes to the front of the card work.
    let urgent: Bool
    let queuedAt: Date?

    var id: String { botId }

    init(_ d: JSONDict) {
        botId = d.str("bot_id")
        projectId = d.str("project_id")
        reason = d.str("reason")
        itemId = d.optStr("item_id")
        priority = d.optStr("priority")
        urgent = d.bool("urgent")
        queuedAt = d.date("queued_at")
    }

    /// Why it waits, as the desktop's queue reads it: "Card H-018 · P1",
    /// "Lead", "You woke it". An urgent bug says so in a pill of its own.
    var words: String {
        let label = Self.reasons[reason] ?? (reason.isEmpty ? "Waiting" : reason.capitalizedFirst)
        var words = itemId.map { "\(label) \($0)" } ?? label
        if let priority { words += " · \(priority)" }
        return words
    }

    static let reasons = ["owner": "You woke it", "lead": "Lead", "card": "Card", "task": "Task",
                          "message": "Message", "review": "Review", "routine": "Routine"]
}

/// One computer's running bots and the queue for a slot.
struct TeamStatus: Equatable {
    let running: Int
    let maxRunning: Int
    let idleSleepMinutes: Int
    /// In the order they will start.
    let queue: [TeamWake]

    init(running: Int, maxRunning: Int, idleSleepMinutes: Int, queue: [TeamWake] = []) {
        self.running = running
        self.maxRunning = maxRunning
        self.idleSleepMinutes = idleSleepMinutes
        self.queue = queue
    }

    init(_ d: JSONDict) {
        running = d.int("running")
        maxRunning = d.int("max_running")
        idleSleepMinutes = d.int("idle_sleep_minutes")
        queue = d.list("queue").map(TeamWake.init)
    }

    /// "4 of 6 running · 2 waiting", "4 of 6 running".
    var words: String {
        var parts = ["\(running) of \(maxRunning) running"]
        if !queue.isEmpty { parts.append("\(queue.count) waiting") }
        return parts.joined(separator: " · ")
    }

    /// Every slot is taken: a wake now waits.
    var full: Bool { maxRunning > 0 && running >= maxRunning }

    /// The queue's wakes for one project's bots.
    func queue(in projectId: String) -> [TeamWake] { queue.filter { $0.projectId == projectId } }

    /// The bot's place in the queue, from 1; nil when it isn't waiting.
    func place(of botId: String) -> Int? { queue.firstIndex { $0.botId == botId }.map { $0 + 1 } }
}

/// What the owner may do about a bot's presence and sleep, and why not.
enum TeamRules {
    /// Why the bot's presence can't be changed from here, or nil when it can.
    static func presenceLocked(_ bot: Bot, project: Project?) -> String? {
        if project?.leadBotId == bot.id { return "The project's lead is always on: it plans and hands out the work." }
        if let peer = bot.peerName { return "\(bot.name) runs on \(peer): set it there." }
        if bot.temporary { return "A worker is on demand and retires when its task closes." }
        return nil
    }

    /// Wake now: the bot sleeps, or waits for a slot (waking moves it to the front).
    static func canWake(_ bot: Bot) -> Bool { bot.state.isAsleep }

    /// Sleep now: an on-demand bot that is awake.
    static func canSleep(_ bot: Bot, project: Project?) -> Bool {
        guard bot.presence == .onDemand, project?.leadBotId != bot.id, !bot.state.isAsleep else { return false }
        return ![.stopped, .stopping, .crashed, .authFailed].contains(bot.state)
    }
}
