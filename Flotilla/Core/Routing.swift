import Foundation

/// What a notification is about and where tapping it leads. It travels in
/// the notification's `userInfo` as `computer`, `kind`, `id` and, for the
/// kinds that open a bot, `bot`.
struct NotificationTarget: Equatable {
    enum Kind: String, CaseIterable {
        /// A decision waiting for a ruling: its detail.
        case decision
        /// A tool waiting for permission: the bot, with its card on top.
        case permission
        /// A bot waiting for you: its Chat.
        case waiting
        /// A task for you or from a bot: the bot's Work pane.
        case task
        /// A bot waiting for approval in its terminal: the bot.
        case approval
    }

    /// Where a target opens.
    enum Destination: Equatable {
        case decision(id: String)
        case bot(id: String, pane: BotPane?)
        /// The Decisions tab, scrolled to a permission card: for a prompt
        /// whose bot is not known.
        case permissionCard(id: String)
    }

    /// The bot pane a route asks for; `nil` keeps the bot's first pane.
    enum BotPane: String, Equatable {
        case chat, work
    }

    let computerId: String
    let kind: Kind
    let id: String
    var botId: String?

    var userInfo: [String: String] {
        var info = ["computer": computerId, "kind": kind.rawValue, "id": id]
        if let botId { info["bot"] = botId }
        return info
    }

    init(computerId: String, kind: Kind, id: String, botId: String? = nil) {
        self.computerId = computerId
        self.kind = kind
        self.id = id
        self.botId = botId
    }

    /// The target in a tapped notification's `userInfo`, or nil for one that
    /// leads nowhere. Notifications from before `kind` existed carried only
    /// `computer` and `permission`.
    init?(userInfo: [AnyHashable: Any]) {
        guard let computer = userInfo["computer"] as? String, !computer.isEmpty else { return nil }
        let bot = (userInfo["bot"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let raw = userInfo["kind"] as? String, let kind = Kind(rawValue: raw),
           let id = userInfo["id"] as? String, !id.isEmpty {
            self.init(computerId: computer, kind: kind, id: id, botId: bot)
        } else if let permission = userInfo["permission"] as? String, !permission.isEmpty {
            self.init(computerId: computer, kind: .permission, id: permission, botId: bot)
        } else {
            return nil
        }
    }

    /// Nil for a task whose bot is not known: there is nowhere to open it.
    var destination: Destination? {
        switch kind {
        case .decision: .decision(id: id)
        case .permission: botId.map { .bot(id: $0, pane: nil) } ?? .permissionCard(id: id)
        case .waiting: .bot(id: botId ?? id, pane: .chat)
        case .task: botId.map { .bot(id: $0, pane: .work) }
        case .approval: .bot(id: botId ?? id, pane: nil)
        }
    }
}

/// A link the system hands the app: a pairing link from the Camera, a
/// message or a web page.
enum IncomingURL {
    static func pairing(_ url: URL) -> PairingLink? {
        guard let scheme = url.scheme?.lowercased(), PairingLink.schemes.contains(scheme) else { return nil }
        return PairingLink.parse(url.absoluteString)
    }
}
