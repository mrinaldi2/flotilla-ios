import Foundation
import Observation
import SwiftProtobuf

// The project's plan on the phone (0.21.0, flotilla#43): goals, initiatives,
// epics and features with their stages and documents, read from the board's
// home (`plan_*` board requests, capability `plan_v1`). The phone reads the
// tree and the documents, rules gates (with Face ID) and starts goals and
// initiatives; documents are written on the computer.

typealias PlanNode = Flotilla_Board_V1_PlanNode
typealias PlanTree = Flotilla_Board_V1_PlanTree
typealias PlanStage = Flotilla_Board_V1_PlanStage
typealias PlanKind = Flotilla_Board_V1_PlanKind
typealias PlanDoc = Flotilla_Board_V1_PlanDoc
typealias PlanGate = Flotilla_Board_V1_PlanGate
typealias PlanNodeDetail = Flotilla_Board_V1_PlanNodeDetail
typealias PlanChange = Flotilla_Board_V1_PlanChange
typealias PlanResult = Flotilla_Board_V1_PlanResult

// MARK: What the home serves

/// The 0.21 capabilities, each gating its own part: an older home keeps
/// the phone as it was.
enum PlanCapability {
    /// The plan requests, `plan_change`, `plan_node_id` on cards.
    static let plan = "plan_v1"
    /// Task and Design cards; Epic, Feature and Chore are refused.
    static let itemTypes = "item_types_v2"
    /// Research columns, the `start.research` guard and Design links.
    static let research = "column_research"
    /// `PLAN_GATE` rows in Needs you.
    static let attention = "attention_plan"
}

extension AppStore {
    var hasPlan: Bool { capabilities.contains(PlanCapability.plan) || PlanFixture.isOn }
    var hasItemTypesV2: Bool { capabilities.contains(PlanCapability.itemTypes) }
    var hasResearchColumn: Bool { capabilities.contains(PlanCapability.research) }
    var hasPlanAttention: Bool { capabilities.contains(PlanCapability.attention) || PlanFixture.isOn }
}

/// The card types New item offers: the 0.21 four on a home that takes them,
/// else the list an older home knows.
enum CardTypes {
    static let current: [(Flotilla_Board_V1_ItemType, String)] = [(.task, "Task"), (.design, "Design"), (.bug, "Bug"), (.spike, "Spike")]
    static let legacy: [(Flotilla_Board_V1_ItemType, String)] = [(.feature, "Feature"), (.bug, "Bug"), (.chore, "Chore"),
                                                                 (.spike, "Spike"), (.epic, "Epic")]

    static func offered(v2: Bool) -> [(Flotilla_Board_V1_ItemType, String)] { v2 ? current : legacy }
    static func defaultType(v2: Bool) -> Flotilla_Board_V1_ItemType { v2 ? .task : .feature }
}

// MARK: Requests

/// The plan's requests, behind a protocol so the models run in tests without a daemon.
@MainActor
protocol PlanService: AnyObject {
    func planTree(projectId: String) async throws -> PlanTree
    func planNode(_ id: String) async throws -> PlanNodeDetail
    func planCreate(_ create: Flotilla_Board_V1_PlanCreate) async throws -> PlanResult
    func planRule(_ rule: Flotilla_Board_V1_PlanRule) async throws -> PlanResult
    func planDocRead(_ read: Flotilla_Board_V1_PlanDocRead) async throws -> Flotilla_Board_V1_PlanDocContent
    /// `plan_change` pushes for a project reach `handler` while it follows
    /// (the home sends them to connections that watch the project's board).
    func followPlan(projectId: String, _ handler: @escaping (PlanChange) -> Void) async -> UUID
    func unfollowPlan(projectId: String, _ token: UUID)
}

extension AppStore: PlanService {
    private func unexpectedPlan(_ name: String) -> DaemonError {
        DaemonError(code: "decode", message: "The Flotilla service answered \(name) with something else.")
    }

    func planTree(projectId: String) async throws -> PlanTree {
        #if DEBUG
        if let tree = PlanFixture.tree(projectId: projectId) { return tree }
        #endif
        var get = Flotilla_Board_V1_PlanGet()
        get.projectID = projectId
        guard case .plan(let tree) = try await boardCall(.planGet(get), name: "plan_get") else { throw unexpectedPlan("plan_get") }
        return tree
    }

    func planNode(_ id: String) async throws -> PlanNodeDetail {
        #if DEBUG
        if let detail = PlanFixture.node(id) { return detail }
        #endif
        var get = Flotilla_Board_V1_PlanNodeGet()
        get.id = id
        guard case .planNode(let detail) = try await boardCall(.planNodeGet(get), name: "plan_node_get") else {
            throw unexpectedPlan("plan_node_get")
        }
        return detail
    }

    func planCreate(_ create: Flotilla_Board_V1_PlanCreate) async throws -> PlanResult {
        guard case .planned(let result) = try await boardCall(.planCreate(create), name: "plan_create") else {
            throw unexpectedPlan("plan_create")
        }
        return result
    }

    func planRule(_ rule: Flotilla_Board_V1_PlanRule) async throws -> PlanResult {
        guard case .planned(let result) = try await boardCall(.planRule(rule), name: "plan_rule") else { throw unexpectedPlan("plan_rule") }
        return result
    }

    func planDocRead(_ read: Flotilla_Board_V1_PlanDocRead) async throws -> Flotilla_Board_V1_PlanDocContent {
        #if DEBUG
        if let content = PlanFixture.doc(read) { return content }
        #endif
        guard case .planDoc(let content) = try await boardCall(.planDocRead(read), name: "plan_doc_read") else {
            throw unexpectedPlan("plan_doc_read")
        }
        return content
    }

    func followPlan(projectId: String, _ handler: @escaping (PlanChange) -> Void) async -> UUID {
        let token = UUID()
        planListeners[projectId, default: [:]][token] = handler
        // A quiet board listener keeps the project watched while the plan shows,
        // and lets the board's own screens share that watch.
        boardListeners[projectId, default: [:]][token] = { _ in }
        _ = try? await watchBoard(projectId: projectId)
        return token
    }

    func unfollowPlan(projectId: String, _ token: UUID) {
        planListeners[projectId]?[token] = nil
        if planListeners[projectId]?.isEmpty ?? false { planListeners[projectId] = nil }
        stopListening(projectId: projectId, token)
    }

    /// A `plan_change` push, to the screens following its project.
    func planPushed(_ change: PlanChange) {
        for handler in (planListeners[change.projectID] ?? [:]).values { handler(change) }
    }

    /// A document of the project's repository (see `PlanDocReader`).
    func planDocument(projectId: String, path: String, sha: String?) async throws -> DocumentFile {
        try await PlanDocReader.read(projectId: projectId, path: path, sha: sha, with: self)
    }
}

/// Reads a plan document a chunk at a time (`plan_doc_read`).
enum PlanDocReader {
    /// Every chunk at the commit the first was read at, so the parts can't
    /// come from two commits; `sha` nil starts from the default branch's head.
    @MainActor
    static func read(projectId: String, path: String, sha: String?, with service: PlanService) async throws -> DocumentFile {
        var data = Data()
        var mime = ""
        var pinned = sha
        while true {
            var read = Flotilla_Board_V1_PlanDocRead()
            read.projectID = projectId
            read.path = path
            if let pinned, !pinned.isEmpty { read.sha = pinned }
            read.offset = UInt64(data.count)
            let chunk = try await service.planDocRead(read)
            if data.isEmpty {
                mime = chunk.mime
                if !chunk.sha.isEmpty { pinned = chunk.sha }
            }
            data.append(chunk.data)
            if chunk.data.isEmpty || UInt64(data.count) >= chunk.total { break }
        }
        return DocumentFile(data: data, mime: mime.isEmpty ? AppStore.mime(for: path) : mime)
    }
}

// MARK: Words

/// A plan's nodes and stages in the glossary's words.
enum PlanWords {
    static func kind(_ kind: PlanKind) -> String {
        switch kind {
        case .goal: "Goal"
        case .initiative: "Initiative"
        case .epic: "Epic"
        case .feature: "Feature"
        default: "Node"
        }
    }

    /// The letter on a node's tile: G, I, E, F.
    static func glyph(_ kind: PlanKind) -> String { String(kind == .unspecified ? "?" : self.kind(kind).prefix(1)) }

    static func stage(_ stage: PlanStage) -> String {
        switch stage {
        case .define: "Define"
        case .active: "Active"
        case .met: "Met"
        case .dropped: "Dropped"
        case .proposed: "Proposed"
        case .research: "Research"
        case .prd: "PRD"
        case .design: "Design"
        case .hld: "HLD"
        case .lld: "LLD"
        case .running: "Running"
        case .build: "Build"
        case .released: "Released"
        case .done: "Done"
        default: "—"
        }
    }

    /// The stages a document is approved at.
    static let gateStages: Set<PlanStage> = [.prd, .design, .hld, .lld]

    /// How a node's pill reads on the tree.
    enum PillTone: Equatable {
        /// Waits for the owner.
        case you
        /// A document stage being written.
        case gate
        case research
        case plain
        case finished
    }

    /// "You" when it waits for the owner, else its stage: "Build 3/5" for a
    /// feature with cards.
    static func pill(_ node: PlanNode) -> (text: String, tone: PillTone) {
        if node.hasGate { return ("You", .you) }
        switch node.stage {
        case .build where node.cardsTotal > 0: return ("Build \(node.cardsDone)/\(node.cardsTotal)", .plain)
        case .research: return ("Research", .research)
        case .met, .released, .done: return (stage(node.stage), .finished)
        default: return (stage(node.stage), gateStages.contains(node.stage) ? .gate : .plain)
        }
    }

    /// The stages a kind moves through, in order, for the stage bar.
    static func steps(_ kind: PlanKind) -> [PlanStage] {
        switch kind {
        case .goal: [.define, .active, .met]
        case .initiative: [.research, .prd, .running, .done]
        case .epic: [.research, .design, .hld, .running, .done]
        case .feature: [.lld, .build, .released]
        default: []
        }
    }

    enum StepState: Equatable { case done, now, next }

    /// Each step's state: before the node's stage done, its stage now, the
    /// rest to come. A proposed or dropped node has no step now.
    static func stepStates(_ node: PlanNode) -> [(stage: PlanStage, state: StepState)] {
        let steps = steps(node.kind)
        let index = steps.firstIndex(of: node.stage)
        return steps.enumerated().map { offset, stage in
            guard let index else { return (stage, .next) }
            return (stage, offset < index ? .done : offset == index ? .now : .next)
        }
    }

    /// "HLD waits for you", "Proposal waits for you".
    static func waits(_ gate: PlanGate) -> String {
        switch gate.stage {
        case .proposed: "Proposal waits for you"
        case .research: "Research skip waits for you"
        case .design: "Design waits for you"
        default: "\(stage(gate.stage)) waits for you"
        }
    }

    /// The gate screen's title: "Approve HLD", "Accept initiative", "Skip research?".
    static func gateTitle(_ gate: PlanGate) -> String {
        switch gate.stage {
        case .proposed: "Accept initiative"
        case .research: "Skip research"
        case .design: "Approve design"
        default: "Approve \(stage(gate.stage))"
        }
    }

    /// "Creates 3 features": what approving makes, by what the stage proposes.
    static func creates(_ gate: PlanGate) -> String? {
        let count = gate.children.count
        guard count > 0 else { return nil }
        let (one, many): (String, String) = switch gate.stage {
        case .prd: ("epic", "epics")
        case .hld: ("feature", "features")
        case .lld: ("task", "tasks")
        default: ("item", "items")
        }
        return "Creates \(count) \(count == 1 ? one : many)"
    }

    /// The submitter: "Game Lead", from `bot:<id>`.
    static func submitter(_ gate: PlanGate, botName: (String) -> String?) -> String {
        let actor = gate.submittedBy
        if actor.hasPrefix("bot:") { return botName(String(actor.dropFirst(4))) ?? "the lead" }
        return actor == "user" ? "you" : "the lead"
    }

    /// "References" from `research/references.md`, "Prototype results" from
    /// `prototype-results.md`.
    static func docTitle(_ path: String) -> String {
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let words = stem.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        let lower = words.lowercased()
        if ["prd", "hld", "lld"].contains(lower) { return lower.uppercased() }
        return words.capitalizedFirst
    }

    static func docKind(_ kind: Flotilla_Board_V1_PlanDocKind) -> String {
        switch kind {
        case .goal: "Goal statement"
        case .research: "Research"
        case .prd: "PRD"
        case .design: "Design"
        case .hld: "HLD"
        case .lld: "LLD"
        case .guideline: "Guideline"
        default: "Document"
        }
    }

    /// "Approved 15 Oct", "Changed since approval", "Not approved yet".
    static func docState(_ doc: PlanDoc) -> String {
        if doc.changedSinceApproval { return "Changed since approval" }
        if doc.hasApprovedAt { return "Approved \(doc.approvedAt.date.formatted(.dateTime.day().month(.abbreviated)))" }
        // Guidelines are read, never approved.
        if doc.kind == .guideline { return "Guideline" }
        return doc.kind == .research ? (doc.hasItemID ? doc.itemID : "Research") : "Not approved yet"
    }

    /// "Research · closed 14 Oct", "Research · open", "Research · skipped".
    static func research(_ research: Flotilla_Board_V1_PlanResearch) -> String {
        switch research.state {
        case .closed:
            let when = research.hasClosedAt ? " \(research.closedAt.date.formatted(.dateTime.day().month(.abbreviated)))" : ""
            return "Research · closed\(when)"
        case .skipped: return "Research · skipped"
        default: return "Research · open"
        }
    }
}

// MARK: The tree

/// One row of the tree: a node and how deep it sits.
struct PlanRow: Identifiable, Equatable {
    let node: PlanNode
    let depth: Int
    var id: String { node.id }
}

enum PlanOutline {
    /// Every node under its parent, siblings by rank, parents first. A node
    /// whose parent isn't in the tree sits at the top, so nothing is lost.
    static func rows(_ nodes: [PlanNode]) -> [PlanRow] {
        let ids = Set(nodes.map(\.id))
        var children: [String: [PlanNode]] = [:]
        var roots: [PlanNode] = []
        for node in nodes {
            if node.hasParentID, ids.contains(node.parentID), node.parentID != node.id {
                children[node.parentID, default: []].append(node)
            } else {
                roots.append(node)
            }
        }
        func ordered(_ list: [PlanNode]) -> [PlanNode] {
            list.sorted { ($0.rank, $0.id) < ($1.rank, $1.id) }
        }
        var rows: [PlanRow] = []
        var seen: Set<String> = []
        func walk(_ node: PlanNode, depth: Int) {
            guard seen.insert(node.id).inserted else { return }
            rows.append(PlanRow(node: node, depth: depth))
            for child in ordered(children[node.id] ?? []) { walk(child, depth: depth + 1) }
        }
        for root in ordered(roots) { walk(root, depth: 0) }
        return rows
    }

    /// What waits for the owner, the oldest first: pinned over the tree.
    static func waiting(_ nodes: [PlanNode]) -> [PlanNode] {
        nodes.filter(\.hasGate).sorted { ($0.gate.submittedAt.date, $0.id) < ($1.gate.submittedAt.date, $1.id) }
    }

    /// A node's children, in order.
    static func children(of id: String, in nodes: [PlanNode]) -> [PlanNode] {
        nodes.filter { $0.hasParentID && $0.parentID == id }.sorted { ($0.rank, $0.id) < ($1.rank, $1.id) }
    }

    /// The nodes a card can belong to: the initiatives, epics and features
    /// still going that have a board (on one board, when it is named). A
    /// proposed initiative takes cards once the owner accepts it.
    static func homes(for boardId: String? = nil, in nodes: [PlanNode]) -> [PlanRow] {
        rows(nodes).filter { row in
            let node = row.node
            guard node.kind != .goal, node.hasBoardID, !node.boardID.isEmpty,
                  ![.proposed, .dropped, .done, .released].contains(node.stage) else {
                return false
            }
            return boardId.map { node.boardID == $0 } ?? true
        }
    }

    /// Goals an initiative can go under.
    static func openGoals(_ nodes: [PlanNode]) -> [PlanNode] {
        nodes.filter { $0.kind == .goal && ![.dropped, .met].contains($0.stage) }.sorted { ($0.rank, $0.id) < ($1.rank, $1.id) }
    }
}

/// The plan of a project on screen: read once, kept current by `plan_change`.
@MainActor @Observable
final class PlanModel {
    enum Phase: Equatable {
        case loading, loaded
        case failed(String)
    }

    let projectId: String
    private(set) var tree: PlanTree?
    private(set) var phase = Phase.loading

    @ObservationIgnored private let service: PlanService
    @ObservationIgnored private var token: UUID?

    init(projectId: String, service: PlanService) {
        self.projectId = projectId
        self.service = service
    }

    /// The Plan shows only for a project whose owner turned planning on.
    var enabled: Bool { tree?.enabled ?? false }
    var nodes: [PlanNode] { tree?.nodes ?? [] }
    var rows: [PlanRow] { PlanOutline.rows(nodes) }
    var waiting: [PlanNode] { PlanOutline.waiting(nodes) }
    func node(_ id: String) -> PlanNode? { nodes.first { $0.id == id } }

    func start() async {
        if token == nil {
            token = await service.followPlan(projectId: projectId) { [weak self] change in self?.received(change) }
        }
        await reload()
    }

    func stop() {
        if let token { service.unfollowPlan(projectId: projectId, token) }
        token = nil
    }

    func reload() async {
        do {
            tree = try await service.planTree(projectId: projectId)
            phase = .loaded
        } catch {
            if tree == nil { phase = .failed(error.localizedDescription) }
        }
    }

    /// A node changed or appeared. An older copy (lower version) is ignored.
    func received(_ change: PlanChange) {
        guard change.projectID == projectId, change.hasNode, var current = tree else { return }
        let node = change.node
        if let index = current.nodes.firstIndex(where: { $0.id == node.id }) {
            guard node.version >= current.nodes[index].version else { return }
            current.nodes[index] = node
        } else {
            current.nodes.append(node)
        }
        tree = current
    }

    /// A node the phone just created or ruled, before its push arrives.
    func take(_ node: PlanNode) {
        var change = PlanChange()
        change.projectID = projectId
        change.node = node
        received(change)
    }
}

/// One node's screen: the node, its history and cards, live.
@MainActor @Observable
final class PlanNodeModel {
    let projectId: String
    let nodeId: String
    private(set) var detail: PlanNodeDetail?
    private(set) var failure: String?

    @ObservationIgnored private let service: PlanService
    @ObservationIgnored private var token: UUID?

    init(projectId: String, nodeId: String, service: PlanService) {
        self.projectId = projectId
        self.nodeId = nodeId
        self.service = service
    }

    var node: PlanNode? { detail?.node }

    func start() async {
        if token == nil {
            token = await service.followPlan(projectId: projectId) { [weak self] change in
                guard let self, change.node.id == self.nodeId else { return }
                Task { await self.reload() }
            }
        }
        await reload()
    }

    func stop() {
        if let token { service.unfollowPlan(projectId: projectId, token) }
        token = nil
    }

    func reload() async {
        do {
            detail = try await service.planNode(nodeId)
            failure = nil
        } catch {
            if detail == nil { failure = error.localizedDescription }
        }
    }
}

// MARK: Ruling a gate

/// How a plan change came out, in words.
enum PlanOutcome: Equatable {
    case done(PlanNode)
    case refused([String])
    case conflict(PlanNode)

    init(_ result: PlanResult) {
        switch result.outcome {
        case .done(let node)?: self = .done(node)
        case .refused(let refused)?: self = .refused(MoveOutcome.lines(refused.unmet))
        case .conflict(let node)?: self = .conflict(node)
        case nil: self = .refused(["The Flotilla service didn’t say how it went. Look at the plan again."])
        }
    }
}

/// The two answers a waiting node offers, by what waits: a document gate,
/// a proposed initiative, or the lead's request to skip research.
struct PlanAsk: Equatable {
    enum Kind: Equatable { case document, proposal, researchSkip }

    let kind: Kind

    init(_ stage: PlanStage) {
        switch stage {
        case .proposed: kind = .proposal
        case .research: kind = .researchSkip
        default: kind = .document
        }
    }

    /// The filled button: Review opens the gate; the others rule at once.
    var yes: String {
        switch kind {
        case .document: "Review"
        case .proposal: "Accept"
        case .researchSkip: "Skip"
        }
    }

    var no: String {
        switch kind {
        case .document: "Later"
        case .proposal: "Decline"
        case .researchSkip: "Keep research"
        }
    }

    /// "HLD gate", "Proposal", "Research".
    static func kindWord(_ stage: PlanStage?) -> String {
        guard let stage else { return "Plan" }
        switch stage {
        case .proposed: return "Proposal"
        case .research: return "Research"
        default: return "\(PlanWords.stage(stage)) gate"
        }
    }

    /// The Face ID question for ruling yes.
    func question(_ node: PlanNode) -> String {
        switch kind {
        case .document: "Approve the \(PlanWords.stage(node.gate.stage)) of \(node.title)?"
        case .proposal: "Accept the initiative \(node.title)?"
        case .researchSkip: "Skip research for \(node.title)?"
        }
    }

    /// The note sheet's words for ruling no (and for a skip's reason).
    var noteTitle: String {
        switch kind {
        case .document: "Send back"
        case .proposal: "Decline"
        case .researchSkip: "Keep research"
        }
    }
}

/// The gate screen: the features to create (each ticked), Approve with Face
/// ID, Send back with a note.
@MainActor @Observable
final class GateModel {
    let node: PlanNode
    /// The children left unticked, by their index in the gate's list.
    var leftOut: Set<Int> = []
    var note = ""
    private(set) var busy = false
    private(set) var failure: [String] = []
    /// The node after the ruling: the screen closes.
    private(set) var ruled: PlanNode?

    @ObservationIgnored private let service: PlanService
    @ObservationIgnored private let confirm: (String) async throws -> Void

    /// `confirm` asks for Face ID (`OwnerAuth.confirm`) before approving.
    init(node: PlanNode, service: PlanService, confirm: @escaping (String) async throws -> Void) {
        self.node = node
        self.service = service
        self.confirm = confirm
    }

    var ask: PlanAsk { PlanAsk(node.gate.stage) }

    func toggle(_ index: Int) {
        if leftOut.contains(index) { leftOut.remove(index) } else { leftOut.insert(index) }
    }

    /// Sending back, declining or keeping research needs a note for the lead.
    var canSendBack: Bool { !note.trimmed.isEmpty && !busy }

    /// The request: `leave_out` lists the unticked children, in order.
    func rule(approve: Bool) -> Flotilla_Board_V1_PlanRule {
        var rule = Flotilla_Board_V1_PlanRule()
        rule.id = node.id
        rule.expectedVersion = node.version
        rule.approve = approve
        if approve {
            rule.leaveOut = leftOut.filter { $0 >= 0 && $0 < node.gate.children.count }.sorted().map(UInt32.init)
        }
        if !note.trimmed.isEmpty { rule.note = note.trimmed }
        return rule
    }

    func approve() async {
        busy = true
        failure = []
        defer { busy = false }
        do {
            try await confirm(ask.question(node))
        } catch {
            failure = [error.localizedDescription]
            return
        }
        await send(rule(approve: true))
    }

    func sendBack() async {
        guard canSendBack else { return }
        busy = true
        failure = []
        defer { busy = false }
        await send(rule(approve: false))
    }

    private func send(_ rule: Flotilla_Board_V1_PlanRule) async {
        do {
            switch PlanOutcome(try await service.planRule(rule)) {
            case .done(let node): ruled = node
            case .refused(let lines): failure = lines
            case .conflict(let node):
                failure = node.hasGate && node.gate.round != self.node.gate.round
                    ? ["The lead submitted it again meanwhile. Open it again to see this round."]
                    : ["\(node.title) changed meanwhile. Open it again, then rule."]
            }
        } catch {
            failure = [error.localizedDescription]
        }
    }
}

// MARK: Starting a goal or an initiative

/// New goal and New initiative (+ on the Plan): `plan_create`, no Face ID.
@MainActor @Observable
final class PlanCreateModel {
    let projectId: String
    let kind: PlanKind
    var title = ""
    /// A goal's outcome and measure; an initiative's why.
    var summary = ""
    /// A goal's deadline, in the owner's words.
    var due = ""
    /// An initiative's goal.
    var goalId: String
    /// An initiative's lead; empty for the project's lead.
    var lead = ""
    private(set) var busy = false
    private(set) var failure: [String] = []

    @ObservationIgnored private let service: PlanService

    init(projectId: String, kind: PlanKind, goalId: String = "", service: PlanService) {
        self.projectId = projectId
        self.kind = kind
        self.goalId = goalId
        self.service = service
    }

    var canCreate: Bool { !title.trimmed.isEmpty && !busy && (kind == .goal || !goalId.isEmpty) }

    var request: Flotilla_Board_V1_PlanCreate {
        var create = Flotilla_Board_V1_PlanCreate()
        create.projectID = projectId
        create.kind = kind
        create.title = title.trimmed
        if !summary.trimmed.isEmpty { create.summary = summary.trimmed }
        if kind == .goal, !due.trimmed.isEmpty { create.due = due.trimmed }
        if kind == .initiative {
            create.parentID = goalId
            if !lead.isEmpty { create.lead = lead }
        }
        return create
    }

    /// The new node, or nil with `failure` said.
    func create() async -> PlanNode? {
        guard canCreate else { return nil }
        busy = true
        failure = []
        defer { busy = false }
        do {
            switch PlanOutcome(try await service.planCreate(request)) {
            case .done(let node): return node
            case .refused(let lines): failure = lines
            case .conflict: failure = ["The plan changed meanwhile. Try again."]
            }
        } catch {
            failure = [error.localizedDescription]
        }
        return nil
    }
}

// MARK: Documents

/// A document's opening, for the gate: its first section heading and the
/// paragraph under it, cut to a few lines.
enum PlanExcerpt {
    static func of(_ markdown: String, limit: Int = 280) -> (heading: String?, text: String) {
        var heading: String?
        var paragraph: [String] = []
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                if !paragraph.isEmpty { break }
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                // The document's own title (`# HLD`) isn't the section.
                if line.hasPrefix("##") || heading == nil { heading = title }
                continue
            }
            if line.isEmpty || (line.hasPrefix("<!--") && line.hasSuffix("-->")) {
                if !paragraph.isEmpty { break }
                continue
            }
            paragraph.append(line)
        }
        var text = paragraph.joined(separator: " ")
        if text.count > limit {
            let cut = text.prefix(limit)
            text = (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
        }
        return (heading, text)
    }
}

// MARK: Cards: Code research and Design links

/// A task's or a bug's "Code research" section (0.21.0): what its bot found
/// in the code before starting. The home reads it the same way: a `##`
/// heading starting with the name, and text under it that isn't a hint.
enum CodeResearch {
    static let heading = "Code research"

    /// Cards that pass Research before Doing.
    static func applies(to type: Flotilla_Board_V1_ItemType) -> Bool { type == .task || type == .bug }

    /// The section's text, hints left out; empty when not written, nil when
    /// the description has no such section.
    static func section(in description: String) -> String? {
        var inside = false
        var found = false
        var lines: [String] = []
        for line in description.components(separatedBy: .newlines) {
            if line.hasPrefix("#") {
                if inside { break }
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased()
                inside = title.hasPrefix(heading.lowercased())
                found = found || inside
            } else if inside {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("<!--") && trimmed.hasSuffix("-->") { continue }
                lines.append(line)
            }
        }
        guard found else { return nil }
        return lines.joined(separator: "\n").trimmed
    }

    /// The description without that section, so it shows once.
    static func removing(from description: String) -> String {
        var inside = false
        var kept: [String] = []
        for line in description.components(separatedBy: .newlines) {
            if line.hasPrefix("#") {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased()
                inside = title.hasPrefix(heading.lowercased())
                if inside { continue }
            }
            if !inside { kept.append(line) }
        }
        return kept.joined(separator: "\n").trimmed
    }

    /// The home's code for "no code research is recorded yet".
    static let unmetCode = "start.research"

    /// Whether any column the card could move to waits for its research.
    static func blocks(_ check: Flotilla_Board_V1_MoveCheck) -> BoardUnmet? {
        check.columns.lazy.flatMap(\.unmet).first { $0.code == unmetCode }
    }
}

extension Flotilla_Board_V1_ItemDetail {
    /// The Design cards this task builds (`LINK_KIND_DESIGN`), by id.
    var designIds: [String] {
        links.filter { $0.kind == .design && !$0.ref.isEmpty }.map(\.ref).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
}

/// "design.md · 3 mockups": what a Design card carries.
enum DesignWords {
    static func line(_ attachments: [ItemAttachment]) -> String {
        let live = attachments.filter { !$0.removed }
        let docs = live.filter { $0.kind == "doc" || $0.name.lowercased().hasSuffix(".md") }
        let images = live.filter { $0.kind == "image" }
        var parts = docs.prefix(1).map { $0.name.isEmpty ? (($0.path as NSString).lastPathComponent) : $0.name }
        if docs.count > 1 { parts.append("\(docs.count - 1) more document\(docs.count == 2 ? "" : "s")") }
        if !images.isEmpty { parts.append("\(images.count) mockup\(images.count == 1 ? "" : "s")") }
        let other = live.count - docs.count - images.count
        if other > 0 { parts.append("\(other) file\(other == 1 ? "" : "s")") }
        return parts.isEmpty ? "No documents yet" : parts.joined(separator: " · ")
    }
}

// MARK: Screenshots without a 0.21 home

/// Debug only: `-planFixture <folder>` serves the plan from the vendored
/// contract fixtures (`response.plan.json`, `response.plan_node.json`,
/// `response.plan_doc.json`), for screenshots before a home serves the plan.
enum PlanFixture {
    static var isOn: Bool {
        #if DEBUG
        return folder != nil
        #else
        return false
        #endif
    }

    #if DEBUG
    private static var folder: URL? {
        UserDefaults.standard.string(forKey: "planFixture").map { URL(fileURLWithPath: $0) }
    }

    private static func response(_ name: String) -> Flotilla_Board_V1_BoardResponse.OneOf_Response? {
        guard let folder, let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8),
              let envelope = try? Flotilla_Wire_V1_Envelope(jsonString: text, options: HomeJSON.options),
              case .boardResponse(let response)? = envelope.body else { return nil }
        return response.response
    }

    static func tree(projectId: String) -> PlanTree? {
        guard case .plan(var tree)? = response("response.plan.json") else { return nil }
        tree.projectID = projectId
        for index in tree.nodes.indices { tree.nodes[index].projectID = projectId }
        return tree
    }

    static func node(_ id: String) -> PlanNodeDetail? {
        guard isOn else { return nil }
        let tree = tree(projectId: "")
        if case .planNode(var detail)? = response("response.plan_node.json"), detail.node.id == id {
            if let live = tree?.nodes.first(where: { $0.id == id }) { detail.node = live }
            return detail
        }
        guard let node = tree?.nodes.first(where: { $0.id == id }) else { return nil }
        var detail = PlanNodeDetail()
        detail.node = node
        return detail
    }

    static func doc(_ read: Flotilla_Board_V1_PlanDocRead) -> Flotilla_Board_V1_PlanDocContent? {
        guard isOn else { return nil }
        var content = Flotilla_Board_V1_PlanDocContent()
        content.path = read.path
        content.sha = read.hasSha ? read.sha : "fixture"
        content.mime = "text/markdown"
        let title = PlanWords.docTitle(read.path)
        let text = "# \(title)\n\n## Context\n\nThe approved design asks for a HUD that reads in under a second at the edge of vision. "
            + "Playtests showed players miss stamina and off-screen threats.\n\n## Approach\n\nThree features, one per signal.\n"
        content.data = Data(text.utf8)
        content.total = UInt64(content.data.count)
        return content
    }
    #endif
}
