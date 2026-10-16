import SwiftUI

struct BotDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(LensStore.self) private var lens
    @Environment(\.scenePhase) private var scenePhase
    let botId: String
    /// The pane to open on, from a tapped notification.
    var initialPane: NotificationTarget.BotPane? = nil
    @State private var choice: Pane?
    @State private var searching = false
    @State private var confirming: SessionAction?
    @State private var notice: String?
    @State private var failure: String?
    /// Says which action `failure` is about.
    @State private var failedAction = SessionAction.restart

    /// Four panes at most (UX-024): what the bot reported, its chat and
    /// terminal on demand, and everything else (work, artifacts, browser,
    /// memory, its settings).
    enum Pane: String, CaseIterable {
        case reports = "Reports"
        case chat = "Chat"
        case terminal = "Terminal"
        case activity = "Activity"
        case messages = "Messages"
        case work = "Work"
        case files = "Artifacts"
        case more = "More"

        var symbol: String {
            switch self {
            case .reports: "text.quote"
            case .terminal: "terminal"
            case .chat: "bubble.left"
            case .activity: "list.bullet.rectangle"
            case .messages: "envelope"
            case .work: "hammer"
            case .files: "doc"
            case .more: "ellipsis.circle"
            }
        }
    }

    private var bot: Bot? { store.bot(botId) }

    /// A daemon that serves chat gets Gravity's chat and the panes after it;
    /// an older one keeps the Gravity Lens activity and the message thread.
    private var panes: [Pane] {
        guard let bot else { return [.more] }
        guard store.hasChat else { return [.activity, .messages, .more] }
        return store.hasTerminal(bot) ? [.reports, .chat, .terminal, .more] : [.reports, .chat, .more]
    }

    private var pane: Pane {
        if let choice, panes.contains(choice) { return choice }
        // Work and Artifacts sit under More, but a task notification opens Work.
        if let choice, store.hasChat, [.work, .files].contains(choice) { return choice }
        return panes[0]
    }

    /// The bot's browser is open: its tab shows a red dot, as on the desktop.
    private var browserOpen: Bool { store.browserTabs?.botId == botId && store.browserTabs?.open == true }

    var body: some View {
        VStack(spacing: 0) {
            PaneSwitcher(panes: panes, selection: Binding(get: { pane }, set: { choice = $0 }), moreDot: browserOpen)

            // Its tools waiting on the owner, answered right here.
            if store.hasPermissions, !store.permissions(for: botId).isEmpty {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(store.permissions(for: botId)) { PermissionCard(request: $0) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
            } else if let detail = store.approvals[botId] {
                // Its runtime's own prompt: answered in the terminal, one tap away.
                Group {
                    if let bot, store.hasTerminal(bot) {
                        NavigationLink { TerminalScreen(botId: botId).navigationTitle("Terminal") } label: { approvalLabel(detail, link: true) }
                    } else {
                        approvalLabel(detail, link: false)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            if let notice {
                Label(notice, systemImage: "arrow.clockwise")
                    .font(.footnote)
                    .foregroundStyle(Color.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(6))
                        if self.notice == notice { self.notice = nil }
                    }
            }

            switch pane {
            case .reports: BotReportsPane(botId: botId) { choice = .chat }
            case .terminal: TerminalScreen(botId: botId)
            case .chat: BotChatPane(botId: botId, searching: $searching)
            case .work: WorkPane(botId: botId)
            case .files: BotFilesPane(botId: botId)
            case .activity: BotActivityView(botId: botId)
            case .messages: ChatView(botId: botId)
            case .more: BotMorePane(botId: botId, browserOpen: browserOpen, confirming: $confirming)
            }
        }
        .navigationTitle(bot?.name ?? "Bot")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { header }
            // Only the state here, so it is never cut short; chat search
            // lives in the chat pane itself.
            ToolbarItem(placement: .topBarTrailing) {
                if let bot { StateBadge(state: bot.state).fixedSize() }
            }
        }
        .confirmationDialog(confirming?.title(bot?.name ?? "the bot") ?? "", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible
        ) {
            if let action = confirming {
                Button(action.confirm, role: action == .clear ? .destructive : nil) { run(action) }
            }
        } message: {
            Text(confirming?.body(bot?.name ?? "The bot") ?? "")
        }
        .errorAlert(failedAction == .clear ? "Couldn’t clear the conversation." : "Couldn’t restart the bot.", $failure)
        .toolbar(.hidden, for: .tabBar)
        // The browser is watched while the bot is on screen, whatever pane is
        // open, so the Browser pane is live the moment it is chosen.
        .onAppear {
            store.markSeen(botId)
            store.botOnScreen = botId
            watchBrowser()
            if choice == nil, let initialPane {
                choice = initialPane == .chat ? .chat : .work
            }
            #if DEBUG
            // Screenshots of the demo: -openPane Commands opens that pane.
            if choice == nil, let name = UserDefaults.standard.string(forKey: "openPane") {
                choice = Pane(rawValue: name)
            }
            #endif
        }
        .onDisappear {
            store.markSeen(botId)
            if store.botOnScreen == botId { store.botOnScreen = nil }
            if store.watchedBrowser?.botId == botId { store.unwatchBrowser() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { watchBrowser() } else if store.watchedBrowser?.botId == botId { store.unwatchBrowser() }
        }
    }

    /// The bot, where it runs and which project it is in.
    @ViewBuilder private var header: some View {
        if let bot {
            HStack(spacing: 8) {
                AvatarView(avatar: bot.avatar, name: bot.name, size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(bot.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text([bot.peerName ?? store.computerName, store.projectName(bot.projectId)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(Color.secondaryText).lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func approvalLabel(_ detail: String, link: Bool) -> some View {
        HStack(spacing: 10) {
            IconTile(systemImage: "hand.raised.fill", tone: .needsYou, size: 28)
            Text(detail).font(.footnote.weight(.medium)).foregroundStyle(Color.warningText).lineLimit(2)
            Spacer(minLength: 4)
            if link {
                Text("Terminal").font(.footnote.weight(.semibold))
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func watchBrowser() {
        guard let bot, store.hasBrowser(bot), store.watchedBrowser?.botId != botId else { return }
        store.watchBrowser(botId)
    }

    private func run(_ action: SessionAction) {
        let name = bot?.name ?? "The bot"
        Task {
            do {
                switch action {
                case .restart:
                    try await store.restartBot(botId)
                case .clear:
                    try await store.clearBotSession(botId)
                    // The new conversation starts empty.
                    await lens.resetChat(botId)
                }
                notice = action.done(name)
            } catch {
                failedAction = action
                failure = error.localizedDescription
            }
        }
    }
}

/// Restart bot and Clear conversation, with the words the desktop app uses.
enum SessionAction {
    case restart, clear

    func title(_ name: String) -> String {
        switch self {
        case .restart: "Restart \(name)?"
        case .clear: "Clear \(name)'s conversation?"
        }
    }

    func body(_ name: String) -> String {
        switch self {
        case .restart:
            "Its session restarts and picks its conversation back up. If it was in the middle of something, it is told what it was doing and which tasks are open, so it carries on. Its files, memory and tasks are kept."
        case .clear:
            "It restarts with a fresh conversation, without this one's history, which leaves the chat. Its files, its memory (FACTS.md) and its tasks are kept, and it is told what it was working on so it can carry on."
        }
    }

    var confirm: String {
        switch self {
        case .restart: "Restart bot"
        case .clear: "Clear conversation"
        }
    }

    func done(_ name: String) -> String {
        switch self {
        case .restart: "\(name) is restarting and will pick up where it left off."
        case .clear: "\(name) is starting a fresh conversation and will carry on its work."
        }
    }
}

/// The bot's panes: one segmented row, every pane always in view.
private struct PaneSwitcher: View {
    let panes: [BotDetailView.Pane]
    @Binding var selection: BotDetailView.Pane
    /// The bot's browser is open: More, where the Browser is, shows a red dot.
    let moreDot: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(panes, id: \.self) { pane in
                let on = selection == pane
                Button { selection = pane } label: {
                    HStack(spacing: 5) {
                        Image(systemName: pane.symbol).font(.footnote.weight(.semibold))
                        Text(pane.rawValue).font(.subheadline.weight(.semibold))
                        if pane == .more, moreDot { Circle().fill(.red).frame(width: 6, height: 6) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .foregroundStyle(on ? Color(.systemBackground) : .primary)
                    .background(on ? Color.primary : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pane.rawValue)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Everything about the bot beyond its chat, work and files: its terminal,
/// browser and memory, who it is, its routines, and its session.
private struct BotMorePane: View {
    @Environment(AppStore.self) private var store
    let botId: String
    let browserOpen: Bool
    @Binding var confirming: SessionAction?
    @State private var instructionsOpen = false

    var body: some View {
        List {
            if let bot = store.bot(botId) {
                Section {
                    if store.hasChat {
                        NavigationLink { WorkPane(botId: botId).navigationTitle("Work").navigationBarTitleDisplayMode(.inline) } label: {
                            ItemRow(title: "Work", subtitle: "Tasks, commands and routines") { IconTile(systemImage: "hammer") }
                        }
                        NavigationLink { BotFilesPane(botId: botId).navigationTitle("Artifacts").navigationBarTitleDisplayMode(.inline) } label: {
                            ItemRow(title: "Artifacts", subtitle: "What the bot published") { IconTile(systemImage: "doc") }
                        }
                    }
                    if store.hasTerminal(bot), !store.hasChat {
                        NavigationLink { TerminalScreen(botId: botId).navigationTitle("Terminal").navigationBarTitleDisplayMode(.inline) } label: {
                            ItemRow(title: "Terminal", subtitle: "The bot's live session") { IconTile(systemImage: "terminal") }
                        }
                    }
                    if store.hasBrowser(bot) {
                        NavigationLink { BrowserPane(botId: botId).navigationTitle("Browser").navigationBarTitleDisplayMode(.inline) } label: {
                            ItemRow(title: "Browser", subtitle: browserOpen ? "Open now" : "What the bot browsed") {
                                IconTile(systemImage: "globe", tone: browserOpen ? .failed : nil)
                            }
                        }
                    }
                    if store.hasChat {
                        NavigationLink { MemoryPane(botId: botId).navigationTitle("Memory").navigationBarTitleDisplayMode(.inline) } label: {
                            ItemRow(title: "Memory", subtitle: MemoryPane.file) { IconTile(systemImage: "brain") }
                        }
                    }
                } header: {
                    SectionTitle("Also here")
                }
                Section {
                    ItemRow(title: bot.name, subtitle: store.projectName(bot.projectId),
                            detail: [bot.engine == .codex ? "Codex" : "Claude Code", bot.peerName.map { "runs on \($0)" } ?? "runs on \(store.computerName)"].joined(separator: " · ")) {
                        AvatarView(avatar: bot.avatar, name: bot.name, size: 40)
                    } trailing: {
                        if bot.temporary { WorkerTag() }
                    }
                    LabeledContent("State") { StateBadge(state: bot.state) }
                    if !bot.stateReason.isEmpty {
                        LabeledContent("Reason", value: bot.stateReason)
                    }
                    if bot.temporary {
                        Text("Temporary worker spawned by \(bot.createdByBotId.flatMap(store.bot)?.name ?? "a bot"); removed when its task closes.")
                            .font(.footnote).foregroundStyle(Color.secondaryText)
                    } else if let creator = bot.createdByBotId.flatMap(store.bot) {
                        LabeledContent("Created by", value: creator.name)
                    }
                    if !bot.description.isEmpty {
                        Text(bot.description).font(.callout)
                    }
                    if !bot.instructions.isEmpty {
                        Text(bot.instructions)
                            .font(.footnote)
                            .foregroundStyle(Color.secondaryText)
                            .lineLimit(instructionsOpen ? nil : 3)
                            .textSelection(.enabled)
                            .onTapGesture { withAnimation(.snappy) { instructionsOpen.toggle() } }
                    }
                } header: {
                    SectionTitle("Profile")
                }
                if store.capabilities.contains("bot_browser"), !bot.isLinked {
                    ChromeAccessSection(bot: bot)
                }
                RoutinesSection(botId: botId)
                if store.canRestart {
                    Section {
                        Button { confirming = .restart } label: { Label("Restart bot", systemImage: "arrow.clockwise") }
                        Button(role: .destructive) { confirming = .clear } label: { Label("Clear conversation", systemImage: "eraser") }
                    } header: {
                        SectionTitle("Session")
                    } footer: {
                        Text("Files, memory and tasks are kept either way.").foregroundStyle(Color.secondaryText)
                    }
                    .disabled(store.status != .connected)
                }
                Section {
                    Text(bot.workspacePath).font(.caption.monospaced()).foregroundStyle(Color.secondaryText).textSelection(.enabled)
                } header: {
                    SectionTitle("Workspace")
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct RoutinesSection: View {
    @Environment(AppStore.self) private var store
    let botId: String
    @State private var routines: [Routine] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        Section {
          if loaded, routines.isEmpty {
            EmptyNote(text: "No routines yet.", systemImage: "calendar")
          }
          ForEach(routines) { routine in
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: Binding(
                    get: { routine.enabled },
                    set: { enabled in run { try await setEnabled(routine, enabled) } })
                ) {
                    ItemRow(title: routine.name, subtitle: routine.triggerSummary,
                            detail: routine.enabled ? routine.nextRunAt.map { "Next run \($0.relative)" } : "Paused") {
                        IconTile(systemImage: "calendar.badge.clock", tone: routine.enabled ? .working : nil)
                    }
                }
                .disabled(!store.canControl)
                Text(routine.prompt).font(.footnote).foregroundStyle(Color.secondaryText).lineLimit(3)
                if store.canControl {
                    Button("Run now") {
                        run { _ = try await store.client.request("run_routine_now", ["routine_id": routine.id]) }
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
                }
            }
          }
        } header: {
            SectionTitle("Routines")
        }
        .task(id: store.status) { await load() }
        .errorAlert("Couldn’t update the routine.", $error)
    }

    private func load() async {
        guard let reply = try? await store.client.request("list_routines", ["bot_id": botId]) else { return }
        routines = reply.list("routines").map(Routine.init)
        loaded = true
    }

    private func setEnabled(_ routine: Routine, _ enabled: Bool) async throws {
        _ = try await store.client.request("set_routine_enabled", ["routine_id": routine.id, "enabled": enabled])
        await load()
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}

/// Whether the bot may also drive the owner's own Chrome. Off by default:
/// every bot has a browser of its own, and this is for the task that needs
/// the owner's logged-in sessions. Changing it restarts the bot's session.
private struct ChromeAccessSection: View {
    @Environment(AppStore.self) private var store
    let bot: Bot
    @State private var saving = false
    @State private var note: String?
    @State private var failure: String?

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { bot.userChrome }, set: { save($0) })) {
                Text("Can use your Chrome")
            }
            .disabled(!store.canControl || store.status != .connected || saving)
            // On the row, not the Section: a List applies a section's modifiers to each row.
            .errorAlert("Couldn’t change Chrome access.", $failure)
            if let note { Text(note).font(.footnote).foregroundStyle(Color.secondaryText) }
        } header: {
            Text("Browser").foregroundStyle(Color.secondaryText)
        } footer: {
            Text("\(bot.name) always has a browser of its own. Allow this only for tasks that need your logged-in sessions; its tabs then open in your Chrome. Restarts the bot.").foregroundStyle(Color.secondaryText)
        }
    }

    private func save(_ enabled: Bool) {
        saving = true
        Task {
            do {
                try await store.setUserChrome(botId: bot.id, enabled: enabled)
                note = "\(bot.name) is restarting \(enabled ? "with" : "without") access to your Chrome."
            } catch {
                failure = error.localizedDescription
            }
            saving = false
        }
    }
}
