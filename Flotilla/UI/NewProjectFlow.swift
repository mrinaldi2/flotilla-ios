import SwiftUI

// Creating a project (0.20, BG-Rules §7, F1–F7, I2): name and board, columns
// (optional), lead, details (optional), review, then creating. The plan and
// its checks are Core/ProjectSetup.swift; this is how they are asked.

struct NewProjectFlow: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    let computer: Computer
    @State private var plan = ProjectPlan()
    @State private var step = SetupStep.board
    /// The furthest step reached: on iPad any step up to it can be picked again.
    @State private var reached = SetupStep.board
    @State private var creation: ProjectCreation?
    @State private var folderEdited = false

    private var store: AppStore { computer.store }

    var body: some View {
        NavigationStack {
            Group {
                if let creation {
                    CreatingView(creation: creation, computerName: store.computerName) {
                        creation.inBackground = true
                        dismiss()
                    } close: {
                        dismiss()
                    } retry: { failed in
                        fleet.creations.retry(creation, step: failed, on: store)
                    }
                } else if sizeClass == .regular {
                    HStack(spacing: 0) {
                        sidebar.frame(width: 250)
                        Divider()
                        page
                    }
                } else {
                    VStack(spacing: 0) {
                        StepBar(step: step).padding(.horizontal, 16).padding(.bottom, 8)
                        page
                    }
                }
            }
            .navigationTitle(creation == nil ? "New project" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if creation == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        if step == .board || sizeClass == .regular {
                            Button("Cancel") { dismiss() }
                        } else {
                            Button { go(step.previous ?? .board) } label: { Label("Back", systemImage: "chevron.left") }
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        Text(sizeClass == .regular ? "New project" : "\(step.number) of \(SetupStep.allCases.count)")
                            .font(.subheadline).foregroundStyle(Color.secondaryText)
                    }
                }
            }
        }
        .interactiveDismissDisabled(creation != nil && !(creation?.finished ?? false) && !(creation?.failed ?? false))
        .task { try? await store.loadPeers() }
        .onChange(of: creation?.finished ?? false) { _, finished in
            // Done (F7): back on the tab, the new card marked.
            if finished { dismiss() }
        }
    }

    // MARK: Pages

    @ViewBuilder private var page: some View {
        switch step {
        case .board: BoardStep(plan: $plan, taken: takenNames) { advance() }
        case .columns: ColumnsStep(plan: $plan) { advance() }
        case .lead: LeadStep(plan: $plan, store: store) { advance() }
        case .details: DetailsStep(plan: $plan, store: store, folderEdited: $folderEdited) { advance() }
        case .review: ReviewStep(plan: $plan, store: store, taken: takenNames, edit: go) { create() }
        }
    }

    /// The steps as a list down the side (I2): done ones ticked and pickable.
    private var sidebar: some View {
        List {
            ForEach(SetupStep.allCases) { item in
                Button { go(item) } label: {
                    HStack(spacing: 12) {
                        StepMark(state: item == step ? .now : item.rawValue < reached.rawValue ? .done : .next)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).fontWeight(item == step ? .bold : .regular)
                            Text(summary(item)).font(.footnote).foregroundStyle(Color.secondaryText).lineLimit(1)
                        }
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(item.rawValue > reached.rawValue)
                .listRowBackground(item == step ? Color(.tertiarySystemFill) : Color.clear)
                .accessibilityAddTraits(item == step ? .isSelected : [])
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
    }

    private func summary(_ item: SetupStep) -> String {
        switch item {
        case .board: plan.name.trimmed.isEmpty ? plan.template.title : "\(plan.name.trimmed) · \(plan.template.title)"
        case .columns: plan.columnsEdited ? "\(plan.columns.count) columns" : "Kept the defaults"
        case .lead: plan.leadName.trimmed.isEmpty ? "Name, runtime, computer" : "\(plan.leadName.trimmed) · \(plan.engine.label)"
        case .details: plan.hasRepo ? plan.repoURL.trimmed : "Optional"
        case .review: "Check and create"
        }
    }

    private var takenNames: [String] { store.projects.map(\.name) }

    private func go(_ next: SetupStep) {
        if next == .lead, plan.leadName.trimmed.isEmpty {
            plan.leadName = ProjectPlan.suggestedLead(for: plan.name)
        }
        withAnimation(.snappy) { step = next }
        if next.rawValue > reached.rawValue { reached = next }
    }

    private func advance() {
        if let next = step.next { go(next) }
    }

    private func create() {
        let creation = ProjectCreation(plan: plan, computerId: computer.id)
        self.creation = creation
        fleet.creations.start(creation, on: store)
        Task { await fleet.home.refresh(computer, force: true) }
    }
}

/// The five steps before Create.
enum SetupStep: Int, CaseIterable, Identifiable {
    case board, columns, lead, details, review

    var id: Int { rawValue }
    var number: Int { rawValue + 1 }
    var next: SetupStep? { SetupStep(rawValue: rawValue + 1) }
    var previous: SetupStep? { SetupStep(rawValue: rawValue - 1) }

    var title: String {
        switch self {
        case .board: "Name and board"
        case .columns: "Columns"
        case .lead: "Lead"
        case .details: "Details"
        case .review: "Review"
        }
    }

    var short: String {
        switch self {
        case .board: "Board"
        case .columns: "Columns"
        case .lead: "Lead"
        case .details: "Details"
        case .review: "Review"
        }
    }
}

/// "1 of 5" as five bars with their names (F1).
private struct StepBar: View {
    let step: SetupStep

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(SetupStep.allCases) { item in
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(item.rawValue <= step.rawValue ? Tone.needsYou.color : Color(.tertiarySystemFill)).frame(height: 4)
                    Text(item.short).font(.caption).fontWeight(item == step ? .bold : .regular)
                        .foregroundStyle(item.rawValue <= step.rawValue ? Color.primary : Color.secondaryText)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.number) of \(SetupStep.allCases.count), \(step.title)")
    }
}

/// A step's mark: done ticked, the current one filled, the rest a ring.
struct StepMark: View {
    enum State { case done, now, next, failed }
    let state: State

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(Tone.working.color)
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            case .now:
                Circle().strokeBorder(Tone.needsYou.color, lineWidth: 2)
                ProgressView().controlSize(.mini)
            case .next:
                Circle().strokeBorder(Color.secondaryText.opacity(0.5), lineWidth: 2)
            case .failed:
                Circle().fill(Tone.needsYou.color)
                Image(systemName: "exclamationmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }
}

/// Next (and Skip on the optional steps) at the bottom of a step.
private struct StepButtons: View {
    var skip: (() -> Void)?
    let next: String
    var disabled = false
    var why: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if let why, disabled {
                Text(why).font(.footnote).foregroundStyle(Color.secondaryText).multilineTextAlignment(.center)
            }
            HStack(spacing: 10) {
                if let skip {
                    Button("Skip", action: skip)
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
                Button(next, action: action)
                    .buttonStyle(.borderedProminent)
                    .disabled(disabled)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
        .padding(16)
        .background(.bar)
    }
}

// MARK: 1 · Name and board

private struct BoardStep: View {
    @Binding var plan: ProjectPlan
    let taken: [String]
    let next: () -> Void
    @FocusState private var focused: Bool

    private var problem: String? { PlanCheck.name(plan.name, taken: []) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Project name") {
                    TextField("Project name", text: $plan.name, prompt: .placeholder("Thesis writing"))
                        .focused($focused)
                        .submitLabel(.next)
                        .font(.title3)
                }
                Section {
                    ForEach(BoardTemplate.allCases) { template in
                        Button { plan.choose(template) } label: { TemplateRow(template: template, chosen: plan.template == template) }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(plan.template == template ? .isSelected : [])
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("How should work flow?").font(.title3.bold()).foregroundStyle(.primary)
                        Text("The board sets what bots may do on their own.").font(.subheadline).foregroundStyle(Color.secondaryText)
                    }
                    .textCase(nil)
                    .padding(.bottom, 4)
                }
            }
            StepButtons(next: "Next: columns", disabled: problem != nil, why: problem, action: next)
        }
        .onAppear { if plan.name.isEmpty { focused = true } }
    }
}

/// A board template: its name, its columns as the tab draws them, and how work flows (F1).
private struct TemplateRow: View {
    let template: BoardTemplate
    let chosen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(chosen ? Tone.needsYou.color : Color.secondaryText)
                    .accessibilityHidden(true)
                Text(template.title).font(.headline)
                Spacer(minLength: 6)
                if template.recommended {
                    Text("RECOMMENDED").font(.caption2.weight(.bold)).foregroundStyle(Color.secondaryText)
                }
            }
            MiniBoardBar(segments: TemplatePreview.segments(template.columns), height: 8)
            Text(template.columns.map(\.name).joined(separator: " · ")).font(.footnote).foregroundStyle(Color.secondaryText)
            Text(template.how).font(.subheadline)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A board being planned, as the tab's bar: a segment per column, all the same length.
enum TemplatePreview {
    static func segments(_ columns: [PlannedColumn]) -> [BoardSegment] {
        let rows = columns.enumerated().map { index, planned -> HomeColumn in
            var column = HomeColumn()
            column.key = planned.key ?? ""
            column.name = planned.name
            column.count = 1
            column.kind = planned.kind == .open ? "open" : planned.kind == .done ? "done" : "active"
            column.category = planned.key.flatMap(category) ?? (planned.kind == .open ? "inbox" : planned.kind == .done ? "done" : "doing")
            _ = index
            return column
        }
        return MiniBoard.segments(rows)
    }

    private static func category(_ key: String) -> String? {
        switch key {
        case "todo", "inbox": "inbox"
        case "ready": "ready"
        case "doing", "deploying": "doing"
        case "review": "review"
        case "verify": "verify"
        case "approval": "approval"
        case "done": "done"
        default: nil
        }
    }
}

// MARK: 2 · Columns

private struct ColumnsStep: View {
    @Binding var plan: ProjectPlan
    let next: () -> Void
    @State private var adding = false
    @State private var newName = ""
    @State private var newKind = Flotilla_Board_V1_ColumnKind.active

    private var problem: String? { PlanCheck.columns(plan.columns, template: plan.template) }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach($plan.columns) { $column in
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Column name", text: $column.name)
                                .font(.headline)
                                .onChange(of: column.name) { plan.columnsEdited = true }
                            Text(column.rule.isEmpty ? KindWords.rule(column.kind) : column.rule)
                                .font(.footnote).foregroundStyle(Color.secondaryText)
                        }
                        .padding(.vertical, 4)
                    }
                    .onMove(perform: plan.template.renameOnly ? nil : { from, to in
                        plan.columns.move(fromOffsets: from, toOffset: to)
                        plan.columnsEdited = true
                    })
                    .onDelete(perform: plan.template.renameOnly ? nil : { offsets in
                        plan.columns.remove(atOffsets: offsets)
                        plan.columnsEdited = true
                    })
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Columns").font(.title2.bold()).foregroundStyle(.primary)
                        Text(plan.template.renameOnly
                             ? "\(plan.template.title) keeps these columns, in this order: its checks rely on them. You can rename them."
                             : "\(plan.template.title) starts with these. Rename, drag to reorder, or add one. You can change them later.")
                            .font(.subheadline).foregroundStyle(Color.secondaryText)
                    }
                    .textCase(nil)
                    .padding(.bottom, 4)
                }
                if !plan.template.renameOnly {
                    Section {
                        Button { adding = true } label: { Label("Add a column", systemImage: "plus") }
                    }
                }
            }
            .environment(\.editMode, .constant(plan.template.renameOnly ? .inactive : .active))
            StepButtons(skip: {
                plan.columns = plan.template.columns
                plan.columnsEdited = false
                next()
            }, next: "Next: lead", disabled: problem != nil, why: problem, action: next)
        }
        .alert("Add a column", isPresented: $adding) {
            TextField("Name", text: $newName)
            Button("New work") { add(.open) }
            Button("In progress") { add(.active) }
            Button("Done") { add(.done) }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: {
            Text("Name it, then pick what it holds.")
        }
    }

    private func add(_ kind: Flotilla_Board_V1_ColumnKind) {
        let name = newName.trimmed
        newName = ""
        guard !name.isEmpty else { return }
        // Before Done, so Done stays last.
        let at = plan.columns.lastIndex { $0.kind == .done } ?? plan.columns.count
        plan.columns.insert(PlannedColumn(key: nil, name: name, kind: kind), at: kind == .done ? plan.columns.count : at)
        plan.columnsEdited = true
    }
}

enum KindWords {
    static func rule(_ kind: Flotilla_Board_V1_ColumnKind) -> String {
        switch kind {
        case .open: "New work waits here."
        case .done: "Finished work."
        default: "Work in progress."
        }
    }
}

// MARK: 3 · Lead

/// A computer the lead could run on (F3): this one or one it is paired with.
struct LeadPlace: Identifiable, Equatable {
    let choice: LeadComputer
    let name: String
    let detail: String
    /// Why it can't be picked; nil when it can.
    let unavailable: String?
    var id: LeadComputer { choice }

    @MainActor
    static func all(_ store: AppStore) -> [LeadPlace] {
        let running = store.bots.filter { !$0.isLinked && [.working, .starting, .ready, .waitingForUser, .waitingForApproval].contains($0.state) }.count
        var places = [LeadPlace(choice: .here, name: store.computerName.isEmpty ? "This computer" : store.computerName,
                                detail: "Online · \(running) bot\(running == 1 ? "" : "s") running", unavailable: nil)]
        guard store.hasLinkedProjects else { return places }
        for peer in store.peers where peer.isActive {
            let since = peer.lastSeenAt.map { "Offline since \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Offline"
            places.append(LeadPlace(choice: .peer(id: peer.id, name: peer.name), name: peer.name,
                                    detail: peer.online ? "Online · paired with \(store.computerName)" : since,
                                    unavailable: peer.online ? nil : "offline"))
        }
        return places
    }
}

private struct LeadStep: View {
    @Binding var plan: ProjectPlan
    let store: AppStore
    let next: () -> Void

    private var problem: String? { PlanCheck.lead(plan.leadName) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Lead's name", text: $plan.leadName)
                        .font(.title3)
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Who leads it?").font(.title2.bold()).foregroundStyle(.primary)
                        Text("The lead plans the work, writes cards and hands them to other bots.")
                            .font(.subheadline).foregroundStyle(Color.secondaryText)
                    }
                    .textCase(nil)
                    .padding(.bottom, 4)
                }
                Section("Runs with") {
                    Picker("Runs with", selection: $plan.engine) {
                        ForEach(BotEngine.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Section {
                    ForEach(LeadPlace.all(store)) { place in
                        Button { plan.computer = place.choice } label: {
                            HStack(spacing: 12) {
                                Circle().fill(place.unavailable == nil ? Tone.working.color : Color.secondaryText)
                                    .frame(width: 10, height: 10)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(place.name).font(.headline)
                                    Text(place.detail).font(.footnote).foregroundStyle(Color.secondaryText)
                                }
                                Spacer(minLength: 8)
                                if plan.computer == place.choice {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Tone.needsYou.color).accessibilityHidden(true)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(place.unavailable != nil)
                        .opacity(place.unavailable == nil ? 1 : 0.6)
                        .accessibilityAddTraits(plan.computer == place.choice ? .isSelected : [])
                    }
                } header: {
                    Text("On computer")
                } footer: {
                    Text("Greyed computers can't run it right now. The project can move its lead later.")
                }
            }
            StepButtons(next: "Next: details", disabled: problem != nil, why: problem, action: next)
        }
    }
}

// MARK: 4 · Details

private struct DetailsStep: View {
    @Binding var plan: ProjectPlan
    let store: AppStore
    @Binding var folderEdited: Bool
    let next: () -> Void

    private var problem: String? { PlanCheck.repository(plan) ?? PlanCheck.description(plan.description) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Details").font(.title2.bold()).foregroundStyle(.primary)
                            Pill(text: "OPTIONAL", tone: .quiet)
                        }
                        Text("Give the lead somewhere to work. Skip it and the lead asks when it needs one.")
                            .font(.subheadline).foregroundStyle(Color.secondaryText)
                    }
                    .textCase(nil)
                }
                if store.hasRepoClone {
                    Section {
                        TextField("Repository", text: $plan.repoURL, prompt: .placeholder("github.com/you/project"))
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: plan.repoURL) {
                                if !folderEdited { plan.folder = ProjectPlan.suggestedFolder(for: plan.repoURL) }
                            }
                        if plan.hasRepo {
                            TextField("Branch", text: $plan.branch)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("Folder", text: Binding(get: { plan.folder }, set: { plan.folder = $0; folderEdited = true }))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    } header: {
                        Text("Repository")
                    } footer: {
                        if plan.hasRepo {
                            Text(PlanCheck.repository(plan)
                                 ?? "Cloned into this folder on \(store.computerName) when you create the project; its bots and workers use it.")
                        } else {
                            Text("The https address you clone it with.")
                        }
                    }
                }
                if store.hasProjectDescription {
                    Section {
                        TextField("What is it about?", text: $plan.description, axis: .vertical)
                            .lineLimit(3...8)
                    } header: {
                        Text("What is it about?")
                    } footer: {
                        Text("The lead reads this first.")
                    }
                }
            }
            StepButtons(skip: {
                plan.repoURL = ""
                plan.folder = ""
                plan.description = ""
                folderEdited = false
                next()
            }, next: "Next: review", disabled: problem != nil, why: problem, action: next)
        }
    }
}

// MARK: 5 · Review

private struct ReviewStep: View {
    @Binding var plan: ProjectPlan
    let store: AppStore
    let taken: [String]
    let edit: (SetupStep) -> Void
    let create: () -> Void

    private var nameProblem: String? { PlanCheck.name(plan.name, taken: taken) }
    private var place: String {
        switch plan.computer {
        case .here: store.computerName
        case .peer(_, let name): name
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    row("Name", plan.name.trimmed, nil, .board)
                    if let nameProblem {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(nameProblem, systemImage: "exclamationmark.circle.fill")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Tone.needsYou.text)
                            if !plan.name.trimmed.isEmpty {
                                let free = PlanCheck.freeName(plan.name, taken: taken)
                                Button("Use \u{201C}\(free)\u{201D}") { plan.name = free }
                                    .font(.footnote.weight(.semibold))
                            }
                        }
                    }
                    row("Board", plan.template.title, plan.columns.map(\.name).joined(separator: " · "), .columns)
                    row("Lead", plan.leadName.trimmed, plan.engine.label, .lead)
                    row("Computer", place, plan.computer == .here ? "Online" : "Paired with \(store.computerName)", .lead)
                    if plan.hasRepo { row("Repository", plan.repoURL.trimmed, plan.folder.trimmed, .details) }
                } header: {
                    Text("Ready to create?").font(.title2.bold()).foregroundStyle(.primary).textCase(nil)
                }
                Section("When you tap Create") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("• Flotilla makes the board\(plan.hasRepo ? " and clones the repository on \(store.computerName)" : "").")
                        (Text("• \(plan.leadName.trimmed) starts as a \(plan.engine.label) session on \(place). ")
                            + Text("It uses your \(plan.engine == .codex ? "ChatGPT" : "Claude") plan.").bold())
                        Text("• The lead stays idle until there is a card.")
                    }
                    .font(.subheadline)
                }
            }
            StepButtons(next: "Create project", disabled: nameProblem != nil,
                        why: nameProblem == nil ? nil : "Fix the name to create the project.", action: create)
        }
    }

    private func row(_ title: String, _ value: String, _ detail: String?, _ step: SetupStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).foregroundStyle(Color.secondaryText).frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).fontWeight(.semibold)
                if let detail, !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(Color.secondaryText) }
            }
            Spacer(minLength: 6)
            Button("Edit") { edit(step) }.font(.subheadline.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: 6 · Creating

private struct CreatingView: View {
    let creation: ProjectCreation
    let computerName: String
    let background: () -> Void
    let close: () -> Void
    let retry: (ProjectCreation.Step) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 14) {
                    ZStack {
                        Circle().stroke(Color(.tertiarySystemFill), lineWidth: 7)
                        Circle().trim(from: 0, to: CGFloat(creation.done) / CGFloat(max(creation.steps.count, 1)))
                            .stroke(creation.failed ? Tone.needsYou.color : Tone.working.color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(creation.done) / \(creation.steps.count)").font(.title3.bold())
                    }
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)
                    Text(creation.failed ? "\(creation.plan.name.trimmed) needs a look" : "Creating \(creation.plan.name.trimmed)")
                        .font(.title2.bold()).multilineTextAlignment(.center)
                    Text(creation.failed ? "What's done stays done. Retry what didn't work." : "Usually under a minute.")
                        .foregroundStyle(Color.secondaryText)
                }
                VStack(spacing: 0) {
                    ForEach(Array(creation.steps.enumerated()), id: \.element) { index, step in
                        if index > 0 { Divider().padding(.leading, 52) }
                        HStack(spacing: 12) {
                            StepMark(state: mark(step))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(creation.label(step)).fontWeight(.semibold)
                                    .foregroundStyle(creation.states[step] == .waiting ? Color.secondaryText : Color.primary)
                                Text(creation.detail(step, computerName: computerName)).font(.footnote).foregroundStyle(Color.secondaryText)
                            }
                            Spacer(minLength: 6)
                            if case .failed = creation.states[step] {
                                Button("Retry") { retry(step) }.buttonStyle(.bordered)
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 60)
                        .accessibilityElement(children: .combine)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text(creation.failed
                     ? "The project is kept: its card on Projects offers Retry too."
                     : "You can leave this screen; you'll get a notification when it's ready. If the lead can't start, the project is kept and its card offers Retry.")
                    .font(.subheadline).foregroundStyle(Color.secondaryText).multilineTextAlignment(.center)
                if creation.failed {
                    Button("Close", action: close).buttonStyle(.bordered).controlSize(.large)
                } else {
                    Button("Continue in the background", action: background).buttonStyle(.bordered).controlSize(.large)
                }
            }
            .padding(22)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func mark(_ step: ProjectCreation.Step) -> StepMark.State {
        switch creation.states[step] {
        case .done?: .done
        case .running?: .now
        case .failed?: .failed
        default: .next
        }
    }
}
