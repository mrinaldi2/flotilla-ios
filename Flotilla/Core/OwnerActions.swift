import Foundation
import Observation

// Owner actions (H-117 R1) and push requests (0.24.0, `push_requests_v1`): a
// bot proposes an exact command, or asks for a push, and only the owner runs
// it. The phone runs them now, on its device credential, where it only
// counted them before (0.24.0). The hello names the feature `owner_actions`,
// so the daemon sends the cards and lets this client run one.

/// A push a bot asks for: what `git push origin <branch>:<target>` sends.
struct PushDetails: Equatable {
    let branch: String
    let target: String
    /// "owner/name" for a GitHub origin, else the origin's URL.
    let repo: String
    /// The branch's head.
    let commit: String
    let files: Int
    let additions: Int
    let deletions: Int
    let itemId: String?

    init(_ d: JSONDict) {
        branch = d.str("branch")
        target = d.str("target")
        repo = d.str("repo")
        commit = d.str("commit")
        files = d.int("files")
        additions = d.int("additions")
        deletions = d.int("deletions")
        itemId = d.optStr("item_id")
    }
}

/// One proposed command or push request, as `owner_action_get` reads it.
struct OwnerAction: Identifiable, Equatable {
    let id: String
    let projectId: String
    /// `bot:<id>`.
    let proposedBy: String
    let itemId: String?
    let decisionId: String?
    /// The daemon id of the computer it runs on.
    let targetMachine: String
    /// That computer's name, when it isn't the one that answered.
    let targetName: String?
    let shell: String
    let cwd: String
    let content: String
    let reason: String
    let timeoutS: Int
    /// The hash of what the owner is shown: the run sends it back.
    let sha256: String
    let flags: [String]
    /// proposed, running, succeeded, failed, timed_out, rejected, withdrawn or expired.
    let state: String
    let createdAt: Date?
    let expiresAt: Date?
    let runBy: String?
    let finishedAt: Date?
    let exitCode: Int?
    let outputTail: String?
    let rejectReason: String?
    /// command or push.
    let kind: String
    let push: PushDetails?

    init(_ d: JSONDict) {
        id = d.str("id")
        projectId = d.str("project_id")
        proposedBy = d.str("proposed_by")
        itemId = d.optStr("item_id")
        decisionId = d.optStr("decision_id")
        targetMachine = d.str("target_machine")
        targetName = d.optStr("target_name")
        shell = d.str("shell")
        cwd = d.str("cwd")
        content = d.str("content")
        reason = d.str("reason")
        timeoutS = d.int("timeout_s")
        sha256 = d.str("sha256")
        flags = d.strings("flags")
        state = d.str("state")
        createdAt = d.date("created_at")
        expiresAt = d.date("expires_at")
        runBy = d.optStr("run_by")
        finishedAt = d.date("finished_at")
        exitCode = d.optInt("exit_code")
        outputTail = d.optStr("output_tail")
        rejectReason = d.optStr("reject_reason")
        let push = d.dict("push").map(PushDetails.init)
        kind = d.optStr("kind") ?? (push == nil ? "command" : "push")
        self.push = push
    }

    var isPush: Bool { kind == "push" && push != nil }
    /// Still waiting for the owner's Run (or Push) or Reject.
    var isOpen: Bool { state == "proposed" }
    var isRunning: Bool { state == "running" }
    var isFinished: Bool { !isOpen && !isRunning }

    /// The proposing bot's id, from `bot:<id>`.
    var botId: String? { proposedBy.hasPrefix("bot:") ? String(proposedBy.dropFirst(4)) : nil }

    /// The card it is for: the push's, else the proposal's.
    var card: String? { push?.itemId ?? itemId }
}

/// Owner actions in the glossary's words: "Push" and "Run".
enum OwnerActionWords {
    /// The filled button.
    static func run(_ action: OwnerAction) -> String { action.isPush ? "Push" : "Run" }

    /// "Automation Tester asks you to push its branch", "Backend Dev asks you to run a command".
    static func title(_ action: OwnerAction, botName: String?) -> String {
        let who = botName ?? "A bot"
        return action.isPush ? "\(who) asks you to push its branch" : "\(who) asks you to run a command"
    }

    /// "a334dd34 · 2 files, +208 −3".
    static func pushLine(_ push: PushDetails) -> String {
        var parts: [String] = []
        if !push.commit.isEmpty { parts.append(String(push.commit.prefix(8))) }
        parts.append("\(push.files) file\(push.files == 1 ? "" : "s"), +\(push.additions) −\(push.deletions)")
        return parts.joined(separator: " · ")
    }

    /// "To mrinaldi2/flotilla, branch → target" when the target differs.
    static func destination(_ push: PushDetails) -> String {
        let to = push.target.isEmpty || push.target == push.branch ? push.branch : "\(push.branch) → \(push.target)"
        return push.repo.isEmpty ? to : "\(push.repo) · \(to)"
    }

    /// Where a finished one stands: "Pushed", "Failed · exit 1", "Rejected".
    static func state(_ action: OwnerAction) -> String {
        switch action.state {
        case "proposed": return action.isPush ? "Waiting for your push" : "Waiting for you to run it"
        case "running": return action.isPush ? "Pushing…" : "Running…"
        case "succeeded": return action.isPush ? "Pushed" : "Done"
        case "failed": return action.exitCode.map { "Failed · exit \($0)" } ?? "Failed"
        case "timed_out": return "Timed out"
        case "rejected": return "Rejected"
        case "withdrawn": return "Withdrawn by the bot"
        case "expired": return "Expired"
        default: return action.state.capitalizedFirst
        }
    }

    static func tone(_ action: OwnerAction) -> Tone {
        switch action.state {
        case "proposed": .needsYou
        case "running": .working
        case "succeeded": .ready
        case "failed", "timed_out": .failed
        default: .quiet
        }
    }

    /// "expires in 23 h".
    static func expiry(_ action: OwnerAction, now: Date = Date()) -> String? {
        guard action.isOpen, let expires = action.expiresAt else { return nil }
        let left = expires.timeIntervalSince(now)
        guard left > 0 else { return "expired" }
        let hours = Int(left / 3600)
        return hours >= 1 ? "expires in \(hours) h" : "expires in \(max(1, Int(left / 60))) min"
    }

    /// What Face ID asks before it runs.
    static func question(_ action: OwnerAction) -> String {
        if let push = action.push { return "Push \(push.branch)?" }
        return "Run \(PermissionWords.middleTruncated(action.content.split(separator: "\n").first.map(String.init) ?? action.content, limit: 60))?"
    }

    /// What a Push card says it does, under its buttons.
    static func promise(_ action: OwnerAction) -> String {
        action.isPush
            ? "Runs exactly this command as you, from the bot’s worktree, once. Pushes to main are never offered here."
            : "Runs exactly this command as you, once, on \(action.targetName ?? "its computer")."
    }

    /// The flags the daemon raised: a path a bot can write that isn't pinned.
    static func flags(_ action: OwnerAction) -> String? {
        action.flags.isEmpty ? nil : action.flags.joined(separator: "\n")
    }
}

/// What the phone does with owner actions on one computer.
@MainActor
protocol OwnerActionService: AnyObject {
    func ownerAction(_ id: String) async throws -> OwnerAction
    func ownerActions(projectId: String?) async throws -> [OwnerAction]
    /// `owner_action_run {id, sha256}`: the hash the owner was shown.
    func runOwnerAction(id: String, sha256: String) async throws -> OwnerAction
    func rejectOwnerAction(id: String, reason: String?) async throws -> OwnerAction
}

extension AppStore: OwnerActionService {
    /// The daemon serves owner actions (H-117) to a client that renders them.
    var hasOwnerActions: Bool { capabilities.contains("owner_actions") }
    /// Bots ask the owner for pushes (0.24.0).
    var hasPushRequests: Bool { capabilities.contains("push_requests_v1") }

    func ownerAction(_ id: String) async throws -> OwnerAction {
        try decodeAction(try await client.request("owner_action_get", ["id": id]))
    }

    func ownerActions(projectId: String?) async throws -> [OwnerAction] {
        var fields: JSONDict = [:]
        if let projectId { fields["project_id"] = projectId }
        return try await client.request("owner_action_list", fields).list("actions").map(OwnerAction.init)
    }

    func runOwnerAction(id: String, sha256: String) async throws -> OwnerAction {
        try decodeAction(try await client.request("owner_action_run", ["id": id, "sha256": sha256]))
    }

    func rejectOwnerAction(id: String, reason: String?) async throws -> OwnerAction {
        var fields: JSONDict = ["id": id]
        if let reason, !reason.trimmed.isEmpty { fields["reason"] = reason.trimmed }
        return try decodeAction(try await client.request("owner_action_reject", fields))
    }

    private func decodeAction(_ reply: JSONDict) throws -> OwnerAction {
        guard let row = reply.dict("action") else {
            throw DaemonError(code: "decode", message: "The Flotilla service answered without the action.")
        }
        return OwnerAction(row)
    }

    /// `owner_action_update`: the open screens and Needs you follow it.
    func ownerActionUpdated(_ frame: JSONDict) {
        guard let action = frame.dict("action").map(OwnerAction.init) else { return }
        ownerActionUpdates[action.id] = action
        onHomeChanged?()
    }

    /// `owner_action_output`: the redacted output while it runs.
    func ownerActionOutput(_ frame: JSONDict) {
        let id = frame.str("id")
        var text = (ownerActionOutputs[id] ?? "") + frame.str("chunk")
        // The last 64 KB, as the daemon keeps.
        if text.utf8.count > 65_536 { text = String(text.suffix(60_000)) }
        ownerActionOutputs[id] = text
    }
}

/// One owner action on screen: read, then Run (Face ID) or Reject (a reason).
@MainActor @Observable
final class OwnerActionModel {
    let actionId: String
    private(set) var action: OwnerAction?
    private(set) var busy = false
    private(set) var failure: String?
    private(set) var loadFailure: String?

    /// The service that answered for it, and the one that runs it: the computer
    /// it targets, when the phone talks to that one too (a run isn't forwarded).
    @ObservationIgnored private let service: OwnerActionService
    @ObservationIgnored private let runner: (OwnerAction) -> OwnerActionService?
    @ObservationIgnored private let confirm: (String) async throws -> Void

    init(actionId: String, service: OwnerActionService, runner: @escaping (OwnerAction) -> OwnerActionService? = { _ in nil },
         confirm: @escaping (String) async throws -> Void) {
        self.actionId = actionId
        self.service = service
        self.runner = runner
        self.confirm = confirm
    }

    func load() async {
        do {
            action = try await service.ownerAction(actionId)
            loadFailure = nil
        } catch {
            loadFailure = error.localizedDescription
        }
    }

    /// A push from the daemon.
    func take(_ update: OwnerAction?) {
        guard let update, update.id == actionId else { return }
        action = update
    }

    var canAct: Bool { action?.isOpen == true && !busy }

    /// Face ID, then the run with the hash the owner was shown.
    func run() async {
        guard let action, canAct else { return }
        busy = true
        failure = nil
        defer { busy = false }
        do {
            try await confirm(OwnerActionWords.question(action))
        } catch {
            failure = error.localizedDescription
            return
        }
        do {
            if let there = runner(action) {
                // Its own copy on the computer it targets, by that copy's hash.
                let copy = try await there.ownerAction(action.id)
                self.action = try await there.runOwnerAction(id: copy.id, sha256: copy.sha256)
            } else {
                self.action = try await service.runOwnerAction(id: action.id, sha256: action.sha256)
            }
        } catch {
            failure = error.localizedDescription
            await load()
        }
    }

    func reject(reason: String) async {
        guard let action, canAct else { return }
        busy = true
        failure = nil
        defer { busy = false }
        do {
            self.action = try await service.rejectOwnerAction(id: action.id, reason: reason)
        } catch {
            failure = error.localizedDescription
            await load()
        }
    }
}
