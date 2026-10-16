import SwiftUI

/// The iPad shell (UX-024, 0.20): a sidebar with Chat, then the projects in
/// the order Projects shows them, the ones that need the owner first; what
/// needs you is the Needs you filter on All projects. The main chat also
/// slides over any screen (✉ or ⌘J) without leaving it.
struct PadRootView: View {
    @Environment(Fleet.self) private var fleet
    @Binding var tab: RootView.Tab
    @Binding var openNeeds: NeedsDestination?
    @Binding var openBot: BotLink?
    /// RootView's landings: each one shows All projects, where its screen opens.
    var landings = 0
    @State private var selection: Item? = .projects
    @State private var chatPanel = false
    /// ✎ on iPad: who to message, then their thread in the slide-over chat.
    @State private var picking = false
    @State private var openThread: ThreadLink?
    /// The project column's stack, so card links push there (H-204).
    @State private var projectPath = NavigationPath()
    /// What to show once a project is selected: a linked card, or its settings.
    @State private var pendingPath: NavigationPath?
    /// The segment a project opens on: Board from a card's Open board.
    @State private var pendingSegment: ProjectScreen.Segment?
    @State private var projectSegment = ProjectScreen.Segment.overview

    enum Item: Hashable {
        case chat, projects, settings
        case project(HomeProjectLink)
    }

    private var cards: [HomeCard] { BoardGlance.ordered(fleet.home.cards(fleet.computers)) }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    .badge(fleet.home.questions(fleet.computers))
                    .tag(Item.chat)
                Section("Projects") {
                    Label("All projects", systemImage: "square.grid.2x2")
                        .badge(fleet.home.total(fleet.computers))
                        .tag(Item.projects)
                    ForEach(cards) { card in
                        let link = HomeProjectLink(computerId: card.computerId, projectId: card.row.projectID)
                        let selected = selection == .project(link)
                        HStack(spacing: 8) {
                            ProjectGlyph(name: card.row.name, seed: card.glyphSeed, size: 24)
                            Text(card.row.name).lineLimit(1)
                            Spacer(minLength: 4)
                            if card.row.attention.count > 0 {
                                Text("\(card.row.attention.count)")
                                    .font(.caption)
                                    .foregroundStyle(selected ? Color.white : Color.secondaryText)
                                    .accessibilityLabel("\(card.row.attention.count) need you")
                            }
                        }
                        .tag(Item.project(link))
                        .accessibilityElement(children: .combine)
                    }
                }
                Label("Settings", systemImage: "gearshape")
                    .badge(fleet.computers.filter { $0.store.status != .connected && $0.store.status != .connecting }.count)
                    .tag(Item.settings)
            }
            .navigationTitle("Flotilla")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { NewProjectButton() }
            }
        } detail: {
            detail
                .toolbar {
                    // One order everywhere (UX-029): ✉ Chat · ✎ Message a bot · ⋯ More (the screen's own).
                    if selection != .chat {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            Button { chatPanel.toggle() } label: { Image(systemName: "envelope") }
                                .accessibilityLabel("Main chat")
                                .keyboardShortcut("j", modifiers: .command)
                            Button { picking = true } label: { Image(systemName: "square.and.pencil") }
                                .accessibilityLabel("Message a bot")
                                .keyboardShortcut("n", modifiers: .command)
                        }
                    }
                }
                .inspector(isPresented: $chatPanel) {
                    MainChatView(title: "Chat", openThread: $openThread)
                        .inspectorColumnWidth(min: 320, ideal: 380, max: 480)
                }
                .sheet(isPresented: $picking) {
                    BotPicker { link in
                        picking = false
                        openThread = link
                        chatPanel = true
                    }
                }
        }
        #if DEBUG
        // Screenshots of the slide-over chat: -openChatPanel YES.
        .task { if UserDefaults.standard.bool(forKey: "openChatPanel") { chatPanel = true } }
        #endif
        // A notification or the debug tab picks the matching sidebar row.
        .onChange(of: tab, initial: true) { _, tab in
            switch tab {
            case .projects: if case .project = selection {} else { selection = .projects }
            case .chat: selection = .chat
            case .settings: selection = .settings
            }
        }
        // A route that used to open Needs you: All projects, filtered, its screen on top.
        .onChange(of: landings) { if landings > 0, tab == .projects { selection = .projects } }
        // On a cold start the link arrives before the projects: try again as they load (H-216).
        .onChange(of: fleet.openCard, initial: true) { openLinkedCard() }
        .onChange(of: fleet.cards.homes) { openLinkedCard() }
        .onChange(of: fleet.cards.settled) { openLinkedCard() }
        .onChange(of: selection) { _, item in
            projectPath = pendingPath ?? NavigationPath()
            projectSegment = pendingSegment ?? .overview
            pendingPath = nil
            pendingSegment = nil
            switch item {
            case .chat: tab = .chat; chatPanel = false
            case .settings: tab = .settings
            default: tab = .projects
            }
        }
    }

    /// A card link from outside: its project, with the card pushed (H-204).
    private func openLinkedCard() {
        guard let (id, home) = fleet.takeOpenCard() else { return }
        let card = NeedsDestination.item(computerId: home.computerId, itemId: id)
        let project = Item.project(HomeProjectLink(computerId: home.computerId, projectId: home.projectId))
        if selection == project {
            projectPath = NavigationPath([card])
        } else {
            pendingPath = NavigationPath([card])
            selection = project
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .chat:
            MainChatView(openBot: $openBot)
        case .settings:
            SettingsView(inTab: true)
        case .project(let link):
            if let computer = fleet.computer(id: link.computerId) {
                NavigationStack(path: $projectPath) {
                    ProjectScreen(projectId: link.projectId, segment: projectSegment)
                        .computerEnvironment(computer)
                        .needsDestinations()
                        .homeProjectDestinations()
                }
                .opensCardLinks(projectIds: [link.projectId]) { projectPath.append($0) }
                .id(link)
            }
        case .projects, nil:
            ProjectsHomeView(landings: landings, openNeeds: $openNeeds) { link in
                // The sidebar row is the project itself; the page it asks for opens inside.
                pendingSegment = link.page == .board ? .board : nil
                if link.page == .settings { pendingPath = NavigationPath([link]) }
                selection = .project(HomeProjectLink(computerId: link.computerId, projectId: link.projectId))
            }
        }
    }
}
