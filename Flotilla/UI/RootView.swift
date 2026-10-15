import SwiftUI

/// The app's tabs (UX-024): Projects · Needs you · Chat · Settings.
struct RootView: View {
    @Environment(Fleet.self) private var fleet
    @Environment(Computer.self) private var computer
    @Environment(AppStore.self) private var store
    @Environment(LensStore.self) private var lens
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var tab = Tab.projects
    @State private var openNeeds: NeedsDestination?
    @State private var openBot: BotLink?
    @State private var explaining = false
    private var router: NotificationRouter { .shared }

    enum Tab { case projects, needs, chat, settings }

    /// Changes whenever a computer connects or drops, to refetch the home.
    /// Changes when a computer's projects change.
    private var projectsKey: String {
        fleet.computers.map { "\($0.id)=\($0.store.status == .connected)/\($0.store.projectsLoaded):\($0.store.projects.map(\.id).joined(separator: "+"))" }
            .joined(separator: ",")
    }

        private var connections: String { fleet.computers.map { "\($0.id)=\($0.store.status == .connected)" }.joined(separator: ",") }

    var body: some View {
        Group {
            if sizeClass == .regular {
                // iPad (UX-024): the sidebar holds Needs you, Chat and the ranked projects.
                PadRootView(tab: $tab, openNeeds: $openNeeds, openBot: $openBot)
            } else {
                tabs
            }
        }
        .overlay(alignment: .top) { noticeBanner }
        .overlay(alignment: .top) { UpdatedToast() }
        .overlay(alignment: .top) { openingBanner }
        // A release approval's Undo and outcome, wherever the owner is (UX-040).
        .overlay(alignment: .bottom) { RulingBar().padding(.bottom, 64) }
        // iPad keyboard (UX-023 §2.7): ⌘⇧N opens Needs you.
        .background {
            Button("Needs you") { tab = .needs }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .opacity(0)
                .accessibilityHidden(true)
        }
        // The home feed loads whichever screen opens first: a notification may
        // open Needs you before Projects ever shows (QA-004).
        .task(id: connections) {
            fleet.home.loadCache(fleet.computers)
            #if DEBUG
            fleet.home.loadFixture(fleet.computers)
            #endif
            await fleet.home.refreshAll(fleet.computers)
        }
        // Which card ids are links: each project's prefix (H-204). Projects
        // arrive after the connection does, so this follows them.
        .task(id: projectsKey) { await fleet.cards.refresh(fleet.computers) }
        // thehermes://item/H-293 from outside (a notification): the card, on Projects.
        .onChange(of: fleet.openCard) { _, id in if id != nil { tab = .projects } }
        .task(id: fleet.openCard) { await fleet.watchOpenCard() }
        // A card link whose id no project uses (H-216).
        .alert(fleet.missingCard ?? "", isPresented: Binding(get: { fleet.missingCard != nil },
                                                             set: { if !$0 { fleet.missingCard = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            if let id = fleet.missingCard {
                Text(CardPreview.unseen(id, device: UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"))
            }
        }
        // "See all in Needs you" on a project's Overview.
        .onChange(of: fleet.home.needsFocus) { _, id in if id != nil { tab = .needs } }
        .animation(.snappy, value: fleet.notice?.1)
        .animation(.snappy, value: fleet.openingCard)
        // Asked after pairing, with a word on why, before the system prompt.
        .task { explaining = await NotificationExplainer.shouldExplain() }
        .sheet(isPresented: $explaining) { NotificationExplainer() }
        .task(id: computer.id) { await lens.poll() }
        #if DEBUG
        // Checks without tapping a notification: -route kind/id[/bot] acts as one.
        .task {
            guard let route = UserDefaults.standard.string(forKey: "route") else { return }
            let parts = route.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { return }
            router.target = NotificationTarget(userInfo: ["computer": computer.id, "kind": parts[0], "id": parts[1],
                                                          "bot": parts.count > 2 ? parts[2] : ""])
        }
        // QA captures (H-230): -releaseStub <get_release json> opens that release.
        .task {
            if let id = InstallStubs.releaseId {
                tab = .needs
                openNeeds = .release(computerId: computer.id, releaseId: id)
            }
        }
        // As a link from outside: -openCard H-293, at launch like a cold-start link (H-216).
        .task {
            if let id = UserDefaults.standard.string(forKey: "openCard"),
               !UserDefaults.standard.bool(forKey: "openCardDone") {
                UserDefaults.standard.set(true, forKey: "openCardDone")
                fleet.openCard = id
            }
        }
        // Screenshots of a tab: -openTab needs|chat|settings.
        .task {
            switch UserDefaults.standard.string(forKey: "openTab") {
            case "needs": tab = .needs
            case "chat": tab = .chat
            case "settings": tab = .settings
            default: break
            }
        }
        #endif
        // A tapped notification: its computer, then what it is about.
        .onChange(of: router.target, initial: true) { _, target in
            guard let target else { return }
            router.target = nil
            guard let source = fleet.computers.first(where: { $0.id == target.computerId }),
                  let destination = target.destination else { return }
            fleet.select(source)
            open(destination, on: source)
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            ProjectsHomeView()
                .tabItem { Label("Projects", systemImage: "square.grid.2x2") }
                .tag(Tab.projects)
            NeedsYouView(openDecision: $openNeeds)
                .tabItem { Label("Needs you", systemImage: "exclamationmark.bubble") }
                .badge(fleet.home.total(fleet.computers))
                .tag(Tab.needs)
            MainChatView(openBot: $openBot)
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                .badge(fleet.home.questions(fleet.computers))
                .tag(Tab.chat)
            SettingsView(inTab: true)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .badge(fleet.computers.filter { $0.store.status != .connected && $0.store.status != .connecting }.count)
                .tag(Tab.settings)
        }
    }

    private func open(_ destination: NotificationTarget.Destination, on source: Computer) {
        switch destination {
        case .decision(let id):
            tab = .needs
            openNeeds = .decision(computerId: source.id, decisionId: id)
        case .permissionCard(let id):
            tab = .needs
            // A terminal command's card sits atop Needs you, read-only (H-108).
            if let bot = source.store.permissions.first(where: { $0.id == id })?.botId, bot != "terminal" {
                openNeeds = .bot(computerId: source.id, botId: bot, chat: false)
            }
        case .bot(let id, let pane):
            tab = .chat
            openBot = BotLink(botId: id, pane: pane)
        }
    }

    /// "Opening ZZ-404…" while a link from outside waits for the projects (UX-044).
    @ViewBuilder private var openingBanner: some View {
        if let id = fleet.openingCard {
            Label {
                Text("Opening \(id)…")
            } icon: {
                ProgressView().controlSize(.small)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder private var noticeBanner: some View {
        if case let (source, notice)? = fleet.notice {
            Button {
                if let id = notice.decisionId {
                    tab = .needs
                    openNeeds = .decision(computerId: source.id, decisionId: id)
                }
                source.store.notice = nil
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    if fleet.computers.count > 1 {
                        Label(source.name, systemImage: source.kind.symbol)
                            .font(.caption.weight(.medium)).foregroundStyle(Color.secondaryText)
                    }
                    Text(notice.title).font(.subheadline.weight(.semibold))
                    if !notice.body.isEmpty {
                        Text(notice.body).font(.footnote).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 12)
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: notice.id) {
                try? await Task.sleep(for: .seconds(5))
                if source.store.notice?.id == notice.id { source.store.notice = nil }
            }
        }
    }
}

/// "Approving 2 of 3 items of 0.17.0 · Undo" for the rest of the 5 s, then
/// what happened: approved, undone, refused, or changed under you.
struct RulingBar: View {
    @Environment(Fleet.self) private var fleet

    var body: some View {
        Group {
            if let pending = fleet.rulings.pending {
                bar {
                    Text(pending.label).font(.subheadline)
                    Spacer(minLength: 8)
                    Button("Undo") { fleet.rulings.undo() }.fontWeight(.semibold)
                }
            } else if let outcome = fleet.rulings.outcome {
                bar {
                    Label(outcome.text, systemImage: outcome.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(outcome.ok ? Color.primary : Color.errorText)
                    Spacer(minLength: 8)
                    Button("OK") { fleet.rulings.dismissOutcome() }
                }
                .task(id: outcome.id) {
                    try? await Task.sleep(for: .seconds(6))
                    if fleet.rulings.outcome?.id == outcome.id { fleet.rulings.dismissOutcome() }
                }
            }
        }
        .animation(.snappy, value: fleet.rulings.pending)
        .animation(.snappy, value: fleet.rulings.outcome)
    }

    private func bar(@ViewBuilder _ content: () -> some View) -> some View {
        HStack { content() }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
    }
}
