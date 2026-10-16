import Foundation
import Observation
import UIKit

/// Receives a bot's terminal stream while its terminal screen is open.
@MainActor
protocol TerminalSink: AnyObject {
    func attached(seq: Int, resumed: Bool)
    func output(seq: Int, data: String)
    /// The connection came back: re-attach from the last seen cursor.
    func reattach()
}

struct Notice: Identifiable, Equatable {
    let id = UUID()
    let level: String
    let title: String
    let body: String
    let decisionId: String?
}

/// Everything the UI shows about one computer, kept current from replies and pushes.
@MainActor
@Observable
final class AppStore {
    var computerName = ""
    var kind = ComputerKind.mac
    var status: ConnectionStatus = .idle
    /// Whether to tell the owner the computer is unreachable. A drop on the
    /// move usually heals in a second or two, so this waits a moment first.
    var connectionTrouble = false
    /// The last round trip to the daemon, from the keepalive pings.
    var latency: Duration?
    var endpoint: Endpoint?
    var grants: Set<String> = []
    /// What the daemon serves, from `hello_ok`.
    var capabilities: Set<String> = []
    /// Binary encodings it takes (`["proto"]`): typed requests in binary frames.
    var encodings: Set<String> = []
    var serverVersion = ""
    var deviceId: String?
    /// The daemon's stable id, as its peers know it (newer daemons).
    var daemonId: String?
    /// Permission prompts waiting on the owner, oldest first.
    var permissions: [PermissionRequest] = []
    /// The bot whose screen is open, so its prompts need no notification.
    @ObservationIgnored var botOnScreen: String?
    /// Daemons this one is paired with; loaded by the network screen.
    var peers: [Peer] = []

    var projects: [Project] = []
    /// A release waiting to be installed on this device (H-230): the banner.
    var installOffer: InstallOffer?
    /// The last release whose owner_blockers changed (`release_updated`, H-248);
    /// a new value on every push, even for the same release.
    var releaseUpdated: ReleaseUpdate?
    /// The service has answered list_projects since this connection began, so an
    /// empty `projects` means none, not not-yet (H-216).
    private(set) var projectsLoaded = false
    var bots: [Bot] = []
    var activity: [String: BotActivity] = [:]
    /// bot id → its DM thread.
    var conversations: [String: Conversation] = [:]
    /// conversation id → messages, oldest first.
    var messages: [String: [BusMessage]] = [:]
    /// conversation id → whether older messages than the loaded ones exist.
    var messagesHaveMore: [String: Bool] = [:]
    var decisions: [Decision] = []
    /// How many settled decisions to keep loaded; "Show more" raises it.
    var settledLimit = Page.size
    var pendingCounts = PendingCounts()
    /// bot id → what its native permission prompt is asking.
    var approvals: [String: String] = [:]
    /// bot id → when the owner last looked at it.
    var lastSeen: [String: Date] = [:]
    var notice: Notice?
    var inBackground = false
    /// Bumped by bus traffic and routine runs: tasks open and close with them.
    var busRevision = 0
    /// Bumped by messages one bot sends another, for the Conversations view.
    var botMessageRevision = 0
    /// project id → bumped when its worker queue changes (`workers_updated`).
    var workersRevision: [String: Int] = [:]
    /// bot id → bumped whenever its chat changes (`chat_turns`): its commands,
    /// browser activity and memory are reread then.
    var chatRevision: [String: Int] = [:]

    /// The bot whose browser this connection watches (one at a time), with
    /// the tab picked, if any; nil follows the bot's own tab.
    private(set) var watchedBrowser: (botId: String, tabId: String?)?
    /// Its tabs and newest screen, as the daemon pushes them.
    var browserTabs: BrowserTabs?
    var browserFrame: BrowserFrame?
    /// Set when the phone knows several computers: notifications name this one.
    @ObservationIgnored var notificationTag: String?
    /// The pending-decision counts changed (for the app icon's badge).
    @ObservationIgnored var onCountsChanged: (() -> Void)?
    /// A project's row on the projects home changed (`projects_overview_changed`).
    @ObservationIgnored var onHomeChanged: (() -> Void)?
    /// Bumped by `owner_thread_updated`: the main chat rereads its threads.
    var ownerThreadsVersion = 0
    /// Turns of a bot's chat that are new or changed (`chat_turns`).
    @ObservationIgnored var onChatTurns: ((String, [JSONDict]) -> Void)?

    @ObservationIgnored let client = DaemonClient()
    /// Screens following a project's board, by project: its `board_event` pushes go to them (K7).
    @ObservationIgnored var boardListeners: [String: [UUID: (BoardEvent) -> Void]] = [:]
    @ObservationIgnored private let defaults: ComputerDefaults
    @ObservationIgnored private var sinks: [String: TerminalSink] = [:]
    @ObservationIgnored private var troubleTask: Task<Void, Never>?
    /// How long a drop lasts before `connectionTrouble` shows it.
    /// Eight seconds (H-217): retries on a loaded Mac over Tailscale often
    /// take longer than three, and say nothing the owner must act on.
    @ObservationIgnored var troubleDelay: Duration = .seconds(8)
    /// Bumped on every connection: screens that failed to load reload (H-217).
    var reconnects = 0

    var canControl: Bool { grants.contains("control") }
    var canApprove: Bool { grants.contains("approve") }
    /// The daemon reads the bots' transcripts itself (Gravity's chat pane), so
    /// Gravity Lens is needed only for the file browser and the screen layout.
    var hasChat: Bool { capabilities.contains("chat") }
    /// Projects can be linked across daemons, and bots created on a peer.
    var hasLinkedProjects: Bool { capabilities.contains("linked_projects") }
    /// Bots can run Claude Code or Codex.
    var hasEngines: Bool { capabilities.contains("bot_runtime") }

    /// The Browser pane, for a bot here or one running on a linked machine.
    func hasBrowser(_ bot: Bot) -> Bool {
        capabilities.contains(bot.isLinked ? "peer_browser" : "bot_browser")
    }

    /// A linked bot's terminal is mirrored here (`peer_terminal`).
    func hasTerminal(_ bot: Bot) -> Bool { !bot.isLinked || capabilities.contains("peer_terminal") }
    var hasCommands: Bool { capabilities.contains("bot_commands") }
    /// Bots spawn temporary workers, and projects can share a git repository.
    var hasWorkers: Bool { capabilities.contains("workers") }
    /// Bots' permission prompts wait here for an answer.
    var hasPermissions: Bool { capabilities.contains("permissions") }

    /// What the Decisions tab counts: waiting prompts are urgent too.
    var decisionsBadge: Int { pendingCounts.total + permissions.count }

    func permissions(for botId: String) -> [PermissionRequest] { permissions.filter { $0.botId == botId } }
    var hasConversations: Bool { capabilities.contains("agent_conversations") }
    /// Restart and Clear chat; they change state, so they need `control` too.
    var canRestart: Bool { capabilities.contains("restart_bot") && canControl }

    init(defaults: ComputerDefaults) {
        self.defaults = defaults
        client.onStatus = { [weak self] status in self?.statusChanged(status) }
        client.onLatency = { [weak self] latency in self?.latency = latency }
        client.onHello = { [weak self] hello in self?.helloReceived(hello) }
        client.onPush = { [weak self] type, frame in self?.pushReceived(type, frame) }
        client.onEnvelopePush = { [weak self] envelope in self?.envelopePushed(envelope) }
        if let seen = UserDefaults.standard.dictionary(forKey: defaults.key("lastSeen")) as? [String: Double] {
            lastSeen = seen.mapValues(Date.init(timeIntervalSince1970:))
        }
    }

    // MARK: Endpoint

    func connect(_ endpoint: Endpoint) {
        self.endpoint = endpoint
        client.start(endpoint)
    }

    func disconnect() {
        client.stop()
        endpoint = nil
        clear()
    }

    private func clear() {
        grants = []
        capabilities = []
        permissions = []
        browserTabs = nil
        browserFrame = nil
        projects = []
        installOffer = nil
        projectsLoaded = false
        bots = []
        activity = [:]
        conversations = [:]
        messages = [:]
        messagesHaveMore = [:]
        decisions = []
        pendingCounts = PendingCounts()
        approvals = [:]
    }

    // MARK: Connection events

    private func statusChanged(_ status: ConnectionStatus) {
        self.status = status
        if status != .connected { latency = nil }
        noteTrouble(status)
        guard status == .connected else { return }
        reconnects += 1
        Task { await refresh() }
        for sink in sinks.values { sink.reattach() }
        // A new connection watches nothing yet: pick the bot's browser back up.
        if let watched = watchedBrowser { watchBrowser(watched.botId, tabId: watched.tabId) }
    }

    private func noteTrouble(_ status: ConnectionStatus) {
        switch status {
        case .connected:
            troubleTask?.cancel()
            troubleTask = nil
            connectionTrouble = false
        case .connecting, .disconnected:
            // Already shown, or already counting down: retries flip between
            // these two and must not restart the wait.
            guard !connectionTrouble, troubleTask == nil else { return }
            let delay = troubleDelay
            troubleTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                self.troubleTask = nil
                self.connectionTrouble = true
            }
        case .idle, .authFailed, .versionMismatch:
            troubleTask?.cancel()
            troubleTask = nil
            connectionTrouble = true
        }
    }

    private func helloReceived(_ hello: JSONDict) {
        grants = Set(hello.strings("grants"))
        capabilities = Set(hello.strings("capabilities"))
        encodings = Set(hello.strings("encodings"))
        serverVersion = hello.str("server_version")
        deviceId = hello.optStr("device_id")
        daemonId = hello.optStr("daemon_id")
    }

    func refresh() async {
        async let projectsReply = try? client.request("list_projects")
        async let botsReply = try? client.request("list_bots")
        async let activityReply = try? client.request("list_bot_activity")
        async let conversationsReply = try? client.request("list_conversations")
        if let reply = await projectsReply {
            projects = reply.list("projects").map(Project.init).filter { $0.deletedAt == nil }
            projectsLoaded = true
        }
        if let reply = await botsReply {
            bots = reply.list("bots").map(Bot.init).filter { $0.deletedAt == nil }
        }
        if let reply = await activityReply {
            activity = Dictionary(
                reply.list("activity").map { ($0.str("bot_id"), BotActivity($0)) },
                uniquingKeysWith: { _, newest in newest })
        }
        if let reply = await conversationsReply {
            conversations = Dictionary(
                reply.list("conversations").map { ($0.str("bot_id"), Conversation($0)) },
                uniquingKeysWith: { _, newest in newest })
        }
        await refreshDecisions()
        await refreshPermissions()
        await refreshInstallOffer()
    }

    /// Every prompt still waiting: on connecting, so none is missed while away.
    func refreshPermissions() async {
        guard hasPermissions, let reply = try? await client.request("list_permissions") else { return }
        permissions = PermissionRequest.ordered(reply.list("permissions").map(PermissionRequest.init))
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        onCountsChanged?()
    }

    /// Answers a prompt. The card goes at once; `permission_resolved` would remove it too.
    func answerPermission(_ request: PermissionRequest, _ answer: PermissionRequest.Answer, reason: String?) async throws {
        var fields: JSONDict = ["request_id": request.id, "decision": answer.rawValue]
        if answer == .deny, let reason, !reason.isEmpty { fields["reason"] = reason }
        do {
            _ = try await client.request("answer_permission", fields)
        } catch {
            // No longer waiting (answered elsewhere, expired): the card is stale either way.
            await refreshPermissions()
            throw error
        }
        resolvePermission(request.id)
    }

    func refreshDecisions() async {
        // The daemon's default list is only what still wants an answer, so
        // held and recently settled ones are asked for by name.
        async let pendingReply = try? client.request("list_decisions", ["limit": 200])
        async let heldReply = try? client.request("list_decisions", ["state": "held", "limit": 100])
        async let settledReply = try? client.request("list_decisions", ["state": "settled", "limit": settledLimit])
        let replies = await [pendingReply, heldReply, settledReply]
        if replies.contains(where: { $0 != nil }) {
            let known = Dictionary(decisions.map { ($0.id, $0.comments) }, uniquingKeysWith: { first, _ in first })
            decisions = replies.compactMap { $0 }.flatMap { $0.list("decisions") }.map { row in
                var decision = Decision(row)
                if decision.comments.isEmpty { decision.comments = known[decision.id] ?? [] }
                return decision
            }
        }
        await refreshCounts()
    }

    private func refreshCounts() async {
        guard let reply = try? await client.request("count_pending_decisions"),
              let counts = reply.dict("counts") else { return }
        pendingCounts = PendingCounts(counts)
        onCountsChanged?()
    }

    // MARK: Pushes

    func pushReceived(_ type: String, _ frame: JSONDict) {
        switch type {
        case "term":
            sinks[frame.str("bot_id")]?.output(seq: frame.int("seq"), data: frame.str("data"))
        case "attached":
            sinks[frame.str("bot_id")]?.attached(seq: frame.int("seq"), resumed: frame.bool("resumed"))
        case "bot_state":
            botStateChanged(frame)
        case "bot_updated":
            if let bot = frame.dict("bot").map(Bot.init) { upsert(bot) }
        case "project_updated":
            if let project = frame.dict("project").map(Project.init) { upsert(project) }
        case "activity_update":
            if let entry = frame.dict("activity").map(BotActivity.init) { activity[entry.botId] = entry }
        case "message_new":
            if let message = frame.dict("message").map(BusMessage.init) { append(message) }
            busRevision += 1
            if frame.dict("message")?.dict("sender")?.str("kind") == "bot" { botMessageRevision += 1 }
        case "routine_run_update":
            busRevision += 1
        // Sent to this device's connections only (H-229): the banner, no APNs.
        case "install_offer":
            installOffer = frame.dict("offer").map(InstallOffer.init)
        // A release's owner_blockers changed (H-248): its screen reads it again.
        case "release_updated":
            releaseUpdated = ReleaseUpdate(releaseId: frame.str("release_id"))
        case "chat_turns":
            onChatTurns?(frame.str("bot_id"), frame.list("turns"))
            chatRevision[frame.str("bot_id"), default: 0] += 1
        case "permission_request":
            if let row = frame.dict("request") { permissionArrived(PermissionRequest(row)) }
        case "permission_resolved":
            resolvePermission(frame.str("request_id"))
        case "workers_updated":
            workersRevision[frame.str("project_id"), default: 0] += 1
        case "browser_tabs":
            let tabs = BrowserTabs(frame)
            guard tabs.botId == watchedBrowser?.botId else { return }
            browserTabs = tabs
            if browserFrame.map({ !$0.belongs(to: tabs) }) ?? false { browserFrame = nil }
        case "browser_frame":
            guard let next = BrowserFrame(frame), next.botId == watchedBrowser?.botId else { return }
            browserFrame = next
        case "approval_pending":
            approvalPending(frame)
        case "notify":
            notified(frame)
        case "decision_update":
            if let decision = frame.dict("decision").map(Decision.init) { upsert(decision) }
        case "decision_deleted":
            decisions.removeAll { $0.id == frame.str("decision_id") }
            Task { await refreshCounts() }
        case "decision_comment_new":
            if let comment = frame.dict("comment").map(DecisionComment.init) { append(comment) }
        case "projects_overview_changed":
            onHomeChanged?()
        case "owner_thread_updated":
            ownerThreadsVersion += 1
        default:
            break
        }
    }

    private func botStateChanged(_ frame: JSONDict) {
        let id = frame.str("bot_id")
        guard let index = bots.firstIndex(where: { $0.id == id }) else { return }
        let state = BotState(rawValue: frame.str("state")) ?? .unknown
        let previous = bots[index].state
        bots[index].state = state
        bots[index].stateReason = frame.str("reason")
        if state != .waitingForApproval { approvals[id] = nil }
        if inBackground, state == .waitingForUser, previous != state {
            notify("\(bots[index].name) is waiting for you", activity[id]?.text ?? "", id: "wait-\(id)",
                   about: (.waiting, id, id))
        }
    }

    private func permissionArrived(_ request: PermissionRequest) {
        permissions = PermissionRequest.adding(request, to: permissions)
        onCountsChanged?()
        // Its bot is on screen: the card is already in front of the owner.
        guard inBackground || botOnScreen != request.botId else { return }
        if request.isTerminal {
            // Answered only on its own computer: no actions, and tapping opens Needs you.
            let command = request.origin?.command ?? request.summary
            notify(TerminalCommandCard.title, "\(command) · answer it on \(computerName).",
                   id: "permission-\(request.id)", about: (.permission, request.id, nil), always: true)
            return
        }
        notify("\(bot(request.botId)?.name ?? "A bot") wants to run \(request.toolName)", request.summary,
               id: "permission-\(request.id)", about: (.permission, request.id, request.botId), always: true)
    }

    private func resolvePermission(_ id: String) {
        guard permissions.contains(where: { $0.id == id }) else { return }
        permissions.removeAll { $0.id == id }
        Notifier.withdraw(defaults.key("permission-\(id)"))
        onCountsChanged?()
    }

    private func approvalPending(_ frame: JSONDict) {
        let id = frame.str("bot_id")
        // Never the daemon's `detail`: that is the engine's own wording.
        let approval = Approval(tool: frame.optStr("tool"))
        approvals[id] = approval.line
        if inBackground {
            notify(approval.title(bot(id)?.name ?? "A bot"), "", id: "approval-\(id)", about: (.approval, id, id))
        }
    }

    private func notified(_ frame: JSONDict) {
        let entry = Notice(level: frame.str("level"), title: frame.str("title"),
                           body: frame.str("body"), decisionId: frame.optStr("decision_id"))
        if inBackground {
            // What a notice is about, when the daemon says: a decision, or a
            // task and the bot it is for (task_id and bot_id, H-011).
            let about: (NotificationTarget.Kind, String, String?)?
            if let decision = entry.decisionId {
                about = (.decision, decision, nil)
            } else if let task = frame.optStr("task_id"), let bot = frame.optStr("bot_id") {
                about = (.task, task, bot)
            } else {
                about = nil
            }
            notify(entry.title, entry.body, about: about)
        } else {
            notice = entry
        }
    }

    /// `about` (kind, id, bot) comes back as a `NotificationTarget` when the
    /// notification is tapped, with this computer's id.
    private func notify(_ title: String, _ body: String, id: String = UUID().uuidString,
                        about: (NotificationTarget.Kind, String, String?)? = nil, always: Bool = false) {
        let tagged = notificationTag.map { "\($0): \(title)" } ?? title
        let info = about.map { NotificationTarget(computerId: defaults.id, kind: $0.0, id: $0.1, botId: $0.2).userInfo }
            ?? ["computer": defaults.id]
        Notifier.post(title: tagged, body: body, id: defaults.key(id), info: info, inForeground: always)
    }

    private func upsert(_ bot: Bot) {
        bots.removeAll { $0.id == bot.id }
        if bot.deletedAt == nil {
            bots.append(bot)
            // A bot created after connect has a DM thread we have not listed yet.
            if conversations[bot.id] == nil { Task { await refreshConversations() } }
        }
    }

    private func refreshConversations() async {
        guard let reply = try? await client.request("list_conversations") else { return }
        conversations = Dictionary(
            reply.list("conversations").map { ($0.str("bot_id"), Conversation($0)) },
            uniquingKeysWith: { _, newest in newest })
    }

    private func upsert(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        if project.deletedAt == nil { projects.append(project) }
    }

    private func upsert(_ decision: Decision) {
        var updated = decision
        if let index = decisions.firstIndex(where: { $0.id == decision.id }) {
            // Pushes carry the list view; keep a thread we already loaded.
            if updated.comments.isEmpty { updated.comments = decisions[index].comments }
            decisions[index] = updated
        } else {
            decisions.insert(updated, at: 0)
            if inBackground, decision.state == "open" {
                notify("\(decision.raisedByName) needs a decision", decision.title, id: "decision-\(decision.id)",
                       about: (.decision, decision.id, nil))
            }
        }
        Task { await refreshCounts() }
    }

    private func append(_ comment: DecisionComment) {
        guard let index = decisions.firstIndex(where: { $0.id == comment.decisionId }),
              !decisions[index].comments.contains(where: { $0.id == comment.id }) else { return }
        decisions[index].comments.append(comment)
    }

    func append(_ message: BusMessage) {
        guard var thread = messages[message.conversationId],
              !thread.contains(where: { $0.id == message.id }) else { return }
        thread.append(message)
        messages[message.conversationId] = thread
    }

    // MARK: Lookups

    func bot(_ id: String) -> Bot? { bots.first { $0.id == id } }

    func bots(in project: Project) -> [Bot] {
        bots.filter { $0.projectId == project.id }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var sortedProjects: [Project] {
        projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func projectName(_ id: String) -> String { projects.first { $0.id == id }?.name ?? "" }

    func isUnread(_ bot: Bot) -> Bool {
        guard let at = activity[bot.id]?.at else { return false }
        return at > (lastSeen[bot.id] ?? .distantPast)
    }

    func markSeen(_ botId: String) {
        lastSeen[botId] = Date()
        UserDefaults.standard.set(lastSeen.mapValues(\.timeIntervalSince1970), forKey: defaults.key("lastSeen"))
    }

    // MARK: Terminal

    func register(_ sink: TerminalSink, for botId: String) { sinks[botId] = sink }

    func unregister(_ sink: TerminalSink, for botId: String) {
        guard sinks[botId] === sink else { return }
        sinks[botId] = nil
        client.send("detach", ["bot_id": botId])
    }

    /// Type text into a bot's terminal, then press return.
    func submitToTerminal(_ botId: String, text: String) async {
        // Several lines go in as one bracketed paste so the newlines do not submit early.
        let data = text.contains("\n") ? "\u{1b}[200~\(text)\u{1b}[201~" : text
        client.send("input", ["bot_id": botId, "data": data])
        // Sent together, the return is read as part of the text.
        try? await Task.sleep(for: .milliseconds(200))
        client.send("input", ["bot_id": botId, "data": "\r"])
    }

    // MARK: Messages

    /// The newest page of the bot's DM thread, merged into what is loaded.
    func loadMessages(botId: String) async {
        if conversations[botId] == nil { await refreshConversations() }
        guard let conversation = conversations[botId] else { return }
        let wasEmpty = messages[conversation.id]?.isEmpty ?? true
        guard let page = await messagePage(conversation.id, before: nil) else { return }
        // Only a page that reaches the oldest loaded message says whether more exist.
        if wasEmpty { messagesHaveMore[conversation.id] = page.count >= Page.size }
    }

    func loadOlderMessages(botId: String) async {
        guard let conversation = conversations[botId],
              let oldest = messages[conversation.id]?.first,
              let page = await messagePage(conversation.id, before: oldest.id) else { return }
        messagesHaveMore[conversation.id] = page.count >= Page.size
    }

    private func messagePage(_ conversationId: String, before: String?) async -> [BusMessage]? {
        var fields: JSONDict = ["conversation_id": conversationId, "limit": Page.size]
        if let before { fields["before_id"] = before }
        guard let reply = try? await client.request("list_messages", fields) else { return nil }
        let page = reply.list("messages").map(BusMessage.init)
        let fresh = Set(page.map(\.id))
        messages[conversationId] = ((messages[conversationId] ?? []).filter { !fresh.contains($0.id) } + page)
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        return page
    }

    func sendMessage(botId: String, body: String) async throws {
        let reply = try await client.request("send_user_message", ["to_bot_id": botId, "body": body])
        if let message = reply.dict("message").map(BusMessage.init) { append(message) }
    }

    // MARK: Projects and bots

    func createProject(name: String) async throws -> Project {
        let reply = try await client.request("create_project", ["name": name])
        guard let row = reply.dict("project") else {
            throw DaemonError(code: "internal", message: "The Flotilla service did not return the project.")
        }
        let project = Project(row)
        upsert(project)
        return project
    }

    /// Archives the project with its bots; what it left on disk goes to the
    /// Trash (the owner's, from the app or a paired device).
    func deleteProject(_ projectId: String) async throws {
        _ = try await client.request("delete_project", ["project_id": projectId])
        projects.removeAll { $0.id == projectId }
        bots.removeAll { $0.projectId == projectId }
    }

    /// Only the project is required: without a name the daemon picks "New Bot",
    /// and without a charter the bot starts by asking what it is for.
    func createBot(projectId: String, name: String, description: String, instructions: String,
                   avatar: String?, engine: BotEngine? = nil, peerId: String? = nil) async throws -> Bot {
        var fields: JSONDict = ["project_id": projectId]
        if let engine { fields["runtime"] = engine.rawValue }
        // On a peer: the bot runs there, in the linked project, and stands in here.
        if let peerId { fields["peer_id"] = peerId }
        if !name.isEmpty { fields["name"] = name }
        if !description.isEmpty { fields["description"] = description }
        if !instructions.isEmpty { fields["instructions"] = instructions }
        if let avatar { fields["avatar"] = avatar }
        let reply = try await client.request("create_bot", fields)
        guard let row = reply.dict("bot") else {
            throw DaemonError(code: "internal", message: "The Flotilla service did not return the bot.")
        }
        let bot = Bot(row)
        upsert(bot)
        return bot
    }

    // MARK: A bot's browser

    /// Starts streaming the bot's browser here; a second call replaces the
    /// first. With `tabId`, that tab is shown; without, the bot's own.
    func watchBrowser(_ botId: String, tabId: String? = nil) {
        if watchedBrowser?.botId != botId {
            browserTabs = nil
            browserFrame = nil
        }
        watchedBrowser = (botId, tabId)
        guard status == .connected else { return }
        var fields: JSONDict = ["bot_id": botId]
        if let tabId { fields["tab_id"] = tabId }
        Task { _ = try? await client.request("watch_browser", fields) }
    }

    func unwatchBrowser() {
        guard watchedBrowser != nil else { return }
        watchedBrowser = nil
        browserTabs = nil
        browserFrame = nil
        guard status == .connected else { return }
        Task { _ = try? await client.request("unwatch_browser") }
    }

    func browserActivity(botId: String, limit: Int) async throws -> [BrowserAction] {
        let reply = try await client.request("list_browser_activity", ["bot_id": botId, "limit": limit])
        return reply.list("activity").map(BrowserAction.init)
    }

    /// Whether the bot may also drive the owner's own Chrome. Restarts it.
    func setUserChrome(botId: String, enabled: Bool) async throws {
        let reply = try await client.request("set_bot_user_chrome", ["bot_id": botId, "enabled": enabled])
        if let bot = reply.dict("bot").map(Bot.init) { upsert(bot) }
    }

    // MARK: Commands, sessions, conversations

    func botCommands(botId: String, limit: Int) async throws -> [BotCommand] {
        let reply = try await client.request("list_bot_commands", ["bot_id": botId, "limit": limit])
        return reply.list("commands").map(BotCommand.init)
    }

    /// The session restarts and picks its conversation back up.
    func restartBot(_ botId: String) async throws {
        _ = try await client.request("restart_bot", ["bot_id": botId])
    }

    /// A fresh conversation; files, memory and tasks are kept.
    func clearBotSession(_ botId: String) async throws {
        _ = try await client.request("clear_bot_session", ["bot_id": botId])
    }

    func agentConversations(projectId: String) async throws -> (conversations: [AgentConversation], bots: [AgentBot]) {
        let reply = try await client.request("list_agent_conversations", ["project_id": projectId])
        return (reply.list("conversations").map(AgentConversation.init), reply.list("bots").map(AgentBot.init))
    }

    func agentConversation(projectId: String, botIds: [String], before: Int?) async throws
        -> (messages: [AgentMessage], hasMore: Bool, bots: [AgentBot]) {
        var fields: JSONDict = ["project_id": projectId, "bot_ids": botIds, "limit": Page.size]
        if let before { fields["before"] = before }
        let reply = try await client.request("list_agent_conversation", fields)
        return (reply.list("messages").map(AgentMessage.init), reply.bool("has_more"), reply.list("bots").map(AgentBot.init))
    }

    // MARK: Workers

    func listWorkers(projectId: String) async throws -> WorkerListing {
        WorkerListing(try await client.request("list_workers", ["project_id": projectId]))
    }

    /// A queued spawn is dropped; a running worker is told to stop and retires.
    func cancelWorker(_ workerId: String) async throws {
        _ = try await client.request("cancel_worker", ["worker_id": workerId])
    }

    /// Sets the project's shared repository, or clears it with a nil url.
    func setProjectRepo(_ projectId: String, url: String?, branch: String) async throws {
        var fields: JSONDict = ["project_id": projectId, "url": url ?? NSNull()]
        if url != nil { fields["branch"] = branch }
        let reply = try await client.request("set_project_repo", fields)
        if let project = reply.dict("project").map(Project.init) { upsert(project) }
    }

    // MARK: Peers and linked projects

    func loadPeers() async throws {
        let reply = try await client.request("list_peers")
        peers = reply.list("peers").map(Peer.init)
    }

    /// Pairing, listening side: a one-time code for the other daemon to add.
    /// `url` is where the other daemon should dial; without it, the daemon
    /// offers its first non-loopback bind address.
    func createPeerInvite(name: String, url: String? = nil) async throws -> String {
        var fields: JSONDict = ["name": name]
        if let url { fields["url"] = url }
        let reply = try await client.request("create_peer_invite", fields)
        try? await loadPeers()
        guard let invite = reply.optStr("invite") else {
            throw DaemonError(code: "internal", message: "The Flotilla service did not return an invite.")
        }
        return invite
    }

    /// Pairing, dialing side: keeps a link open to the daemon that made the invite.
    func addPeer(name: String, invite: String) async throws {
        _ = try await client.request("add_peer", ["name": name, "invite": invite])
        try? await loadPeers()
    }

    func revokePeer(_ peerId: String) async throws {
        _ = try await client.request("revoke_peer", ["peer_id": peerId])
        try? await loadPeers()
    }

    func peerProjects(peerId: String) async throws -> [PeerProject] {
        let reply = try await client.request("list_peer_projects", ["peer_id": peerId])
        return reply.list("projects").map(PeerProject.init)
    }

    /// Links a project with one on a peer: an existing one, or a new one named like it.
    func linkProject(_ projectId: String, peerId: String, remoteProjectId: String?) async throws {
        var fields: JSONDict = ["project_id": projectId, "peer_id": peerId]
        if let remoteProjectId { fields["remote_project_id"] = remoteProjectId }
        let reply = try await client.request("link_project", fields)
        if let project = reply.dict("project").map(Project.init) { upsert(project) }
        await refresh()
    }

    func unlinkProject(_ projectId: String, peerId: String) async throws {
        let reply = try await client.request("unlink_project", ["project_id": projectId, "peer_id": peerId])
        if let project = reply.dict("project").map(Project.init) { upsert(project) }
        await refresh()
    }

    // MARK: Files

    /// The project's shared artifacts, newest first.
    /// A page of the project's files, newest first. `before` is the previous
    /// page's `nextBefore`. A daemon that does not page them sends every file
    /// and no `has_more`, which reads as nothing more to load.
    func listArtifacts(projectId: String, before: String? = nil) async throws -> ArtifactPage {
        var fields: JSONDict = ["project_id": projectId, "limit": Page.size]
        if let before { fields["before"] = before }
        let reply = try await client.request("list_artifacts", fields)
        return ArtifactPage(files: reply.list("artifacts").map(ArtifactFile.init),
                            hasMore: reply.bool("has_more"), nextBefore: reply.optStr("next_before"))
    }

    /// A file under the bot's own folder or its project's artifacts.
    func readFile(botId: String, path: String) async throws -> DaemonFile {
        let reply = try await client.request("read_file", ["bot_id": botId, "path": path])
        guard let row = reply.dict("file") else {
            throw DaemonError(code: "not_found", message: "The Flotilla service did not return the file.")
        }
        return DaemonFile(row)
    }

    // MARK: Tasks

    /// Every open task, and a page of closed ones; `moreClosed` when the page was full.
    func listTasks(botId: String, closedLimit: Int) async throws -> (tasks: [BotTask], moreClosed: Bool) {
        async let openReply = client.request("list_tasks", ["bot_id": botId, "state": "open"])
        async let closedReply = client.request("list_tasks", ["bot_id": botId, "state": "closed", "limit": closedLimit])
        let open = try await openReply.list("tasks").map(BotTask.init)
        let closed = try await closedReply.list("tasks").map(BotTask.init)
        // A daemon without the filter sends both kinds to each: keep each its own.
        return (open.filter(\.isOpen) + closed.filter { !$0.isOpen }, closed.count >= closedLimit)
    }

    /// The task with its whole request and result.
    func task(botId: String, taskId: String) async throws -> BotTask {
        let reply = try await client.request("get_task", ["bot_id": botId, "task_id": taskId])
        guard let row = reply.dict("task") else {
            throw DaemonError(code: "not_found", message: "The Flotilla service did not return the task.")
        }
        return BotTask(row)
    }

    func listRoutines(botId: String) async throws -> [Routine] {
        let reply = try await client.request("list_routines", ["bot_id": botId])
        return reply.list("routines").map(Routine.init)
    }

    // MARK: Decisions

    func loadDecision(_ id: String) async {
        guard let reply = try? await client.request("get_decision", ["decision_id": id]),
              let decision = reply.dict("decision").map(Decision.init) else { return }
        if let index = decisions.firstIndex(where: { $0.id == id }) {
            decisions[index] = decision
        } else {
            decisions.insert(decision, at: 0)
        }
    }

    /// Runs a request whose reply is the changed decision.
    func decide(_ type: String, _ fields: JSONDict) async throws {
        let reply = try await client.request(type, fields)
        if let decision = reply.dict("decision").map(Decision.init) { upsert(decision) }
    }

    /// Answer and settle in one step; the asking bots are told.
    func answerAndPublish(_ id: String, option: String?, text: String, reason: String?) async throws {
        var fields: JSONDict = ["decision_id": id, "ruling_text": text]
        if let option { fields["ruling_option"] = option }
        if let reason, !reason.isEmpty { fields["ruling_reason"] = reason }
        let decision = decisions.first { $0.id == id }
        let sha = decision?.grantsSha(for: option)
        if let sha { fields["grants_sha"] = sha }
        // Before anything is sent, so a refused Face ID leaves no draft behind.
        if let decision { try await confirmGrants(decision, option: option, action: .publish) }
        try await decide("answer_decision", fields)
        try await publish(id, grantsSha: sha, confirmed: true)
    }

    /// `grantsSha` echoes the granting option's sha the owner was shown.
    /// Publishing one that grants extras asks for Face ID first, unless the
    /// caller just did.
    func publish(_ id: String, grantsSha: String? = nil, confirmed: Bool = false) async throws {
        let decision = decisions.first { $0.id == id }
        if !confirmed, let decision { try await confirmGrants(decision, option: nil, action: .publish) }
        var item: JSONDict = ["decision_id": id]
        if let sha = grantsSha ?? decision?.grantsSha(for: nil) { item["grants_sha"] = sha }
        _ = try await client.request("publish_decisions", ["items": [item]])
        await loadDecision(id)
        await refreshCounts()
    }

    /// Confirms a ruling a bot relayed; one whose option grants extras asks for Face ID.
    func confirmRuling(_ decision: Decision) async throws {
        try await confirmGrants(decision, option: nil, action: .confirm)
        var fields: JSONDict = ["decision_id": decision.id]
        if let sha = decision.grantsSha(for: nil) { fields["grants_sha"] = sha }
        try await decide("confirm_decision", fields)
    }

    /// Face ID when ruling `option` (else the drafted one) grants extras (H-118, UX-023 decision 2).
    func confirmGrants(_ decision: Decision, option: String?, action: OwnerAuth.Action) async throws {
        guard let reason = grantsReason(decision, option: option, action: action) else { return }
        try await OwnerAuth.confirm(reason, action: action, computer: computerName)
    }

    /// "Publish this ruling? It grants DevOps: install." for a granting option, else nil (UX-032).
    func grantsReason(_ decision: Decision, option: String?, action: OwnerAuth.Action) -> String? {
        guard let key = option ?? decision.ruling?.option,
              let picked = decision.options.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }),
              !picked.grants.isEmpty else { return nil }
        // OptionGrant.words reads "Grants DevOps: install"; here it follows "It".
        let words = OptionGrant.words(picked.grants) { self.bot($0)?.name ?? $0 }.dropFirst("Grants ".count)
        return "\(action.question) It grants \(words)."
    }

    func comment(_ id: String, body: String) async throws {
        let reply = try await client.request("comment_decision", ["decision_id": id, "body": body])
        if let comment = reply.dict("comment").map(DecisionComment.init) { append(comment) }
    }
}
