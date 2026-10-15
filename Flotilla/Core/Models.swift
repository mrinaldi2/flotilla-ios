import Foundation

// Entities of the gravityd control plane (protocol v2), see docs/protocol.md
// in github.com/ahilles107/gravity.

struct Project: Identifiable, Equatable {
    let id: String
    var name: String
    var leadBotId: String?
    var deletedAt: Date?
    /// Its folder under ~/.gravity/projects.
    var dirName: String
    /// Projects on other daemons this one is linked with: one team across machines.
    var links: [ProjectLink]
    /// The shared git repository workers check out and push to, if any.
    var repo: ProjectRepo?
    /// Its card ids' prefix ("H" for "H-017"), when the service sends it (H-203).
    var itemPrefix: String?

    init(_ d: JSONDict) {
        id = d.str("id")
        name = d.str("name")
        dirName = d.optStr("dir_name") ?? d.str("name")
        links = d.list("links").map(ProjectLink.init)
        // null or absent: no repository.
        repo = d.dict("repo").flatMap { row in
            row.optStr("url").map { ProjectRepo(url: $0, branch: row.optStr("branch") ?? "main") }
        }
        leadBotId = d.optStr("lead_bot_id")
        deletedAt = d.date("deleted_at")
        itemPrefix = d.optStr("item_prefix")
    }
}

enum BotState: String {
    case starting, ready, working
    case waitingForUser = "waiting_for_user"
    case waitingForApproval = "waiting_for_approval"
    case rateLimited = "rate_limited"
    case authFailed = "auth_failed"
    case crashed, stopping, stopped
    case unknown

    var label: String {
        switch self {
        case .starting: "Starting"
        case .ready: "Idle"
        case .working: "Working"
        case .waitingForUser: "Waiting for you"
        case .waitingForApproval: "Needs approval"
        case .rateLimited: "Rate limited"
        case .authFailed: "Sign-in failed"
        case .crashed: "Crashed"
        case .stopping: "Stopping"
        case .stopped: "Stopped"
        case .unknown: "Unknown"
        }
    }

    /// The bot is blocked until the owner does something.
    var needsOwner: Bool { self == .waitingForUser || self == .waitingForApproval }
}

/// A project's shared git repository: workers start from its branch and push back to it.
struct ProjectRepo: Equatable {
    let url: String
    let branch: String
}

/// A project on a peer daemon that this project is linked with.
struct ProjectLink: Identifiable, Equatable {
    let peerId: String
    let peerName: String
    let online: Bool
    let remoteProjectId: String
    let remoteProjectName: String

    var id: String { peerId }

    init(_ d: JSONDict) {
        peerId = d.str("peer_id")
        peerName = d.str("peer_name")
        online = d.bool("online")
        remoteProjectId = d.str("remote_project_id")
        remoteProjectName = d.str("remote_project_name")
    }
}

/// Another Gravity daemon this one is paired with (`list_peers`).
struct Peer: Identifiable, Equatable {
    let id: String
    let name: String
    /// Set on the side that dials the other.
    let url: String?
    let daemonId: String?
    let online: Bool
    let lastSeenAt: Date?
    let revokedAt: Date?

    init(_ d: JSONDict) {
        id = d.str("id")
        name = d.str("name")
        url = d.optStr("url")
        daemonId = d.optStr("daemon_id")
        online = d.bool("online")
        lastSeenAt = d.date("last_seen_at")
        revokedAt = d.date("revoked_at")
    }

    var isActive: Bool { revokedAt == nil }
}

/// A project on a peer, for choosing one to link (`list_peer_projects`).
struct PeerProject: Identifiable, Equatable {
    let id: String
    let name: String
    let botCount: Int
    /// The project here it is already linked with.
    let linkedProjectId: String?

    init(_ d: JSONDict) {
        id = d.str("id")
        name = d.str("name")
        botCount = d.int("bot_count")
        linkedProjectId = d.optStr("linked_project_id")
    }
}

/// The coding agent a bot runs.
enum BotEngine: String, CaseIterable, Identifiable {
    case claudeCode = "claude_code"
    case codex = "codex_cli"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }
}

struct Bot: Identifiable, Equatable {
    let id: String
    var projectId: String
    var name: String
    var description: String
    var avatar: String
    var instructions: String
    var state: BotState
    var stateReason: String
    var workspacePath: String
    var createdByBotId: String?
    var deletedAt: Date?
    /// `claude_code` or `codex_cli`; older daemons leave it out (Claude Code).
    var runtime: String?
    /// Set when the bot runs on another daemon and stands in here.
    var peerName: String?
    var peerOnline: Bool
    /// May also drive the owner's own Chrome, besides its own browser.
    var userChrome: Bool
    /// A worker: created for one task, archived once that task closes.
    var temporary: Bool

    var isLinked: Bool { peerName != nil }
    var engine: BotEngine? { runtime.flatMap(BotEngine.init(rawValue:)) }

    init(_ d: JSONDict) {
        id = d.str("id")
        runtime = d.optStr("runtime")
        let peer = d.dict("peer")
        peerName = peer?.optStr("name")
        peerOnline = peer?.bool("online") ?? false
        userChrome = d.bool("user_chrome")
        temporary = d.bool("temporary")
        projectId = d.str("project_id")
        name = d.str("name")
        description = d.str("description")
        avatar = d.str("avatar")
        instructions = d.str("instructions")
        state = BotState(rawValue: d.str("state")) ?? .unknown
        stateReason = d.str("state_reason")
        workspacePath = d.str("workspace_path")
        createdByBotId = d.optStr("created_by_bot_id")
        deletedAt = d.date("deleted_at")
    }
}

/// One line of "what happened last" for a bot.
struct BotActivity: Equatable {
    let botId: String
    /// Empty when the bot itself spoke.
    let from: String
    let text: String
    let at: Date?

    init(_ d: JSONDict) {
        botId = d.str("bot_id")
        from = d.str("from")
        text = d.str("text")
        at = d.date("at")
    }
}

struct Conversation: Identifiable, Equatable {
    let id: String
    let projectId: String
    let botId: String
    let title: String

    init(_ d: JSONDict) {
        id = d.str("id")
        projectId = d.str("project_id")
        botId = d.str("bot_id")
        title = d.str("title")
    }
}

struct BusMessage: Identifiable, Equatable {
    let id: String
    let conversationId: String
    let senderKind: String
    let senderName: String
    let senderBotId: String?
    let kind: String
    let body: String
    let decisionId: String?
    let createdAt: Date?

    var fromUser: Bool { senderKind == "user" }

    init(_ d: JSONDict) {
        id = d.str("id")
        conversationId = d.str("conversation_id")
        let sender = d.dict("sender") ?? [:]
        senderKind = sender.str("kind")
        senderName = sender.str("name")
        senderBotId = sender.optStr("bot_id")
        kind = d.str("kind")
        body = d.str("body")
        decisionId = d.optStr("decision_id")
        createdAt = d.date("created_at")
    }
}

struct Routine: Identifiable, Equatable {
    let id: String
    let botId: String
    let name: String
    let triggerSummary: String
    let prompt: String
    var enabled: Bool
    let nextRunAt: Date?

    init(_ d: JSONDict) {
        id = d.str("id")
        botId = d.str("bot_id")
        name = d.str("name")
        prompt = d.str("prompt")
        enabled = d.bool("enabled")
        nextRunAt = d.date("next_run_at")
        let trigger = d.dict("trigger") ?? [:]
        switch trigger.str("kind") {
        case "cron": triggerSummary = "cron \(trigger.str("expr")) (\(trigger.str("tz")))"
        case "interval": triggerSummary = "every \(Routine.span(trigger.int("seconds")))"
        case "signal": triggerSummary = "on signal \(trigger.str("name"))"
        default: triggerSummary = trigger.str("kind")
        }
    }

    private static func span(_ seconds: Int) -> String {
        if seconds % 3600 == 0 { return "\(seconds / 3600) h" }
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        return "\(seconds) s"
    }
}

struct DecisionOption: Identifiable, Equatable {
    let key: String
    let label: String
    let description: String
    /// Permission extras picking this option gives bots (H-117).
    let grants: [OptionGrant]
    /// Pins the grants shown: a ruling on this option sends it back (ARCH-R51 M2).
    let grantsSha: String?
    var id: String { key }

    init(_ d: JSONDict) {
        key = d.str("key")
        label = d.str("label")
        description = d.str("description")
        grants = d.list("grants").map(OptionGrant.init)
        grantsSha = d.optStr("grants_sha")
    }
}

/// One extra an option grants one bot; `bot` is the bot's id.
struct OptionGrant: Equatable {
    let bot: String
    let extra: String

    init(_ d: JSONDict) {
        bot = d.str("bot")
        extra = d.str("extra")
    }

    /// "Grants DevOps: install, daemon restart · Tester: install", as the desktop words it.
    static func words(_ grants: [OptionGrant], name: (String) -> String) -> String {
        var order: [String] = []
        var extras: [String: [String]] = [:]
        for grant in grants {
            if extras[grant.bot] == nil { order.append(grant.bot) }
            extras[grant.bot, default: []].append(grant.extra.replacingOccurrences(of: "_", with: " "))
        }
        return "Grants " + order.map { "\(name($0)): \(extras[$0]!.joined(separator: ", "))" }.joined(separator: " · ")
    }
}

struct DecisionRuling: Equatable {
    let option: String?
    let text: String
    let reason: String?
    let answeredBy: String

    init(_ d: JSONDict) {
        option = d.optStr("option")
        text = d.str("text")
        reason = d.optStr("reason")
        answeredBy = d.str("answered_by")
    }
}

struct DecisionComment: Identifiable, Equatable {
    let id: String
    let decisionId: String
    let authorKind: String
    let authorName: String
    let body: String
    let createdAt: Date?

    init(_ d: JSONDict) {
        id = d.str("id")
        decisionId = d.str("decision_id")
        authorKind = d.str("author_kind")
        authorName = d.str("author_name")
        body = d.str("body")
        createdAt = d.date("created_at")
    }
}

struct Decision: Identifiable, Equatable {
    let id: String
    let projectId: String
    let kind: String
    let title: String
    let body: String
    let options: [DecisionOption]
    let recommendation: String?
    let raisedByName: String
    let raisedByAvatar: String
    let raisedByBotId: String
    let priority: String
    let deadlineAt: Date?
    let state: String
    let heldUntil: Date?
    let ruling: DecisionRuling?
    let withdrawnReason: String?
    let tags: [String]
    let commentCount: Int
    var comments: [DecisionComment]
    let createdAt: Date?

    var urgent: Bool { priority == "urgent" }
    /// The grants sha to send with a ruling on `option` (else the drafted
    /// ruling's), when that option grants extras.
    func grantsSha(for option: String?) -> String? {
        guard let key = option ?? ruling?.option else { return nil }
        return options.first { $0.key.caseInsensitiveCompare(key) == .orderedSame && !$0.grants.isEmpty }?.grantsSha
    }
    /// Only these count toward the pending badge.
    var pending: Bool { state == "open" || state == "answered" }

    init(_ d: JSONDict) {
        id = d.str("id")
        projectId = d.str("project_id")
        kind = d.str("kind")
        title = d.str("title")
        body = d.str("body")
        options = d.list("options").map(DecisionOption.init)
        recommendation = d.optStr("recommendation")
        let raisedBy = d.dict("raised_by") ?? [:]
        raisedByName = raisedBy.str("name")
        raisedByAvatar = raisedBy.str("avatar")
        raisedByBotId = raisedBy.str("bot_id")
        priority = d.str("priority")
        deadlineAt = d.date("deadline_at")
        state = d.str("state")
        heldUntil = d.date("held_until")
        ruling = d.dict("ruling").map(DecisionRuling.init)
        withdrawnReason = d.optStr("withdrawn_reason")
        tags = d.strings("tags")
        commentCount = d.int("comment_count")
        comments = d.list("comments").map(DecisionComment.init)
        createdAt = d.date("created_at")
    }
}

struct PendingCounts: Equatable {
    var total = 0
    var urgent = 0
    var dueSoon = 0

    init() {}

    init(_ d: JSONDict) {
        total = d.int("total")
        urgent = d.int("urgent")
        dueSoon = d.int("due_soon")
    }
}

struct Diagnostics: Equatable {
    let daemonVersion: String
    let dbHealthy: Bool
    let runtimeKind: String
    let runtimeAvailable: Bool
    let deliveryBacklog: Int
    let activeBots: Int
    let uptimeSeconds: Int
    let staleBuild: Bool

    init(_ d: JSONDict) {
        daemonVersion = d.str("daemon_version")
        dbHealthy = d.bool("db_healthy")
        let runtime = d.dict("runtime") ?? [:]
        runtimeKind = runtime.str("kind")
        runtimeAvailable = runtime.bool("available")
        deliveryBacklog = d.int("delivery_backlog")
        activeBots = d.int("active_bots")
        uptimeSeconds = d.int("uptime_seconds")
        staleBuild = d.bool("stale_build")
    }
}
