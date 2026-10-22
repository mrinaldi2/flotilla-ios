import SwiftUI

// Usage (0.24.0, `usage_v1`, PhoneUsage): from Settings, each project's
// tokens this week against its budget, the bot that used the most, and an
// estimated cost; by bot on its own page. A project's budget is set here, and
// raised or extended from its Needs-you row.

/// A budget bar: blue while fine, amber from 80%, red once reached.
struct BudgetBar: View {
    let budget: ProjectBudget?
    var height: CGFloat = 8

    var body: some View {
        let state = UsageWords.state(budget)
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule()
                    .fill(color(state))
                    .frame(width: geometry.size.width * min(1, max(state == .none ? 0 : 0.02, budget?.fraction ?? 0)))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func color(_ state: UsageWords.BudgetState) -> Color {
        switch state {
        case .none: Color.secondary
        case .fine: Color.accentColor
        case .nearly, .extended: Color.orange
        case .reached: Color.red
        }
    }
}

/// The Usage page, from Settings: every computer that counts usage.
struct UsageScreen: View {
    @Environment(Fleet.self) private var fleet
    @State private var model = UsageModel()

    private var computers: [Computer] { fleet.computers.filter { $0.store.status == .connected && $0.store.hasUsage } }
    private var revisions: String {
        computers.map { "\($0.id):\($0.store.usageRevision.values.reduce(0, +))" }.joined(separator: ",")
    }

    var body: some View {
        List {
            Section {
                Picker("Range", selection: $model.range) {
                    ForEach(UsageRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text(model.header).font(.subheadline).foregroundStyle(Color.secondaryText)
                    .accessibilityIdentifier("usage-header")
            }
            ForEach(model.reports, id: \.computerId) { entry in
                Section {
                    if entry.report.projects.isEmpty {
                        EmptyNote(text: "No tokens used in this range.", systemImage: "gauge.with.dots.needle.0percent")
                    }
                    ForEach(entry.report.projects) { project in
                        NavigationLink(value: NeedsDestination.usage(computerId: entry.computerId, projectId: project.projectId)) {
                            UsageProjectRow(project: project, top: entry.report.top(in: project.projectId))
                        }
                        .accessibilityIdentifier("usage-project-\(project.projectId)")
                    }
                    if !entry.report.bots.isEmpty {
                        NavigationLink {
                            UsageBotsScreen(report: entry.report, computerName: entry.name)
                        } label: {
                            Label("Usage by bot", systemImage: "person.2")
                        }
                        .accessibilityIdentifier("usage-by-bot")
                    }
                } header: {
                    if model.reports.count > 1 { SectionTitle(entry.name) }
                }
            }
            if !model.failures.isEmpty {
                Section {
                    ForEach(model.failures.sorted { $0.key < $1.key }, id: \.key) { name, failure in
                        Label("\(name): \(failure)", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(Color.errorText)
                    }
                }
            }
            if computers.isEmpty {
                Section {
                    EmptyNote(text: "Update Flotilla on your computer to see usage here.", systemImage: "gauge.with.dots.needle.0percent")
                }
            }
            Section {
                Text(UsageWords.estimateNote).font(.footnote).foregroundStyle(Color.secondaryText)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Usage")
        .overlay { if model.loading && model.reports.isEmpty && !computers.isEmpty { ProgressView() } }
        .refreshable { await model.reload() }
        .task(id: "\(model.range.rawValue)|\(revisions)") {
            await model.load(computers.map { UsageModel.Source(computerId: $0.id, name: $0.name, service: $0.store) })
        }
        .needsDestinations()
    }
}

/// A project's usage card: its name, its budget pill and bar, the line under it.
struct UsageProjectRow: View {
    let project: UsageProject
    let top: UsageBot?

    var body: some View {
        let pill = UsageWords.pill(project.budget)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(project.name.isEmpty ? project.projectId : project.name).font(.headline)
                Spacer(minLength: 4)
                Text(pill.text).font(.footnote.weight(.semibold)).foregroundStyle(pill.tone == .quiet ? Color.secondaryText : pill.tone.text)
            }
            if project.budget?.weeklyTokens ?? 0 > 0 { BudgetBar(budget: project.budget) }
            Text(UsageWords.line(project, top: top)).font(.footnote).foregroundStyle(Color.secondaryText)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Every bot's tokens, share and estimated cost, most first.
struct UsageBotsScreen: View {
    let report: UsageReport
    let computerName: String

    var body: some View {
        List {
            Section {
                ForEach(report.bots) { bot in
                    UsageBotRow(bot: bot, project: report.projects.first { $0.projectId == bot.projectId }?.name)
                }
            } footer: {
                Text("\(report.range.phrase). \(UsageWords.estimateNote)").foregroundStyle(Color.secondaryText)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Usage by bot")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct UsageBotRow: View {
    let bot: UsageBot
    var project: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(bot.name.isEmpty ? bot.botId : bot.name).font(.subheadline.weight(.semibold))
                if let project, !project.isEmpty { Text(project).font(.footnote).foregroundStyle(Color.secondaryText) }
                Spacer(minLength: 4)
                Text(UsageWords.percent(bot.share)).font(.footnote.weight(.semibold)).foregroundStyle(Color.secondaryText)
            }
            ProgressView(value: min(1, max(0, bot.share))).tint(Color.accentColor).accessibilityHidden(true)
            Text(UsageWords.botLine(bot)).font(.footnote).foregroundStyle(Color.secondaryText)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One project's usage: its budget (set, raise, remove, extend today) and its bots.
struct ProjectUsageScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(Fleet.self) private var fleet
    let projectId: String
    @State private var range = UsageRange.week
    @State private var report: UsageReport?
    @State private var failure: String?
    @State private var budget: BudgetModel?

    private var project: UsageProject? { report?.projects.first { $0.projectId == projectId } }
    private var name: String { project?.name ?? store.projects.first { $0.id == projectId }?.name ?? "Project" }

    var body: some View {
        List {
            Section {
                Picker("Range", selection: $range) {
                    ForEach(UsageRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if let project {
                Section {
                    LabeledContent("Tokens", value: UsageWords.tokens(project.totals.tokens))
                    LabeledContent("Estimated cost", value: UsageWords.cost(project.totals.estCostUsd))
                    LabeledContent("Turns", value: "\(project.totals.turns)")
                } header: {
                    SectionTitle(range.phrase)
                }
            }
            if let budget {
                BudgetSection(model: budget, current: project?.budget) {
                    Task { await load() }
                    Task { await fleet.home.refreshAll(fleet.computers, force: true) }
                }
            }
            if let report, !report.bots(in: projectId).isEmpty {
                Section {
                    ForEach(report.bots(in: projectId)) { bot in UsageBotRow(bot: bot) }
                } header: {
                    SectionTitle("By bot")
                }
            }
            if let failure {
                Section { Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.errorText) }
            }
            Section {
                Text(UsageWords.estimateNote).font(.footnote).foregroundStyle(Color.secondaryText)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if report == nil && failure == nil { ProgressView() } }
        .task(id: "\(range.rawValue)|\(store.usageRevision[projectId] ?? 0)|\(store.reconnects)") { await load() }
    }

    private func load() async {
        guard store.hasUsage else {
            failure = "Update Flotilla on \(store.computerName) to see usage here."
            return
        }
        do {
            let report = try await store.usage(range: range, projectId: projectId, botId: nil)
            self.report = report
            failure = nil
            // The budget reads the same whatever the range.
            let current = report.projects.first { $0.projectId == projectId }?.budget
            if budget == nil || budget?.busy == false && budget?.saved == true {
                budget = BudgetModel(projectId: projectId, budget: current, service: store)
            }
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// The budget: weekly tokens in millions, Save, No budget; Extend today once reached.
struct BudgetSection: View {
    @Environment(AppStore.self) private var store
    @Bindable var model: BudgetModel
    let current: ProjectBudget?
    let changed: () -> Void
    @FocusState private var editing: Bool

    var body: some View {
        Section {
            if let current, current.weeklyTokens > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(UsageWords.tokens(current.used)) of \(UsageWords.tokens(current.weeklyTokens)) used")
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 4)
                        let pill = UsageWords.pill(current)
                        Text(pill.text).font(.footnote.weight(.semibold)).foregroundStyle(pill.tone == .quiet ? Color.secondaryText : pill.tone.text)
                    }
                    BudgetBar(budget: current, height: 10)
                    Text("Over the last 7 days.").font(.footnote).foregroundStyle(Color.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }
            HStack {
                Text("Weekly budget")
                Spacer()
                TextField("40", text: $model.millions, prompt: .placeholder("None"))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 110)
                    .focused($editing)
                    .accessibilityIdentifier("budget-field")
                Text("M tokens").foregroundStyle(Color.secondaryText)
            }
            if store.canApprove {
                Button {
                    editing = false
                    Task { await model.save(); if model.saved { changed() } }
                } label: {
                    HStack { Text("Save budget"); Spacer(); if model.busy { ProgressView() } }
                }
                .disabled(!model.canSave)
                .accessibilityIdentifier("budget-save")
                if current?.weeklyTokens ?? 0 > 0 {
                    if current?.reached == true {
                        Button("Extend today") {
                            Task { await model.extend(); if model.saved { changed() } }
                        }
                        .disabled(model.busy)
                        .accessibilityIdentifier("budget-extend")
                    }
                    Button("No budget", role: .destructive) {
                        editing = false
                        Task { await model.remove(); if model.saved { changed() } }
                    }
                    .disabled(model.busy)
                }
            }
            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Color.errorText)
            }
        } header: {
            SectionTitle("Budget")
        } footer: {
            Text(store.canApprove
                 ? "At 80% Needs you tells you. At 100% the project’s on-demand bots stop waking; the lead and always-on bots keep running. Extend today lets them wake until midnight."
                 : "This device can’t change budgets. Set it on \(store.computerName), in the Flotilla app.")
                .foregroundStyle(Color.secondaryText)
        }
    }
}

/// A budget row in Needs you (0.24.0): Raise budget, and Extend today once reached.
struct BudgetAskRow: View {
    @Environment(Fleet.self) private var fleet
    let row: HomeAttentionRow
    let computer: Computer
    var primary = false
    let open: (NeedsDestination) -> Void
    @State private var busy = false
    @State private var failure: String?

    private var store: AppStore { computer.store }
    private var destination: NeedsDestination { .usage(computerId: computer.id, projectId: row.projectID) }
    private var reached: Bool { row.kind == .budgetReached }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open(destination) } label: {
                ItemRow(title: row.displayTitle, subtitle: row.needsSubtitle, detail: unavailable ?? failure, titleLines: 2) {
                    AskGlyph(row: row)
                }
            }
            .buttonStyle(GlanceButtonStyle())
            HStack(spacing: 8) {
                if reached {
                    Button { extend() } label: {
                        AskButtonLabel(text: busy ? "Sending…" : "Extend today", primary: primary, enabled: canAct, wide: true)
                    }
                    .disabled(!canAct)
                    .accessibilityIdentifier("budget-ask-extend")
                }
                Button { open(destination) } label: {
                    AskButtonLabel(text: "Raise budget…", primary: primary && !reached, enabled: store.status == .connected, wide: true)
                }
                .disabled(store.status != .connected)
                .accessibilityIdentifier("budget-ask-raise")
            }
            .buttonStyle(GlanceButtonStyle())
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var unavailable: String? {
        if store.status != .connected { return "Not connected to \(computer.name)" }
        if !store.canApprove { return "This device can’t change budgets" }
        return nil
    }

    private var canAct: Bool { store.status == .connected && store.canApprove && !busy }

    private func extend() {
        busy = true
        failure = nil
        Task {
            defer { busy = false }
            do {
                try await store.extendBudget(projectId: row.projectID)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await fleet.home.refreshAll(fleet.computers, force: true)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
