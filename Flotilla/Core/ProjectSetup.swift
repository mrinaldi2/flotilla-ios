import Foundation
import Observation

// Creating a project from the phone (0.20, BG-Rules §7): name and board,
// columns (optional), lead, details (optional), review, creating, done. The
// plan and its checks live here, apart from the screens, so the tests hold
// them; `ProjectCreation` runs it against the daemon and reports each step.

extension AppStore {
    /// The guided flow needs a board from a preset and a lead from the start.
    var hasGuidedSetup: Bool {
        capabilities.contains("board_presets") && capabilities.contains("create_bot_lead") && canControl
    }
    var hasProjectDescription: Bool { capabilities.contains("project_description") }
    var hasRepoClone: Bool { capabilities.contains("project_repo_clone") }
}

// MARK: Boards

/// The boards the phone starts (decided 16 Oct): the daemon's presets, the
/// release-gated one as it is.
enum BoardTemplate: String, CaseIterable, Identifiable {
    case simpleReview = "simple_review", simple, releaseGated = "release_gated"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simpleReview: "Simple + Review"
        case .simple: "Simple"
        case .releaseGated: "Release-gated"
        }
    }

    var recommended: Bool { self == .simpleReview }

    /// How work flows on it, in a line (F1).
    var how: String {
        switch self {
        case .simpleReview: "Bots finish into Review. You approve to Done."
        case .simple: "Bots close their own cards."
        case .releaseGated: "You promote cards to Ready and approve releases with Face ID."
        }
    }

    /// Its visible columns as the daemon starts them (kanban/presets.rs);
    /// the hidden Cancelled column is never listed.
    var columns: [PlannedColumn] {
        func column(_ key: String, _ name: String, _ kind: Flotilla_Board_V1_ColumnKind, _ rule: String) -> PlannedColumn {
            PlannedColumn(key: key, name: name, kind: kind, rule: rule)
        }
        switch self {
        case .simple:
            return [column("todo", "To do", .open, "Anyone adds cards. The lead assigns them."),
                    column("doing", "Doing", .active, "The assignee works its card here, three at a time."),
                    column("done", "Done", .done, "Bots close their own cards.")]
        case .simpleReview:
            return [column("todo", "To do", .open, "Anyone adds cards. The lead assigns them."),
                    column("doing", "Doing", .active, "The assignee moves its card here when it starts, and back to To do if it needs you."),
                    column("review", "Review", .active, "Bots finish here. Waits for you."),
                    column("done", "Done", .done, "Only you move cards here, or the lead when it isn't the card's.")]
        case .releaseGated:
            return [column("inbox", "Inbox", .open, "New work lands here."),
                    column("ready", "Ready", .open, "You promote cards that are ready to start."),
                    column("doing", "Doing", .active, "One card per bot at a time."),
                    column("review", "Review", .active, "The code is reviewed."),
                    column("verify", "Verify", .active, "Testers check it on their computers."),
                    column("approval", "Awaiting owner", .active, "Waits for your release approval, with Face ID."),
                    column("deploying", "Deploying", .active, "The release goes out."),
                    column("done", "Done", .done, "Shipped.")]
        }
    }

    /// A release-gated board's guards key on its columns: only names change.
    var renameOnly: Bool { self == .releaseGated }
}

/// A column of the board being planned.
struct PlannedColumn: Identifiable, Equatable {
    let id = UUID()
    /// The preset's key, kept so the column keeps its rules; nil for one the
    /// owner added, which the daemon keys from its name.
    var key: String?
    var name: String
    var kind: Flotilla_Board_V1_ColumnKind
    /// What happens in it, in words (F2); empty for an added column.
    var rule: String = ""

    static func == (a: Self, b: Self) -> Bool {
        a.key == b.key && a.name == b.name && a.kind == b.kind && a.rule == b.rule
    }
}

// MARK: The plan

/// Where the lead runs: the project's own computer, or one it is paired with.
enum LeadComputer: Hashable {
    case here
    case peer(id: String, name: String)
}

struct ProjectPlan: Equatable {
    var name = ""
    var template = BoardTemplate.simpleReview
    var columns = BoardTemplate.simpleReview.columns
    /// The owner changed the columns: send them; else the preset's own.
    var columnsEdited = false
    var leadName = ""
    var engine = BotEngine.claudeCode
    var computer = LeadComputer.here
    var repoURL = ""
    var branch = "main"
    var folder = ""
    var description = ""

    mutating func choose(_ template: BoardTemplate) {
        guard template != self.template else { return }
        self.template = template
        columns = template.columns
        columnsEdited = false
    }

    /// "Thesis writing" → "Thesis Lead": the first word and Lead.
    static func suggestedLead(for name: String) -> String {
        let first = name.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return first.isEmpty ? "Lead" : "\(first.prefix(1).uppercased())\(first.dropFirst()) Lead"
    }

    /// "github.com/me/thesis" → "~/Developer/thesis".
    static func suggestedFolder(for url: String) -> String {
        let last = url.trimmed.split(separator: "/").last.map(String.init) ?? ""
        let name = last.hasSuffix(".git") ? String(last.dropLast(4)) : last
        return name.isEmpty ? "" : "~/Developer/\(name)"
    }

    /// The repository as git takes it: "github.com/me/x" gains https://.
    var cloneURL: String {
        let url = repoURL.trimmed
        if url.isEmpty || url.contains("://") || url.hasPrefix("/") || url.contains("@") { return url }
        return "https://\(url)"
    }

    var hasRepo: Bool { !repoURL.trimmed.isEmpty }
}

/// What stops a plan, step by step; nil when the step is fine.
enum PlanCheck {
    /// "You already have a project called Thesis writing."
    static func name(_ name: String, taken: [String]) -> String? {
        let name = name.trimmed
        if name.isEmpty { return "Give the project a name." }
        if taken.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return "You already have a project called \(name)."
        }
        return nil
    }

    /// "Thesis writing 2", the first free one.
    static func freeName(_ name: String, taken: [String]) -> String {
        let base = name.trimmed
        let lowered = Set(taken.map { $0.lowercased() })
        var n = 2
        while lowered.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    /// The daemon's rules for a custom board (BoardEnable.columns).
    static func columns(_ columns: [PlannedColumn], template: BoardTemplate) -> String? {
        if columns.contains(where: { $0.name.trimmed.isEmpty }) { return "Every column needs a name." }
        var seen = Set<String>()
        for column in columns where !seen.insert(column.name.trimmed.lowercased()).inserted {
            return "Two columns are named \(column.name.trimmed)."
        }
        if template.renameOnly { return nil }
        if !columns.contains(where: { $0.kind == .open }) { return "Keep at least one column for new work." }
        if !columns.contains(where: { $0.kind == .done }) { return "Keep at least one Done column." }
        return nil
    }

    static func lead(_ name: String) -> String? {
        name.trimmed.isEmpty ? "Give the lead a name." : nil
    }

    /// Clones go over https or from a folder on the computer (the daemon's
    /// git has no SSH keys), into a folder in the home.
    static func repository(_ plan: ProjectPlan) -> String? {
        guard plan.hasRepo else { return nil }
        let url = plan.cloneURL
        if url.contains(" ") { return "A repository address has no spaces." }
        if !(url.lowercased().hasPrefix("https://") || url.hasPrefix("/") || url.lowercased().hasPrefix("file://")) {
            return "Use the repository's https address: the computer clones without SSH keys."
        }
        let folder = plan.folder.trimmed
        if folder.isEmpty { return "Pick a folder to clone it into." }
        if !(folder.hasPrefix("~/") || folder.hasPrefix("/")) { return "Give the folder as ~/… or a full path." }
        return nil
    }

    static func description(_ text: String) -> String? {
        text.trimmed.utf8.count > 2048 ? "Keep the description under 2 KB." : nil
    }
}

// MARK: The daemon's side

/// `repo_clone`: a clone started, finished or failed.
struct RepoClone: Equatable {
    enum State: String { case cloning, done, failed }

    let projectId: String
    let state: State
    let path: String?
    let error: String?

    init(_ d: JSONDict) {
        projectId = d.str("project_id")
        state = State(rawValue: d.str("state")) ?? .failed
        path = d.optStr("path")
        error = d.optStr("error")
    }

    init(projectId: String, state: State, path: String? = nil, error: String? = nil) {
        self.projectId = projectId
        self.state = state
        self.path = path
        self.error = error
    }
}

extension AppStore {
    /// `board_enable {preset, columns}` (`board_presets`): the project's first
    /// board, on this computer.
    func enableBoard(projectId: String, template: BoardTemplate, columns: [PlannedColumn]?) async throws {
        var enable = Flotilla_Board_V1_BoardEnable()
        enable.projectID = projectId
        enable.preset = template.rawValue
        enable.columns = (columns ?? []).map { planned in
            var spec = Flotilla_Board_V1_ColumnSpec()
            if let key = planned.key { spec.key = key }
            spec.name = planned.name.trimmed
            spec.kind = template.renameOnly ? .unspecified : planned.kind
            return spec
        }
        guard case .board = try await boardCall(.boardEnable(enable), name: "board_enable") else {
            throw DaemonError(code: "decode", message: "The Flotilla service answered board_enable with something else.")
        }
    }

    /// `clone_project_repo` (`project_repo_clone`): starts the clone; its end
    /// arrives as a `repo_clone` push.
    func cloneProjectRepo(projectId: String, url: String, branch: String?, dest: String) async throws {
        repoClones[projectId] = nil
        var fields: JSONDict = ["project_id": projectId, "url": url, "dest": dest]
        if let branch, !branch.trimmed.isEmpty { fields["branch"] = branch.trimmed }
        _ = try await client.request("clone_project_repo", fields)
    }

    /// The clone's end: at once if it already came, else when it comes.
    func cloneFinished(projectId: String) async -> RepoClone {
        if let clone = repoClones[projectId], clone.state != .cloning { return clone }
        return await withCheckedContinuation { cloneWaiters[projectId, default: []].append($0) }
    }

    func cloneUpdated(_ clone: RepoClone) {
        repoClones[clone.projectId] = clone
        guard clone.state != .cloning else { return }
        for waiter in cloneWaiters.removeValue(forKey: clone.projectId) ?? [] { waiter.resume(returning: clone) }
    }

    /// The connection dropped: nobody waits for a push that won't come on it.
    func cloneConnectionLost() {
        for (projectId, waiters) in cloneWaiters {
            let lost = RepoClone(projectId: projectId, state: .failed, error: "The connection to \(computerName) dropped during the clone.")
            for waiter in waiters { waiter.resume(returning: lost) }
        }
        cloneWaiters = [:]
    }
}

// MARK: Running it

/// One project being created, step by step (F6).
@MainActor
@Observable
final class ProjectCreation: Identifiable {
    enum Step: String, CaseIterable {
        case board, clone, lead, reading
    }

    enum State: Equatable {
        case waiting, running, done, failed(String), skipped
    }

    nonisolated let id = UUID()
    let plan: ProjectPlan
    let computerId: String
    private(set) var projectId: String?
    private(set) var leadId: String?
    private(set) var states: [Step: State] = [:]
    /// The owner left the screen: tell them when it's ready.
    var inBackground = false

    init(plan: ProjectPlan, computerId: String) {
        self.plan = plan
        self.computerId = computerId
        for step in Step.allCases { states[step] = .waiting }
        if !plan.hasRepo { states[.clone] = .skipped }
    }

    var steps: [Step] { Step.allCases.filter { states[$0] != .skipped } }
    var finished: Bool { steps.allSatisfy { states[$0] == .done } }
    var failed: Bool { steps.contains { if case .failed = states[$0] { true } else { false } } }
    /// The board exists, so the project does: what failed after it can be retried from its card.
    var projectExists: Bool { projectId != nil && states[.board] == .done }
    var done: Int { steps.filter { states[$0] == .done }.count }
    /// The first step that failed, to retry from a card.
    var failedStep: Step? { steps.first { if case .failed = states[$0] { true } else { false } } }

    func label(_ step: Step) -> String {
        switch step {
        case .board: "Board and columns"
        case .clone: states[.clone] == .done ? "Repository cloned" : "Cloning the repository"
        case .lead: "Starting \(plan.leadName.trimmed)"
        case .reading: "\(plan.leadName.trimmed) reads the project"
        }
    }

    func detail(_ step: Step, computerName: String) -> String {
        if case .failed(let why) = states[step] { return why }
        switch step {
        case .board: return "\(plan.template.title) · \(plan.columns.count) columns"
        case .clone: return "\(plan.repoURL.trimmed) → \(plan.folder.trimmed)"
        case .lead:
            let place: String = switch plan.computer {
            case .here: computerName
            case .peer(_, let name): name
            }
            return "\(plan.engine.label) on \(place)"
        case .reading: return plan.description.trimmed.isEmpty ? "Its first look at the board" : "The description and the board"
        }
    }

    /// Creates the project, its board, the clone and the lead, in that order
    /// (the board before any link: two boards can't be linked). Stops at the
    /// first failure that leaves nothing to build on.
    func run(on store: AppStore) async {
        if projectId == nil || states[.board] != .done {
            guard await runBoard(on: store) else { return }
        }
        if case .waiting = states[.clone] { await runClone(on: store) }
        if states[.lead] != .done {
            guard await runLead(on: store) else { return }
        }
        await watchLead(on: store)
    }

    /// Runs one failed step again, then what follows it.
    func retry(_ step: Step, on store: AppStore) async {
        if step == .clone { states[.clone] = .waiting }
        await run(on: store)
    }

    private func runBoard(on store: AppStore) async -> Bool {
        states[.board] = .running
        do {
            if projectId == nil {
                let project = try await store.createProject(name: plan.name.trimmed, description: plan.description)
                projectId = project.id
            }
            guard let projectId else { return false }
            try await store.enableBoard(projectId: projectId, template: plan.template,
                                        columns: plan.columnsEdited ? plan.columns : nil)
            states[.board] = .done
            return true
        } catch {
            states[.board] = .failed(error.localizedDescription)
            return false
        }
    }

    private func runClone(on store: AppStore) async {
        guard let projectId else { return }
        states[.clone] = .running
        do {
            let branch = plan.branch.trimmed
            try await store.cloneProjectRepo(projectId: projectId, url: plan.cloneURL, branch: branch, dest: plan.folder.trimmed)
            let clone = await store.cloneFinished(projectId: projectId)
            guard clone.state == .done else {
                states[.clone] = .failed(clone.error ?? "The clone failed.")
                return
            }
            // Workers check the repository out too (set_project_repo).
            try? await store.setProjectRepo(projectId, url: plan.cloneURL, branch: branch.isEmpty ? "main" : branch)
            states[.clone] = .done
        } catch {
            states[.clone] = .failed(error.localizedDescription)
        }
    }

    private func runLead(on store: AppStore) async -> Bool {
        guard let projectId else { return false }
        states[.lead] = .running
        do {
            var peerId: String?
            if case .peer(let id, _) = plan.computer {
                if !(store.projects.first { $0.id == projectId }?.links.contains { $0.peerId == id } ?? false) {
                    try await store.linkProject(projectId, peerId: id, remoteProjectId: nil)
                }
                peerId = id
            }
            let bot = try await store.createBot(projectId: projectId, name: plan.leadName.trimmed, description: "", instructions: "",
                                                avatar: nil, engine: plan.engine, peerId: peerId, lead: true)
            leadId = bot.id
            states[.lead] = .done
            return true
        } catch {
            states[.lead] = .failed(error.localizedDescription)
            return false
        }
    }

    /// The lead's first turn: it starts, works through its introduction,
    /// then waits. A lead on another computer stands in here without a
    /// session, so its start is as far as this phone can see.
    private func watchLead(on store: AppStore) async {
        guard let leadId else { return }
        states[.reading] = .running
        if case .peer = plan.computer {
            states[.reading] = .done
            return
        }
        var worked = false
        for _ in 0..<600 {
            let state = store.bot(leadId)?.state
            if state == .working { worked = true }
            if worked, state == .ready || state == .waitingForUser {
                states[.reading] = .done
                return
            }
            if state == .crashed || state == .authFailed {
                states[.reading] = .failed("\(plan.leadName.trimmed) stopped: \(store.bot(leadId)?.stateReason ?? "")")
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        // Five minutes on: it runs, it is just slow to finish its first turn.
        states[.reading] = .done
    }
}

/// The projects being created, and the last one finished, so the tab can
/// mark its card (F7) and a card can offer to retry what failed.
@MainActor
@Observable
final class ProjectCreations {
    private(set) var running: [ProjectCreation] = []
    /// The card to mark New, until the owner opens it or adds its first card.
    var highlighted: (computerId: String, projectId: String)?

    func start(_ creation: ProjectCreation, on store: AppStore) {
        running.append(creation)
        Task {
            await creation.run(on: store)
            finish(creation)
        }
    }

    func retry(_ creation: ProjectCreation, step: ProjectCreation.Step, on store: AppStore) {
        Task {
            await creation.retry(step, on: store)
            finish(creation)
        }
    }

    /// The creation of a project, while it runs or after it failed.
    func creation(computerId: String, projectId: String) -> ProjectCreation? {
        running.first { $0.computerId == computerId && $0.projectId == projectId }
    }

    func dismiss(_ creation: ProjectCreation) {
        running.removeAll { $0 === creation }
    }

    func isHighlighted(_ card: HomeCard) -> Bool {
        highlighted.map { $0.computerId == card.computerId && $0.projectId == card.row.projectID } ?? false
    }

    private func finish(_ creation: ProjectCreation) {
        guard creation.finished || creation.failed else { return }
        if let projectId = creation.projectId, creation.projectExists {
            highlighted = (creation.computerId, projectId)
        }
        if creation.inBackground {
            let name = creation.plan.name.trimmed
            let body = creation.failed ? "Something didn't finish. Open its card to retry." : "Board made · \(creation.plan.leadName.trimmed) running"
            Notifier.post(title: creation.failed ? "\(name) needs a look" : "\(name) is ready", body: body,
                          id: "created-\(creation.id)", info: ["computer": creation.computerId], inForeground: false)
        }
        if creation.finished { running.removeAll { $0 === creation } }
    }
}
