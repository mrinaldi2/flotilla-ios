import SwiftUI

// The project's Plan (0.21.0, flotilla#43): the tree of goals, initiatives,
// epics and features with what waits for the owner on top; a node with its
// stages, research, design and documents read in place; a gate ruled with
// Face ID or sent back with a note; and a new goal or initiative from +.
// Documents are written on the computer, by the bots.

/// Where a row of the Plan leads.
enum PlanRoute: Hashable {
    case node(String)
    case gate(String)
}

extension Flotilla_Board_V1_PlanKind: Identifiable {
    var id: Int { rawValue }
}

/// A plan document to open in a sheet.
private struct PlanDocSheet: Identifiable {
    let source: DocumentSource
    var id: String { "\(source)" }
}

// MARK: Glyphs and pills

/// A node's kind as a small coloured tile: G, I, E, F.
struct PlanGlyph: View {
    let kind: PlanKind
    var size: CGFloat = 22

    static func tint(_ kind: PlanKind) -> Color {
        switch kind {
        case .goal: Color(light: 0x6A4C93, dark: 0x8A6BB8)
        case .initiative: Color(light: 0x0C3062, dark: 0x3A62A8)
        case .epic: Color(light: 0x0E6E66, dark: 0x1F8F85)
        case .feature: Color(light: 0x8F5A1E, dark: 0xB8762E)
        default: Color(.systemGray)
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(Self.tint(kind))
            .frame(width: size, height: size)
            .overlay {
                Text(PlanWords.glyph(kind))
                    .font(.system(size: size * 0.5, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// A kind as a system symbol, where a menu can't draw a tile.
enum PlanKindSymbol {
    static func of(_ kind: PlanKind) -> String {
        switch kind {
        case .goal: "scope"
        case .initiative: "square.stack.3d.up"
        case .epic: "square.stack"
        case .feature: "puzzlepiece"
        default: "circle"
        }
    }
}

extension PlanWords.PillTone {
    var tone: Tone {
        switch self {
        case .you: .needsYou
        case .gate: .away
        case .research: .working
        case .plain: .quiet
        case .finished: .ready
        }
    }
}

/// One node on the tree: its tile, its title, its stage.
struct PlanTreeRow: View {
    let node: PlanNode
    var depth = 0

    var body: some View {
        let pill = PlanWords.pill(node)
        HStack(spacing: 10) {
            PlanGlyph(kind: node.kind)
            Text(node.title)
                .font(.subheadline.weight(depth < 2 ? .bold : .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Pill(text: pill.text, tone: pill.tone.tone)
        }
        .padding(.leading, CGFloat(depth) * 16)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(PlanWords.kind(node.kind)): \(node.title), \(pill.tone == .you ? "waits for you" : pill.text)")
    }
}

/// "HLD waits for you · Combat HUD clarity · 2 h ago", with Review.
struct PlanWaitingRow: View {
    let node: PlanNode

    var body: some View {
        ItemRow(title: PlanWords.waits(node.gate), subtitle: [node.title, node.gate.submittedAt.date.relative].joined(separator: " · "),
                titleTone: .needsYou) {
            Circle().fill(Tone.needsYou.color.opacity(0.18)).frame(width: 26, height: 26)
                .overlay { Text("!").font(.system(size: 13, weight: .heavy)).foregroundStyle(Tone.needsYou.text) }
                .accessibilityHidden(true)
        } trailing: {
            Text("Review").font(.subheadline.weight(.semibold)).foregroundStyle(Tone.needsYou.text)
        }
    }
}

// MARK: The tree

/// The Plan segment of a project: what waits for you, then the tree.
struct PlanPane: View {
    @Bindable var model: PlanModel
    let computer: Computer

    var body: some View {
        List {
            switch model.phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Color.errorText)
            case .loaded:
                if !model.waiting.isEmpty {
                    Section {
                        ForEach(model.waiting, id: \.id) { node in
                            NavigationLink(value: PlanRoute.gate(node.id)) { PlanWaitingRow(node: node) }
                                .accessibilityIdentifier("plan-waiting-\(node.id)")
                        }
                    } header: {
                        SectionTitle("Waits for you", count: model.waiting.count)
                    }
                }
                Section {
                    if model.rows.isEmpty {
                        EmptyNote(text: "No goals yet. + starts one.", systemImage: "scope")
                    }
                    ForEach(model.rows) { row in
                        NavigationLink(value: PlanRoute.node(row.node.id)) { PlanTreeRow(node: row.node, depth: row.depth) }
                            .accessibilityIdentifier("plan-node-\(row.node.id)")
                    }
                } header: {
                    SectionTitle("Plan")
                }
                if let guidelines = model.tree?.guidelines, !guidelines.isEmpty {
                    PlanDocsSection(title: "Guidelines", docs: guidelines, projectId: model.projectId)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.reload() }
        .navigationDestination(for: PlanRoute.self) { route in
            switch route {
            case .node(let id): PlanNodeScreen(projectId: model.projectId, nodeId: id).computerEnvironment(computer)
            case .gate(let id): PlanGateScreen(projectId: model.projectId, nodeId: id).computerEnvironment(computer)
            }
        }
    }
}

/// Documents of the repository, each read in place.
struct PlanDocsSection: View {
    let title: String
    let docs: [PlanDoc]
    let projectId: String
    @State private var opened: PlanDocSheet?

    var body: some View {
        Section {
            ForEach(docs, id: \.path) { doc in
                Button { opened = PlanDocSheet(source: PlanDocs.source(doc, projectId: projectId)) } label: {
                    ItemRow(title: PlanWords.docTitle(doc.path), subtitle: PlanDocs.subtitle(doc)) {
                        IconTile(systemImage: PlanDocs.symbol(doc.path), tone: doc.changedSinceApproval ? .needsYou : nil)
                    } trailing: {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.secondaryText)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the document")
            }
        } header: {
            SectionTitle(title)
        }
        .sheet(item: $opened) { sheet in DocumentScreen(source: sheet.source) }
    }
}

enum PlanDocs {
    /// The approved commit when there is one, so the owner reads what was approved.
    static func source(_ doc: PlanDoc, projectId: String) -> DocumentSource {
        .planDoc(projectId: projectId, path: doc.path, sha: doc.hasApprovedSha ? doc.approvedSha : nil,
                 name: (doc.path as NSString).lastPathComponent)
    }

    /// "HLD · Changed since approval", "SP-12 · references.md".
    static func subtitle(_ doc: PlanDoc) -> String {
        let file = (doc.path as NSString).lastPathComponent
        if doc.kind == .research { return [doc.hasItemID ? doc.itemID : nil, file].compactMap { $0 }.joined(separator: " · ") }
        if doc.kind == .guideline { return file }
        return [file, PlanWords.docState(doc)].joined(separator: " · ")
    }

    static func symbol(_ path: String) -> String {
        DocumentKind(mime: "", name: path) == .html ? "globe" : "doc.text"
    }
}

// MARK: A node

/// The stage bar: done, now, to come, in words as well as colour.
struct PlanStageBar: View {
    let node: PlanNode

    var body: some View {
        let steps = PlanWords.stepStates(node)
        HStack(alignment: .top, spacing: 4) {
            ForEach(steps, id: \.stage) { step in
                VStack(alignment: .leading, spacing: 5) {
                    Capsule()
                        .fill(color(step.state))
                        .frame(height: 4)
                    Text(PlanWords.stage(step.stage))
                        .font(.caption.weight(step.state == .now ? .bold : .medium))
                        .foregroundStyle(step.state == .next ? Color.secondaryText : Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stages: " + steps.map { step in
            switch step.state {
            case .done: "\(PlanWords.stage(step.stage)) done"
            case .now: "\(PlanWords.stage(step.stage)) now"
            case .next: PlanWords.stage(step.stage)
            }
        }.joined(separator: ", "))
    }

    private func color(_ state: PlanWords.StepState) -> Color {
        switch state {
        case .done: Tone.ready.color
        case .now: Color.askButton
        case .next: Color(.systemFill)
        }
    }
}

/// A node: where it stands, its research, its design, its documents, its
/// children and its cards.
struct PlanNodeScreen: View {
    @Environment(AppStore.self) private var store
    let projectId: String
    let nodeId: String
    @State private var model: PlanNodeModel?
    /// The whole tree, for the node's parent and children.
    @State private var tree: [PlanNode] = []

    private var parent: PlanNode? {
        guard let node = model?.node, node.hasParentID else { return nil }
        return tree.first { $0.id == node.parentID }
    }

    var body: some View {
        Group {
            if let node = model?.node {
                content(node, detail: model?.detail)
            } else if let failure = model?.failure {
                ContentUnavailableView("Couldn’t open \(nodeId)", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(model?.node.map { PlanWords.kind($0.kind) } ?? "Plan")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil { model = PlanNodeModel(projectId: projectId, nodeId: nodeId, service: store) }
            await model?.start()
            await loadTree()
        }
        .onDisappear { model?.stop() }
    }

    private func content(_ node: PlanNode, detail: PlanNodeDetail?) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    if let parent { Text(parent.title).font(.footnote).foregroundStyle(Color.secondaryText) }
                    Text(node.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                }
                if !PlanWords.steps(node.kind).isEmpty, node.stage != .dropped {
                    PlanStageBar(node: node).padding(.vertical, 4)
                }
                if node.stage == .dropped || node.stage == .proposed {
                    Pill(text: PlanWords.stage(node.stage), tone: node.stage == .dropped ? .quiet : .needsYou)
                }
                if node.stage == .dropped, let why = PlanControls.dropReason(detail?.history ?? []) {
                    Text("Dropped: “\(why)”").font(.callout).foregroundStyle(Color.secondaryText)
                }
                if !node.summary.isEmpty { LinkedText(markdown: node.summary).font(.callout) }
                if node.hasDue, !node.due.isEmpty { LabeledContent("By", value: node.due) }
                if node.hasLead, !node.lead.isEmpty { LabeledContent("Lead", value: store.bot(node.lead)?.name ?? node.lead) }
            }
            if node.hasGate {
                Section {
                    NavigationLink(value: PlanRoute.gate(node.id)) { PlanWaitingRow(node: node) }
                }
            }
            // A dropped node's open research and design stopped with it.
            if node.hasResearch, node.stage != .dropped || node.research.state != .open { research(node) }
            if node.kind == .epic, node.stage != .dropped || !node.docs.filter({ $0.kind == .design }).isEmpty {
                design(node, cards: detail?.cards ?? [])
            }
            let docs = node.docs.filter { $0.kind != .research && !(node.kind == .epic && $0.kind == .design) }
            if !docs.isEmpty { PlanDocsSection(title: "Documents", docs: docs, projectId: projectId) }
            children(node)
            cards(node, detail?.cards ?? [])
            controls(node)
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await model?.reload()
            await loadTree()
        }
    }

    /// The owner's own moves: a goal's stage, and Drop.
    @ViewBuilder private func controls(_ node: PlanNode) -> some View {
        let step = PlanControls.goalStep(node)
        let canStep = step != nil && store.canControl
        let canDrop = PlanControls.canDrop(node) && store.canApprove
        if canStep || canDrop || !controlFailure.isEmpty {
            Section {
                if let step, store.canControl {
                    Button {
                        if step.stage == .met { confirmingMet = true } else { moveGoal(step.stage) }
                    } label: {
                        Label(step.title, systemImage: step.stage == .met ? "checkmark.seal" : "play.circle")
                    }
                    .disabled(acting)
                    .accessibilityIdentifier("plan-goal-step")
                }
                if canDrop {
                    Button(role: .destructive) { dropping = true } label: { Label("Drop…", systemImage: "xmark.circle") }
                        .disabled(acting)
                        .accessibilityIdentifier("plan-drop")
                }
                ForEach(controlFailure, id: \.self) { line in
                    Label(line, systemImage: "xmark.octagon").font(.footnote).foregroundStyle(Color.errorText)
                }
            }
            .confirmationDialog("Mark \(node.title) met?", isPresented: $confirmingMet, titleVisibility: .visible) {
                Button("Mark met") { moveGoal(.met) }
            } message: {
                Text("The goal is done. Add another goal when there is more to do.")
            }
            .sheet(isPresented: $dropping) {
                PlanDropSheet(node: node) { reason in
                    dropping = false
                    drop(reason)
                }
            }
        }
    }

    @State private var acting = false
    @State private var confirmingMet = false
    @State private var dropping = false
    @State private var controlFailure: [String] = []

    private func moveGoal(_ stage: PlanStage) {
        acting = true
        Task {
            controlFailure = await model?.moveGoal(to: stage) ?? []
            if controlFailure.isEmpty { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            acting = false
        }
    }

    private func drop(_ reason: String) {
        acting = true
        let computer = store.computerName
        Task {
            controlFailure = await model?.drop(reason: reason) { question in
                try await OwnerAuth.confirm(question, action: .dropPlan, computer: computer)
            } ?? []
            if controlFailure.isEmpty {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await loadTree()
            }
            acting = false
        }
    }

    private func loadTree() async {
        if let nodes = try? await store.planTree(projectId: projectId).nodes { tree = nodes }
    }

    /// Research: its documents and its spikes, how it closed or why it was skipped.
    @ViewBuilder private func research(_ node: PlanNode) -> some View {
        let research = node.research
        let docs = node.docs.filter { $0.kind == .research }
        let documented = Set(docs.compactMap { $0.hasItemID ? $0.itemID : nil })
        let open = research.spikes.filter { !documented.contains($0) }
        Section {
            if research.state == .skipped {
                Text(research.hasSkippedReason ? "Skipped: “\(research.skippedReason)”" : "Skipped by you.")
                    .font(.callout).foregroundStyle(Color.secondaryText)
            }
            ForEach(docs, id: \.path) { doc in PlanDocRow(doc: doc, projectId: projectId) }
            ForEach(open, id: \.self) { spike in
                NavigationLink { ItemView(itemId: spike, projectId: projectId) } label: {
                    ItemRow(title: spike, subtitle: "Spike · no document yet") { IconTile(systemImage: "magnifyingglass") }
                }
            }
            if docs.isEmpty && open.isEmpty && research.state == .open {
                EmptyNote(text: "No spikes yet. The lead opens them on the board.", systemImage: "magnifyingglass")
            }
        } header: {
            SectionTitle(PlanWords.research(research))
        }
    }

    /// An epic's design: its status, its document and its Design cards.
    @ViewBuilder private func design(_ node: PlanNode, cards: [BoardCard]) -> some View {
        let docs = node.docs.filter { $0.kind == .design }
        let tickets = cards.filter { $0.type == .design }
        Section {
            ForEach(docs, id: \.path) { doc in PlanDocRow(doc: doc, projectId: projectId) }
            ForEach(tickets, id: \.id) { card in
                NavigationLink { ItemView(itemId: card.id, projectId: projectId) } label: {
                    ItemRow(title: card.title, subtitle: [card.hasAssignee ? store.bot(card.assignee)?.name : nil,
                                                          Release.PlanItem.column(card.columnKey)].compactMap { $0 }.joined(separator: " · ")) {
                        IconTile(systemImage: "paintbrush.pointed")
                    }
                }
            }
            if docs.isEmpty && tickets.isEmpty {
                EmptyNote(text: node.stage == .research ? "Design starts once research closes." : "No design yet.",
                          systemImage: "paintbrush.pointed")
            }
        } header: {
            SectionTitle("Design · \(Self.designStatus(node))")
        }
    }

    /// "approved", "waits for you", "in progress", "not started".
    static func designStatus(_ node: PlanNode) -> String {
        if node.hasGate, node.gate.stage == .design { return "waits for you" }
        if node.docs.contains(where: { $0.kind == .design && $0.hasApprovedSha }) { return "approved" }
        switch node.stage {
        case .dropped: return "dropped"
        case .design: return "in progress"
        case .research, .proposed: return "not started"
        default: return "done"
        }
    }

    @ViewBuilder private func children(_ node: PlanNode) -> some View {
        let kids = PlanOutline.children(of: node.id, in: tree)
        if !kids.isEmpty {
            Section {
                ForEach(kids, id: \.id) { child in
                    NavigationLink(value: PlanRoute.node(child.id)) { PlanTreeRow(node: child) }
                }
            } header: {
                SectionTitle(PlanWords.kind(kids[0].kind) + "s", count: kids.count)
            }
        }
    }

    /// A node's own cards but its research spikes and design tickets: a feature's tasks.
    @ViewBuilder private func cards(_ node: PlanNode, _ cards: [BoardCard]) -> some View {
        let spikes = Set(node.research.spikes)
        let shown = cards.filter { !spikes.contains($0.id) && !(node.kind == .epic && $0.type == .design) }
        if !shown.isEmpty {
            Section {
                ForEach(shown, id: \.id) { card in
                    NavigationLink { ItemView(itemId: card.id, projectId: projectId) } label: {
                        ItemRow(title: "\(card.id) · \(card.title)", subtitle: Release.PlanItem.column(card.columnKey)) {
                            IconTile(systemImage: Release.PlanItem.column(card.columnKey) == "Done" ? "checkmark.circle" : "square.stack")
                        }
                    }
                }
            } header: {
                SectionTitle("Cards", count: node.cardsTotal > 0 ? Int(node.cardsTotal) : shown.count)
            } footer: {
                if node.cardsTotal > 0 { Text("\(node.cardsDone) of \(node.cardsTotal) done").foregroundStyle(Color.secondaryText) }
            }
        }
    }
}

/// One document, read in place: "References · SP-12 · references.md".
struct PlanDocRow: View {
    let doc: PlanDoc
    let projectId: String
    @State private var opened: PlanDocSheet?

    var body: some View {
        Button { opened = PlanDocSheet(source: PlanDocs.source(doc, projectId: projectId)) } label: {
            ItemRow(title: PlanWords.docTitle(doc.path), subtitle: PlanDocs.subtitle(doc)) {
                IconTile(systemImage: PlanDocs.symbol(doc.path), tone: doc.changedSinceApproval ? .needsYou : nil)
            } trailing: {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.secondaryText)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the document")
        .sheet(item: $opened) { sheet in DocumentScreen(source: sheet.source) }
    }
}

// MARK: A gate

/// Ruling on what waits: the document's opening, the children it creates
/// (untick to leave one out), Approve with Face ID, Send back with a note.
struct PlanGateScreen: View {
    @Environment(AppStore.self) private var store
    let projectId: String
    let nodeId: String
    @State private var node: PlanNodeModel?

    var body: some View {
        Group {
            if let current = node?.node {
                if current.hasGate {
                    GateContent(projectId: projectId, node: current) { Task { await node?.reload() } }
                        .id("\(current.id)/\(current.version)")
                } else {
                    ContentUnavailableView {
                        Label("Nothing waits for you", systemImage: "checkmark.circle")
                    } description: {
                        Text("\(current.title) is at \(PlanWords.stage(current.stage)).")
                    } actions: {
                        NavigationLink("Open \(PlanWords.kind(current.kind).lowercased())") {
                            PlanNodeScreen(projectId: projectId, nodeId: nodeId)
                        }
                    }
                }
            } else if let failure = node?.failure {
                ContentUnavailableView("Couldn’t open \(nodeId)", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(node?.node.flatMap { $0.hasGate ? PlanWords.gateTitle($0.gate) : nil } ?? "Plan")
        .navigationBarTitleDisplayMode(.inline)
        // The two answers sit at the bottom, where the tab bar would be.
        .toolbar(.hidden, for: .tabBar)
        .task {
            if node == nil { node = PlanNodeModel(projectId: projectId, nodeId: nodeId, service: store) }
            await node?.start()
        }
        .onDisappear { node?.stop() }
    }
}

private struct GateContent: View {
    @Environment(AppStore.self) private var store
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    let projectId: String
    let node: PlanNode
    let changed: () -> Void
    @State private var model: GateModel?
    @State private var excerpt: (heading: String?, text: String)?
    @State private var reading = false
    @State private var opened: PlanDocSheet?
    @State private var noting = false

    private var gate: PlanGate { node.gate }

    var body: some View {
        let ask = PlanAsk(gate.stage)
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text([node.title, "from \(PlanWords.submitter(gate) { store.bot($0)?.name })"].joined(separator: " · "))
                        .font(.footnote).foregroundStyle(Color.secondaryText)
                    Text(gate.hasDocPath ? (gate.docPath as NSString).lastPathComponent : node.title)
                        .font(.title3.bold())
                        .accessibilityAddTraits(.isHeader)
                }
                if gate.round > 1 || (gate.hasNote && gate.note.trimmed != node.summary.trimmed) {
                    VStack(alignment: .leading, spacing: 4) {
                        if gate.round > 1 { Text("Round \(gate.round)").font(.caption.weight(.semibold)).foregroundStyle(Color.secondaryText) }
                        // A proposal's note is its why, shown below.
                        if gate.hasNote, !gate.note.isEmpty, gate.note.trimmed != node.summary.trimmed {
                            Text("“\(gate.note)”").font(.callout)
                        }
                    }
                }
                if gate.hasPrNumber { LabeledContent("Pull request", value: "#\(gate.prNumber)") }
            }
            if gate.hasDocPath { excerptSection }
            if ask.kind == .proposal, !node.summary.isEmpty {
                Section {
                    LinkedText(markdown: node.summary)
                } header: {
                    SectionTitle("Why")
                }
            }
            if let model, !gate.children.isEmpty {
                Section {
                    ForEach(Array(gate.children.enumerated()), id: \.offset) { index, child in
                        let on = !model.leftOut.contains(index)
                        Button { model.toggle(index) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: on ? "checkmark.square.fill" : "square")
                                    .font(.title3)
                                    .foregroundStyle(on ? Color.askButton : Color.secondaryText)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(child.title).font(.body)
                                    if child.hasSummary, !child.summary.isEmpty {
                                        Text(child.summary).font(.footnote).foregroundStyle(Color.secondaryText).lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityHint(on ? "Untick to leave it out" : "Tick to create it")
                        .accessibilityIdentifier("gate-child-\(index)")
                    }
                } header: {
                    SectionTitle(PlanWords.creates(gate) ?? "Creates")
                } footer: {
                    Text("Untick what you don’t want created. The lead is told.").foregroundStyle(Color.secondaryText)
                }
            }
            if let model, !model.failure.isEmpty {
                Section {
                    ForEach(model.failure, id: \.self) { line in
                        Label(line, systemImage: "xmark.octagon").foregroundStyle(Color.errorText)
                    }
                } header: {
                    SectionTitle(ask.kind == .document ? "Not approved" : "Not sent")
                }
            }
            if !store.canApprove {
                Section {
                    Text("This device can’t rule on the plan. Rule on it on your computer.")
                        .font(.footnote).foregroundStyle(Color.secondaryText)
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            if store.canApprove, let model { buttons(model, ask: ask) }
        }
        .task {
            if model == nil {
                let computer = store.computerName
                model = GateModel(node: node, service: store) { reason in
                    try await OwnerAuth.confirm(reason, action: .approvePlan, computer: computer)
                }
            }
            await loadExcerpt()
        }
        .onChange(of: model?.ruled?.version) { _, version in
            guard version != nil else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            changed()
            Task { await fleet.home.refreshAll(fleet.computers, force: true) }
            dismiss()
        }
        .sheet(item: $opened) { sheet in DocumentScreen(source: sheet.source) }
        .sheet(isPresented: $noting) {
            if let model {
                PlanNoteSheet(title: ask.noteTitle, prompt: "What the lead should change", note: Binding(get: { model.note }, set: { model.note = $0 })) {
                    noting = false
                    Task { await model.sendBack() }
                }
            }
        }
    }

    private var source: DocumentSource {
        .planDoc(projectId: projectId, path: gate.docPath, sha: gate.hasSha ? gate.sha : nil,
                 name: (gate.docPath as NSString).lastPathComponent)
    }

    @ViewBuilder private var excerptSection: some View {
        Section {
            Button { opened = PlanDocSheet(source: source) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    if let excerpt {
                        if let heading = excerpt.heading { Text(heading).font(.headline) }
                        if !excerpt.text.isEmpty {
                            Text(excerpt.text).font(.callout).foregroundStyle(Color.secondaryText).lineLimit(6)
                        }
                    } else if reading {
                        ProgressView()
                    }
                    Text("Read the whole document").font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor)
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("gate-read")
        }
    }

    private func loadExcerpt() async {
        guard gate.hasDocPath, excerpt == nil else { return }
        reading = true
        defer { reading = false }
        guard let file = try? await store.planDocument(projectId: projectId, path: gate.docPath, sha: gate.hasSha ? gate.sha : nil),
              DocumentKind(mime: file.mime, name: gate.docPath) == .markdown || file.mime.hasPrefix("text/") else { return }
        excerpt = PlanExcerpt.of(file.text)
    }

    private func buttons(_ model: GateModel, ask: PlanAsk) -> some View {
        VStack(spacing: 10) {
            Button { Task { await model.approve() } } label: {
                Text(Self.yes(ask))
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(Color.onAskButton)
                    .background(Color.askButton, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .accessibilityIdentifier("gate-approve")
            Button { noting = true } label: {
                Text(Self.no(ask))
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(Color.primary)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .accessibilityIdentifier("gate-send-back")
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.bar)
    }

    static func yes(_ ask: PlanAsk) -> String {
        switch ask.kind {
        case .document: "Approve with Face ID"
        case .proposal: "Accept with Face ID"
        case .researchSkip: "Skip research with Face ID"
        }
    }

    static func no(_ ask: PlanAsk) -> String {
        switch ask.kind {
        case .document: "Send back with a note"
        case .proposal: "Decline with a note"
        case .researchSkip: "Keep research"
        }
    }
}

/// The note a send-back, a decline or keeping research carries: required.
struct PlanNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let prompt: String
    @Binding var note: String
    let send: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Note", text: $note, prompt: .placeholder(prompt), axis: .vertical)
                        .lineLimit(3...10)
                        .focused($focused)
                        .accessibilityIdentifier("plan-note")
                } footer: {
                    Text("The lead reads it and submits again.").foregroundStyle(Color.secondaryText)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send() }
                        .disabled(note.trimmed.isEmpty)
                        .accessibilityIdentifier("plan-note-send")
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Drop: what stops and what stays, an optional reason, then Face ID.
struct PlanDropSheet: View {
    @Environment(\.dismiss) private var dismiss
    let node: PlanNode
    let drop: (String) -> Void
    @State private var reason = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(PlanControls.dropWarning(node))
                }
                Section {
                    TextField("Reason", text: $reason, prompt: .placeholder("Why it stops (optional)"), axis: .vertical)
                        .lineLimit(2...6)
                } footer: {
                    Text("The lead is told, with your reason.").foregroundStyle(Color.secondaryText)
                }
                Section {
                    Button(role: .destructive) { drop(reason) } label: {
                        Text("Drop with Face ID").frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("plan-drop-confirm")
                }
            }
            .navigationTitle("Drop \(PlanWords.kind(node.kind).lowercased())")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: New goal, new initiative

/// + on the Plan: "Add to the plan of <project>".
struct PlanAddMenu: View {
    let projectName: String
    let hasGoals: Bool
    let add: (PlanKind) -> Void

    var body: some View {
        Menu {
            Section("Add to the plan of \(projectName)") {
                Button { add(.goal) } label: {
                    Label { Text("New goal"); Text("An outcome you want, and how you’ll measure it") } icon: { Image(systemName: "scope") }
                }
                if hasGoals {
                    Button { add(.initiative) } label: {
                        Label { Text("New initiative"); Text("A theme under a goal. Gets its own board") } icon: {
                            Image(systemName: "square.stack.3d.up")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("New goal or initiative")
        .accessibilityIdentifier("plan-add")
    }
}

/// New goal (the outcome, the measure, the deadline) or New initiative (its
/// goal, why, its lead). Creating needs no Face ID.
struct PlanCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @State var model: PlanCreateModel
    let goals: [PlanNode]
    let created: (PlanNode) -> Void
    @FocusState private var titleFocused: Bool

    private var isGoal: Bool { model.kind == .goal }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(isGoal ? "Goal" : "Initiative", text: $model.title,
                              prompt: .placeholder(isGoal ? "What you want to be true" : "A theme of work"), axis: .vertical)
                        .lineLimit(1...3)
                        .focused($titleFocused)
                        .accessibilityIdentifier("plan-create-title")
                } header: {
                    SectionTitle(isGoal ? "Goal" : "Initiative")
                }
                Section {
                    TextField(isGoal ? "How you’ll know it worked" : "Why", text: $model.summary,
                              prompt: .placeholder(isGoal ? "The outcome and its measure" : "What it should fix, for whom"), axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    SectionTitle(isGoal ? "How you’ll know it worked" : "Why (seeds the research brief)")
                }
                if isGoal {
                    Section {
                        TextField("By", text: $model.due, prompt: .placeholder("A date or a milestone"))
                    } footer: {
                        Text("The lead writes it into docs/goals/ in the repo. A goal needs no approval: it’s yours.")
                            .foregroundStyle(Color.secondaryText)
                    }
                } else {
                    Section {
                        Picker("Goal", selection: $model.goalId) {
                            ForEach(goals, id: \.id) { Text($0.title).tag($0.id) }
                        }
                        Picker("Lead", selection: $model.lead) {
                            Text("Project lead").tag("")
                            ForEach(leads, id: \.id) { Text($0.name).tag($0.id) }
                        }
                    }
                    Section {
                        ForEach(Array(nextSteps.enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(index + 1)").font(.subheadline.bold()).foregroundStyle(Color.askButton)
                                Text(line).font(.subheadline)
                            }
                        }
                    } header: {
                        SectionTitle("What happens next")
                    }
                }
                if !model.failure.isEmpty {
                    Section {
                        ForEach(model.failure, id: \.self) { line in
                            Label(line, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.errorText)
                        }
                    }
                }
            }
            .navigationTitle(isGoal ? "New goal" : "New initiative")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Button { create() } label: {
                    Group {
                        if model.busy { ProgressView().tint(Color.onAskButton) } else { Text(isGoal ? "Create goal" : "Create initiative") }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(model.canCreate || model.busy ? Color.onAskButton : Color.secondaryText)
                    .background(model.canCreate || model.busy ? Color.askButton : Color(.tertiarySystemFill),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!model.canCreate)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
                .accessibilityIdentifier("plan-create")
            }
            .onAppear { titleFocused = true }
        }
        .interactiveDismissDisabled(model.busy)
    }

    /// The project's bots that can lead it: its own, not linked ones.
    private var leads: [Bot] {
        store.bots.filter { $0.projectId == model.projectId && !$0.isLinked }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var nextSteps: [String] {
        let name = model.title.trimmed.isEmpty ? "the initiative" : model.title.trimmed
        return ["A board named \(name) is created for its work.",
                "It starts in Research: the lead writes the brief and opens spikes.",
                "The PRD comes to you for approval once research closes."]
    }

    private func create() {
        Task {
            guard let node = await model.create() else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            created(node)
            dismiss()
        }
    }
}

// MARK: Chips and the planning switch

/// The node a card belongs to: its kind's tile and its title.
struct PlanNodeChip: View {
    let node: PlanNode
    var showsKind = false

    var body: some View {
        HStack(spacing: 6) {
            PlanGlyph(kind: node.kind, size: 16)
            Text(showsKind ? "\(PlanWords.kind(node.kind)): \(node.title)" : node.title)
                .font(.footnote)
                .foregroundStyle(Color.secondaryText)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(PlanWords.kind(node.kind)): \(node.title)")
    }
}

/// Planning on or off, in the project's settings (the owner's, `approve`).
struct PlanningSection: View {
    @Environment(AppStore.self) private var store
    let projectId: String
    @State private var model: PlanSwitchModel?
    @State private var confirmingOff = false

    var body: some View {
        Section {
            if let model, model.tree != nil {
                Button(role: model.enabled ? .destructive : nil) {
                    if model.enabled { confirmingOff = true } else { Task { await model.toggle() } }
                } label: {
                    HStack {
                        Label(model.title, systemImage: model.enabled ? "scope" : "plus.circle")
                        Spacer()
                        if model.busy { ProgressView() }
                    }
                }
                .disabled(!store.canApprove || model.busy || (!model.enabled && !model.canTurnOn))
                .accessibilityIdentifier("plan-switch")
                if !model.enabled && !model.canTurnOn {
                    Text("Set the project’s repository first: the plan’s documents live there.")
                        .font(.footnote).foregroundStyle(Color.secondaryText)
                } else if !store.canApprove {
                    Text("This device can’t turn planning on or off.").font(.footnote).foregroundStyle(Color.secondaryText)
                }
            } else if model?.failure == nil {
                ProgressView()
            }
            if let failure = model?.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Color.errorText)
            }
        } header: {
            SectionTitle("Planning")
        } footer: {
            Text("Goals, initiatives, epics and features, each with its documents in the project’s repository and approved by you. "
                 + "Each initiative gets its own board. Turning it off hides the plan and keeps it.")
                .foregroundStyle(Color.secondaryText)
        }
        .task {
            if model == nil { model = PlanSwitchModel(projectId: projectId, service: store) }
            await model?.load()
        }
        .confirmationDialog("Turn planning off?", isPresented: $confirmingOff, titleVisibility: .visible) {
            Button("Turn planning off", role: .destructive) { Task { await model?.toggle() } }
        } message: {
            Text("The Plan is hidden and kept: turning it on again brings it back. The bots are told.")
        }
    }
}
