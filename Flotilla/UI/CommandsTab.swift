import SwiftUI

// The Commands tab (0.24.0, `commands_v1`), in place of Chat: every process
// the bots run, across projects and computers. The summary on top, Running ·
// Failed · All, a project and a bot to narrow it, a search; a command opens
// with its last output, its card, Open bot and, while it runs in the
// background, the owner's Stop. Each bot's own chat is on its page.

struct CommandsTab: View {
    @Environment(Fleet.self) private var fleet
    @State private var model = CommandsModel()
    @State private var path = NavigationPath()
    /// Bumped by routes that land here, to pop to the list.
    var landings = 0

    private var connected: [Computer] { fleet.computers.filter { $0.store.status == .connected } }

    private var sources: [CommandsSource] {
        connected.map { CommandsSource(computerId: $0.id, name: $0.name, daemonId: $0.store.daemonId,
                                       supported: $0.store.hasCommandsList, service: $0.store) }
    }

    /// Changes when a computer connects or drops, or a filter changes.
    private var loadKey: String {
        let computers = connected.map { "\($0.id)=\($0.store.hasCommandsList)" }.joined(separator: ",")
        return [computers, model.status.rawValue, model.project?.id ?? "", model.bot?.id ?? "", model.query].joined(separator: "|")
    }

    private var pushes: String { connected.map { "\($0.id):\($0.store.commandsRevision)" }.joined(separator: ",") }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    CommandsSummaryTiles(model: model)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                    CommandsFilterChips(model: model, projects: projectChoices, bots: botChoices)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                }
                .listRowSeparator(.hidden)
                rows
                notes
            }
            .listStyle(.plain)
            .navigationTitle("Commands")
            .searchable(text: $model.query, prompt: "Search commands")
            .refreshable { await model.load(sources) }
            .navigationDestination(for: CommandLink.self) { link in
                CommandDetailView(model: model, rowId: link.id, snapshot: link.row) { path.append($0) }
            }
            .needsDestinations()
            .task(id: loadKey) {
                // Typing waits a moment before it asks.
                if !model.query.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
                guard !Task.isCancelled else { return }
                await model.load(sources)
            }
            .onChange(of: pushes) { model.changed() }
            .onChange(of: landings) { path = NavigationPath() }
        }
    }

    @ViewBuilder private var rows: some View {
        if model.rows.isEmpty {
            if model.loaded {
                EmptyNote(text: emptyText, systemImage: "terminal")
                    .listRowSeparator(.hidden)
            } else if model.loading {
                ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
            }
        }
        ForEach(model.rows) { row in
            NavigationLink(value: CommandLink(row: row)) {
                CommandListRow(row: row, project: projectName(row), computer: computerName(row))
            }
            .accessibilityIdentifier("command-\(row.commandId)")
        }
        if model.hasMore {
            Button {
                Task { await model.loadMore() }
            } label: {
                HStack { Text("Show more"); Spacer(); if model.loading { ProgressView() } }
            }
            .disabled(model.loading)
        }
    }

    @ViewBuilder private var notes: some View {
        ForEach(model.unsupported, id: \.self) { name in
            Label("Update Flotilla on \(name) to see its bots’ commands here.", systemImage: "arrow.up.circle")
                .font(.footnote).foregroundStyle(Color.secondaryText)
                .listRowSeparator(.hidden)
        }
        ForEach(model.failures.sorted { $0.key < $1.key }, id: \.key) { name, failure in
            Label("\(name): \(failure)", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(Color.errorText)
                .listRowSeparator(.hidden)
        }
        if connected.isEmpty {
            EmptyNote(text: "Not connected to a computer.", systemImage: "wifi.slash").listRowSeparator(.hidden)
        }
    }

    private var emptyText: String {
        if !model.query.trimmed.isEmpty { return "No command matches “\(model.query.trimmed)”." }
        switch model.status {
        case .running: return "Nothing is running."
        case .failed: return "Nothing failed."
        case .all: return "No commands yet."
        }
    }

    private func projectName(_ row: FleetCommand) -> String? {
        fleet.computer(id: row.computerId)?.store.projects.first { $0.id == row.projectId }?.name
    }

    /// The bot's computer, when the phone knows several or it isn't the one that answered.
    private func computerName(_ row: FleetCommand) -> String? {
        let answered = fleet.computer(id: row.computerId)
        guard model.summary.count > 1 || (answered?.store.daemonId != nil && answered?.store.daemonId != row.daemonId) else { return nil }
        return model.summary.first { $0.daemonId == row.daemonId }?.computerName
    }

    /// Every project on the home, with each computer's own id for it.
    private var projectChoices: [CommandsProjectChoice] {
        var seen = Set<String>()
        return fleet.home.cards(fleet.computers).compactMap { card in
            var ids: [String: String] = [:]
            for computer in connected where computer.store.hasCommandsList {
                if computer.id == card.computerId {
                    ids[computer.id] = card.row.projectID
                } else if let daemon = computer.store.daemonId,
                          let member = card.row.members.first(where: { $0.daemonID == daemon }) {
                    ids[computer.id] = member.projectID
                }
            }
            guard !ids.isEmpty else { return nil }
            let choice = CommandsProjectChoice(name: card.row.name, ids: ids)
            return seen.insert(choice.id).inserted ? choice : nil
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The bots of the project picked (or all), on the computers that list commands.
    private var botChoices: [CommandsBotChoice] {
        connected.filter { $0.store.hasCommandsList }.flatMap { computer in
            computer.store.bots.filter { bot in
                guard let project = model.project else { return true }
                return project.ids[computer.id] == bot.projectId
            }
            .map { CommandsBotChoice(computerId: computer.id, botId: $0.id, name: $0.name) }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// A command to open, by its id, with the row as it was when tapped.
struct CommandLink: Hashable {
    let row: FleetCommand
    var id: String { row.id }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// running · failed today, and running per computer when there are several.
private struct CommandsSummaryTiles: View {
    let model: CommandsModel

    var body: some View {
        let totals = model.totals
        HStack(spacing: 8) {
            tile("\(totals.running)", "running", tone: .working)
            tile("\(totals.failedToday)", "failed today", tone: totals.failedToday > 0 ? .failed : nil)
            if let split = CommandWords.perComputer(model.summary) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(split).font(.subheadline.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.8)
                    Text("running per computer").font(.caption).foregroundStyle(Color.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 16)
    }

    private func tile(_ value: String, _ label: String, tone: Tone?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.bold()).foregroundStyle(tone?.text ?? .primary).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(Color.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}

/// Running · Failed · All, then the project and the bot.
private struct CommandsFilterChips: View {
    @Bindable var model: CommandsModel
    let projects: [CommandsProjectChoice]
    let bots: [CommandsBotChoice]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CommandStatusFilter.allCases) { choice in
                    Button { withAnimation(.snappy) { model.status = choice } } label: {
                        chip(choice.title, on: model.status == choice)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.status == choice ? .isSelected : [])
                    .accessibilityIdentifier("commands-status-\(choice.rawValue)")
                }
                if projects.count > 1 || model.project != nil {
                    Menu {
                        Button("All projects") { model.project = nil; model.bot = nil }
                        ForEach(projects) { project in
                            Button(project.name) {
                                model.project = project
                                if let bot = model.bot, project.ids[bot.computerId] == nil { model.bot = nil }
                            }
                        }
                    } label: {
                        chip("\(model.project?.name ?? "All projects") ▾", on: model.project != nil)
                    }
                    .accessibilityLabel("Project: \(model.project?.name ?? "all")")
                }
                if !bots.isEmpty || model.bot != nil {
                    Menu {
                        Button("All bots") { model.bot = nil }
                        ForEach(bots) { bot in Button(bot.name) { model.bot = bot } }
                    } label: {
                        chip("\(model.bot?.name ?? "All bots") ▾", on: model.bot != nil)
                    }
                    .accessibilityLabel("Bot: \(model.bot?.name ?? "all")")
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollClipDisabled()
    }

    private func chip(_ text: String, on: Bool) -> some View {
        Text(text)
            .font(.subheadline.weight(on ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .foregroundStyle(on ? Color(.systemBackground) : Color.primary)
            .background(on ? Color.primary : Color(.tertiarySystemFill), in: Capsule())
            .padding(.vertical, 5)
            .contentShape(Rectangle())
    }
}

/// "◑ Running  ML Engineer · PhD   18 min", the command, what it is for.
struct CommandListRow: View {
    let row: FleetCommand
    var project: String?
    var computer: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: row.isRunning ? 30 : 3600)) { context in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Label(CommandWords.status(row), systemImage: CommandWords.symbol(row))
                        .labelStyle(.titleAndIcon)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(CommandWords.tone(row).text)
                    Text(CommandWords.place(row, project: project, computer: computer))
                        .font(.footnote).foregroundStyle(Color.secondaryText).lineLimit(1)
                    Spacer(minLength: 4)
                    if let took = CommandWords.took(row, now: context.date) {
                        Text(took).font(.footnote).foregroundStyle(Color.secondaryText).monospacedDigit()
                    }
                }
                Text(row.firstLine)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.tail)
                let subtitle = CommandWords.subtitle(row)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.footnote).foregroundStyle(Color.secondaryText).lineLimit(1)
                }
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One command: how it stands, the whole command, its bot and card, Stop and
/// Open bot, and its last output.
struct CommandDetailView: View {
    @Environment(Fleet.self) private var fleet
    let model: CommandsModel
    let rowId: String
    let snapshot: FleetCommand
    /// Pushes a screen on the tab's stack: Open bot is a button, not a row.
    let open: (NeedsDestination) -> Void
    @State private var confirmingStop = false

    private var row: FleetCommand { model.row(rowId) ?? snapshot }
    private var store: AppStore? { fleet.computer(id: row.computerId)?.store }

    var body: some View {
        List {
            Section {
                TimelineView(.periodic(from: .now, by: row.isRunning ? 30 : 3600)) { context in
                    Label(CommandWords.headline(row, now: context.date), systemImage: CommandWords.symbol(row))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CommandWords.tone(row).text)
                }
                Text(row.command)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("command-detail-command")
                if let description = row.description, !description.trimmed.isEmpty {
                    Text(description).font(.subheadline).foregroundStyle(Color.secondaryText)
                }
                Text(CommandWords.place(row, project: store?.projects.first { $0.id == row.projectId }?.name,
                                        computer: model.summary.first { $0.daemonId == row.daemonId }?.computerName))
                    .font(.subheadline).foregroundStyle(Color.secondaryText)
                if let card = row.itemId {
                    NavigationLink(value: NeedsDestination.item(computerId: fleet.boardComputer(itemId: card)?.id ?? row.computerId, itemId: card)) {
                        Label("For \(card)", systemImage: "square.stack")
                    }
                    .accessibilityIdentifier("command-detail-card")
                }
            }
            Section {
                HStack(spacing: 10) {
                    if row.canStop, store?.canApprove == true {
                        Button { confirmingStop = true } label: {
                            Text(model.stopping.contains(row.id) ? "Stopping…" : "Stop")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .foregroundStyle(Color.errorText)
                                .background(Color.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .disabled(model.stopping.contains(row.id))
                        .accessibilityIdentifier("command-stop")
                    }
                    Button { open(.bot(computerId: row.computerId, botId: row.botId, chat: false)) } label: {
                        Text("Open bot")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(Color.primary)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .accessibilityIdentifier("command-open-bot")
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                if row.isRunning && !row.background {
                    Text("It runs in the bot’s turn and ends with it.").foregroundStyle(Color.secondaryText)
                } else if row.canStop, store?.canApprove != true {
                    Text("This device can’t stop commands.").foregroundStyle(Color.secondaryText)
                } else if let failure = model.stopFailure {
                    Text(failure).foregroundStyle(Color.errorText)
                }
            }
            Section {
                if let output = row.output {
                    Text(output)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("command-output")
                } else {
                    Text(row.isRunning ? "No output yet." : "No output.").font(.footnote).foregroundStyle(Color.secondaryText)
                }
            } header: {
                SectionTitle("Last output")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(row.botName.isEmpty ? "Command" : row.botName)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(CommandWords.stopQuestion(row), isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("Stop", role: .destructive) {
                Task {
                    if await model.stop(row) { UINotificationFeedbackGenerator().notificationOccurred(.success) }
                }
            }
        } message: {
            Text(CommandWords.stopMessage)
        }
        .onAppear { model.clearStopFailure() }
    }
}
