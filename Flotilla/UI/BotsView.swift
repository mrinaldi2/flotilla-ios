import SwiftUI

/// A bot to open from outside the Bots tab, on a given pane.
struct BotLink: Hashable {
    let botId: String
    var pane: NotificationTarget.BotPane?
}

struct BotsView: View {
    @Environment(AppStore.self) private var store
    /// Set from outside, e.g. a tapped notification: opens that bot.
    var openBot: Binding<BotLink?> = .constant(nil)
    @State private var path = NavigationPath()
    @State private var creating: Creating?

    /// What the create sheet is making.
    enum Creating: Identifiable {
        case project
        case bot(projectId: String?)

        var id: String {
            switch self {
            case .project: "project"
            case .bot(let projectId): "bot-\(projectId ?? "")"
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(store.sortedProjects) { project in
                    Section {
                        let bots = store.bots(in: project)
                        if bots.isEmpty {
                            EmptyNote(text: "No bots yet", systemImage: "person")
                        }
                        ForEach(bots) { bot in
                            NavigationLink(value: bot.id) { BotRow(bot: bot) }
                        }
                    } header: {
                        Button { path.append(ProjectPageLink(id: project.id)) } label: {
                            HStack(spacing: 6) {
                                Text(project.name).foregroundStyle(Color.secondaryText)
                                Text("\(store.bots(in: project).count)").foregroundStyle(Color.secondaryText)
                                if !project.links.isEmpty {
                                    Image(systemName: "link").font(.caption2.weight(.semibold))
                                        .foregroundStyle(project.links.contains(where: \.online) ? .green : Color.secondaryText)
                                }
                                Spacer()
                                Text("Open").font(.footnote.weight(.semibold)).foregroundStyle(.tint).textCase(nil)
                                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tint)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(project.name), \(store.bots(in: project).count) bots. Open the project")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if store.projects.isEmpty {
                    ContentUnavailableView(
                        store.status == .connected ? "No projects yet" : store.status.label,
                        systemImage: "person.2.slash",
                        description: Text(emptyDetail))
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { ConnectionBanner() }
            .refreshable { await store.refresh() }
            .navigationTitle("Bots")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ComputerSwitcher() }
                if store.canControl, store.status == .connected {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { creating = .bot(projectId: nil) } label: { Label("New bot", systemImage: "person.badge.plus") }
                                .disabled(store.projects.isEmpty)
                            Button { creating = .project } label: { Label("New project", systemImage: "folder.badge.plus") }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Create")
                    }
                }
            }
            .sheet(item: $creating) { item in
                switch item {
                case .project:
                    NewProjectSheet { project, addBot in
                        creating = nil
                        if addBot {
                            // Let the first sheet go before the next one comes up.
                            Task {
                                try? await Task.sleep(for: .milliseconds(450))
                                creating = .bot(projectId: project.id)
                            }
                        }
                    }
                case .bot(let projectId):
                    NewBotSheet(projectId: projectId) { bot in
                        creating = nil
                        path.append(bot.id)
                    }
                }
            }
            .navigationDestination(for: String.self) { BotDetailView(botId: $0) }
            .navigationDestination(for: BotLink.self) { BotDetailView(botId: $0.botId, initialPane: $0.pane) }
            .needsDestinations()
            .onChange(of: openBot.wrappedValue, initial: true) { _, link in
                guard let link else { return }
                var fresh = NavigationPath()
                fresh.append(link)
                path = fresh
                openBot.wrappedValue = nil
            }
            .navigationDestination(for: ProjectPageLink.self) { ProjectView(projectId: $0.id) }
            .navigationDestination(for: ConversationsLink.self) { ConversationsView(projectId: $0.projectId) }
            .navigationDestination(for: WorkersLink.self) { WorkersView(projectId: $0.projectId) }
            #if DEBUG
            // Screenshots of the demo: -openConversations opens the first project's,
            // -openWorkers the Workers of the one with a repository, -openBot <name> that bot.
            .task(id: store.bots.count) {
                guard path.isEmpty else { return }
                if let name = UserDefaults.standard.string(forKey: "openBot"),
                   let bot = store.bots.first(where: { $0.name == name }) {
                    path.append(bot.id)
                } else if UserDefaults.standard.bool(forKey: "openWorkers"),
                          let project = store.sortedProjects.first(where: { $0.repo != nil }) ?? store.sortedProjects.first {
                    path.append(WorkersLink(projectId: project.id))
                } else if UserDefaults.standard.bool(forKey: "openConversations"),
                          let first = store.sortedProjects.first {
                    path.append(ConversationsLink(projectId: first.id))
                }
            }
            #endif
            .navigationDestination(for: TurnLink.self) { TurnDetailView(botId: $0.botId, turnId: $0.turnId) }
        }
        // Card ids anywhere in this stack open the card here (H-204).
        .opensCardLinks { path.append($0) }
    }

    private var emptyDetail: String {
        switch store.status {
        case .connected: "Create a project and bots in Hermes on \(store.computerName)."
        case .disconnected(let reason): reason
        case .authFailed(let reason), .versionMismatch(let reason): reason
        default: ""
        }
    }
}

/// Opens a project's page from the Bots list.
struct ProjectPageLink: Hashable {
    let id: String
}

/// The unread dot in words (UX-029): visible "1 new", spoken "New message from <bot>".
enum UnreadWords {
    static func visible(unread: Int?, seenNewer: Bool) -> String? {
        if let unread, unread > 0 { return "\(unread) new" }
        if let unread, unread == 0 { return nil }
        return seenNewer ? "New" : nil
    }

    static func spoken(_ bot: String) -> String { "New message from \(bot)" }
}

struct BotRow: View {
    @Environment(AppStore.self) private var store
    @Environment(LensStore.self) private var lens
    let bot: Bot
    /// Unread messages to you, from the owner thread; nil where not known.
    var unread: Int? = nil

    /// "1 new", or "New" when only the activity says so (UX-029).
    private var newWords: String? { UnreadWords.visible(unread: unread, seenNewer: store.isUnread(bot)) }

    /// The one line about what the bot is doing: its step, its question, its
    /// last word, or what it is for.
    private var line: String {
        if let turn = lens.latest[bot.id], turn.open, bot.state == .working, !turn.current.isEmpty { return turn.current }
        if let detail = store.approvals[bot.id] { return detail }
        if let outcome = lens.latest[bot.id]?.outcome, outcome.kind != "none" {
            return outcome.kind == "message" ? "To \(outcome.to): \(outcome.text)" : outcome.text
        }
        if let activity = store.activity[bot.id] {
            return activity.from.isEmpty ? activity.text : "\(activity.from): \(activity.text)"
        }
        return bot.description
    }

    private var detail: String {
        var parts: [String] = []
        if let newWords { parts.append(newWords) }
        if let machine = bot.peerName { parts.append("on \(machine)") }
        if bot.engine == .codex { parts.append("Codex") }
        if bot.temporary { parts.append("Worker") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ItemRow(title: bot.name, subtitle: line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: ""),
                detail: detail, subtitleLines: 2) {
            AvatarView(avatar: bot.avatar, name: bot.name, size: 40)
                .overlay(alignment: .topTrailing) {
                    if newWords != nil {
                        Circle().fill(.tint).frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
                            .offset(x: 3, y: -3)
                            .accessibilityLabel(UnreadWords.spoken(bot.name))
                    }
                }
        } trailing: {
            StateBadge(state: bot.state)
        }
    }
}
