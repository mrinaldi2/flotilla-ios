import SwiftUI

// UX-024, 0.20 Board glance: the app opens on Projects, every project as a
// card of its board, its fleet and what it needs from you, across every
// computer, with the last answer shown at once. What waits for you is the
// Needs you filter there, and each card's asks.

/// A project to open from the home, on the computer that answered for it.
struct HomeProjectLink: Hashable, Identifiable {
    let computerId: String
    let projectId: String
    /// What it opens on: the Overview, unless a card's menu or a quiet row asks for more.
    var page = Page.overview

    enum Page: Hashable {
        case overview, board, settings
    }

    var id: String { "\(computerId):\(projectId):\(page)" }

    func showing(_ page: Page) -> HomeProjectLink {
        var link = self
        link.page = page
        return link
    }
}

/// Where a Needs-you row leads.
enum NeedsDestination: Hashable {
    case decision(computerId: String, decisionId: String)
    case bot(computerId: String, botId: String, chat: Bool)
    case item(computerId: String, itemId: String)
    /// The card with "Reply to <bot>" open on that comment (H-248, H-210).
    case reply(computerId: String, itemId: String, commentId: String)
    case release(computerId: String, releaseId: String)
    case note(title: String, text: String)
}

extension ReleaseStatusWords {
    static func pill(_ release: Flotilla_Home_V1_ReleaseBrief) -> (String, Tone) {
        let version = release.version.isEmpty ? "Release" : release.version
        // Something only the owner can give it (H-248): that, before its state.
        if release.ownerBlockerCount > 0 { return (WaitingWords.projectsPill(version), .needsYou) }
        switch release.state {
        case "awaiting_owner": return ("\(version) ready for you to test", .needsYou)
        case "deployed": return ("\(version) live", .ready)
        case "held": return ("\(version) on hold", .quiet)
        case "approved": return ("\(version) approved", .ready)
        case "deploying", "partially_deployed": return ("\(version) rolling out", .working)
        case "paused": return ("\(version) rollout paused", .needsYou)
        case "rejected": return ("\(version) rejected", .failed)
        case "rolled_back": return ("\(version) rolled back", .failed)
        case "assembling", "built", "repackaging": return ("\(version) being packaged", .working)
        default: return (version, .quiet)
        }
    }
}

/// Release states in the glossary's words (§5).
enum ReleaseStatusWords {}

// MARK: Projects

/// The Projects tab (0.20, BG-Rules): every project as a card of its board,
/// its fleet and what it needs from you, Needs you first. Needs you is one of
/// its filters, which routes from outside turn on.
struct ProjectsHomeView: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var path = NavigationPath()
    @State private var debugOpened = false
    /// Cards whose whole list of asks is open ("N more").
    @State private var expanded: Set<String> = []
    @State private var showingDecisions = false
    @State private var addingLead: HomeProjectLink?
    /// Bumped by every route that lands here (RootView): back to the list,
    /// then the screen in `openNeeds`, if any.
    var landings = 0
    var openNeeds: Binding<NeedsDestination?> = .constant(nil)
    /// On iPad the sidebar shows the project: a card selects it there instead of pushing.
    var open: ((HomeProjectLink) -> Void)?

    private var feed: HomeFeed { fleet.home }
    private var filter: Binding<HomeFilter> { Binding(get: { fleet.home.filter }, set: { fleet.home.filter = $0 }) }
    private var hasTerminal: Bool { fleet.computers.contains { $0.store.permissions.contains(where: \.isTerminal) } }

    /// What the tab shows now, in order, split into full cards and quiet rows.
    private struct Shown {
        let all: [HomeCard]
        let full: [HomeCard]
        let quiet: [HomeCard]
        let counts: [HomeFilter: Int]
    }

    private func shown(_ now: Date = Date()) -> Shown {
        let all = BoardGlance.ordered(feed.cards(fleet.computers), now: now)
        let visible = all.filter { BoardGlance.matches($0, feed.filter, now: now) }
        return Shown(all: all,
                     full: visible.filter { BoardGlance.group($0, now: now) != .quiet },
                     quiet: visible.filter { BoardGlance.group($0, now: now) == .quiet },
                     counts: BoardGlance.counts(all, now: now))
    }

    var body: some View {
        let shown = shown()
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                Group {
                    if sizeClass == .regular { grid(shown) } else { list(shown) }
                }
                // "See all in Needs you" on a project's Overview: its list, open, in view.
                .onChange(of: feed.needsFocus, initial: true) { _, id in
                    guard let id else { return }
                    if !id.isEmpty { expanded.insert(id) }
                    // After the landing pops the stack; cleared only then, so RootView sees it too.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        if !id.isEmpty { withAnimation { proxy.scrollTo(id, anchor: .top) } }
                        if feed.needsFocus == id { feed.needsFocus = nil }
                    }
                }
            }
            .navigationTitle("Projects")
            .toolbar {
                // Every decision, settled ones too (UX-024), as Needs you offered.
                ToolbarItem(placement: .topBarLeading) {
                    Button("Decisions") { showingDecisions = true }
                }
                ToolbarItem(placement: .topBarTrailing) { NewProjectButton() }
            }
            .sheet(isPresented: $showingDecisions) { DecisionsView(openDecision: .constant(nil)) }
            .sheet(item: $addingLead) { link in
                if let computer = fleet.computer(id: link.computerId) {
                    NewBotSheet(projectId: link.projectId) { _ in
                        addingLead = nil
                        Task { await feed.refresh(computer, force: true) }
                    }
                    .computerEnvironment(computer)
                }
            }
            .refreshable { await feed.refreshAll(fleet.computers, force: true) }
            #if DEBUG
            .onChange(of: shown.all.map(\.row.projectID), initial: true) {
                guard !debugOpened, let name = UserDefaults.standard.string(forKey: "openProject"),
                      let card = shown.all.first(where: { $0.row.name.lowercased().hasPrefix(name.lowercased()) }) else { return }
                debugOpened = true
                openProject(HomeProjectLink(computerId: card.computerId, projectId: card.row.projectID))
            }
            #endif
            .homeProjectDestinations()
            .needsDestinations()
            // A card link from outside (iPad: PadRootView opens it in the project column).
            // On a cold start the link arrives before the projects: try again as they load (H-216).
            .onChange(of: fleet.openCard, initial: true) { openLinkedCard() }
            .onChange(of: fleet.cards.homes) { openLinkedCard() }
            .onChange(of: fleet.cards.settled) { openLinkedCard() }
            .onChange(of: landings, initial: true) { land() }
        }
        // Card ids anywhere in this stack open the card here (H-204).
        .opensCardLinks { path.append($0) }
    }

    /// A route landed (a notification, a toast, ⌘⇧N): back to the list, then its screen.
    private func land() {
        guard landings > 0 else { return }
        path = NavigationPath()
        guard let destination = openNeeds.wrappedValue else { return }
        openNeeds.wrappedValue = nil
        // On iPad a route switches the sidebar to Projects and arrives as this
        // column first shows; pushed in that same update it is lost, since the
        // split view rebuilds the detail stack right after. Push on the next turn (H-230).
        Task { @MainActor in path = NeedsRoute.path(to: destination) }
    }

    private func openLinkedCard() {
        guard open == nil, let (id, home) = fleet.takeOpenCard() else { return }
        path.append(NeedsDestination.item(computerId: home.computerId, itemId: id))
    }

    private func openProject(_ link: HomeProjectLink) {
        if let open { open(link) } else { path.append(link) }
    }

    // MARK: iPhone: one column of cards

    private func list(_ shown: Shown) -> some View {
        List {
            if !shown.all.isEmpty {
                // A header, not a row: a row's rounded corners would clip the words.
                Section {
                } header: {
                    header(shown)
                        .textCase(nil)
                        .padding(.horizontal, -16)
                        .padding(.bottom, -4)
                }
            }
            ForEach(away(shown)) { item in
                Section { NotConnectedBanner(computer: item.computer, asOf: item.asOf) }
            }
            if feed.filter == .all || feed.filter == .needsYou {
                // A release waiting to be installed here (H-230).
                ForEach(fleet.computers) { computer in InstallOfferBanner(store: computer.store) }
                // Terminal commands acting as the owner sit above everything, read-only (H-108).
                ForEach(fleet.computers) { computer in
                    let terminal = computer.store.permissions.filter(\.isTerminal)
                    if !terminal.isEmpty {
                        Section {
                            ForEach(terminal) { TerminalCommandCard(request: $0) }
                        }
                        .computerEnvironment(computer)
                    }
                }
            }
            if shown.all.isEmpty {
                Section { empty }
            } else if shown.full.isEmpty, shown.quiet.isEmpty, !(feed.filter == .needsYou && hasTerminal) {
                EmptyNote(text: emptyFilterText, systemImage: feed.filter == .needsYou ? "checkmark.circle" : "folder")
            }
            ForEach(shown.full) { card in
                Section {
                    cardBody(card)
                    asks(card, inList: true)
                }
                .id(card.id)
            }
            if !shown.quiet.isEmpty {
                Section {
                    ForEach(shown.quiet) { card in quietButton(card) }
                } header: {
                    SectionTitle("Quiet", count: shown.quiet.count)
                } footer: {
                    Text(quietFooter).foregroundStyle(Color.secondaryText)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(12)
    }

    // MARK: iPad: a grid of cards

    private func grid(_ shown: Shown) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !shown.all.isEmpty { header(shown) }
                ForEach(away(shown)) { item in
                    tile { NotConnectedBanner(computer: item.computer, asOf: item.asOf) }
                }
                if feed.filter == .all || feed.filter == .needsYou {
                    ForEach(fleet.computers) { computer in
                        if computer.store.installOffer != nil { tile { InstallOfferBanner(store: computer.store) } }
                    }
                    ForEach(fleet.computers) { computer in
                        ForEach(computer.store.permissions.filter(\.isTerminal)) { request in
                            tile { TerminalCommandCard(request: request) }.computerEnvironment(computer)
                        }
                    }
                }
                if shown.all.isEmpty {
                    tile { empty }
                } else if shown.full.isEmpty, shown.quiet.isEmpty, !(feed.filter == .needsYou && hasTerminal) {
                    EmptyNote(text: emptyFilterText, systemImage: feed.filter == .needsYou ? "checkmark.circle" : "folder")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                    ForEach(shown.full) { card in
                        VStack(alignment: .leading, spacing: 0) {
                            cardBody(card)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                            asks(card, inList: false)
                        }
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .id(card.id)
                    }
                }
                if !shown.quiet.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle("Quiet", count: shown.quiet.count)
                            .font(.footnote.weight(.semibold))
                            .textCase(.uppercase)
                            .padding(.horizontal, 4)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                            ForEach(shown.quiet) { card in
                                quietButton(card)
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 56)
                                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                        Text(quietFooter).font(.footnote).foregroundStyle(Color.secondaryText).padding(.horizontal, 4)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func tile(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: Pieces

    private func header(_ shown: Shown) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(GlanceWords.summary(projects: shown.all.count, needs: feed.total(fleet.computers),
                                     working: shown.all.reduce(0) { $0 + Int($1.row.botsWorking) },
                                     offline: Set(shown.all.flatMap(\.staleNames)).count))
                .font(.subheadline)
                .foregroundStyle(Color.secondaryText)
            if BoardGlance.showsFilters(projects: shown.all.count, filter: feed.filter) {
                FilterChips(filter: filter, counts: shown.counts)
            }
        }
    }

    private struct Away: Identifiable {
        let computer: Computer
        let asOf: Date?
        var id: String { computer.id }
    }

    /// Computers the phone can't reach whose projects it still shows.
    private func away(_ shown: Shown) -> [Away] {
        let showing = Set(shown.all.map(\.computerId))
        return fleet.computers.compactMap { computer in
            guard showing.contains(computer.id), computer.store.connectionTrouble, computer.store.status != .connected else { return nil }
            let overview = feed.overviews[computer.id]
            return Away(computer: computer, asOf: overview?.hasAsOf == true ? overview?.asOf.date : nil)
        }
    }

    @ViewBuilder private var empty: some View {
        if fleet.computers.contains(where: { $0.store.status == .connected }) {
            VStack(spacing: 12) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Tone.working.color)
                    .accessibilityHidden(true)
                Text("Start your first project").font(.title2.bold())
                Text("A project is a board and the bots that work on it.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.secondaryText)
                NewProjectButton(prominent: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else {
            EmptyNote(text: "Connecting…", systemImage: "folder")
        }
    }

    private var emptyFilterText: String {
        switch feed.filter {
        case .needsYou: "Nothing is waiting on you."
        case .working: "No bots are working right now."
        case .quiet: "No quiet projects."
        case .all: "No projects yet"
        }
    }

    private var quietFooter: String { "Nothing to do for a day or more. Tap to open the board." }

    private func quietButton(_ card: HomeCard) -> some View {
        let link = HomeProjectLink(computerId: card.computerId, projectId: card.row.projectID)
        return Button { openProject(link.showing(.board)) } label: { QuietRow(card: card, stacked: sizeClass == .regular) }
            .buttonStyle(GlanceButtonStyle())
            .hoverEffect(.highlight)
            .contextMenu { cardMenu(card) }
            .accessibilityLabel("\(card.row.name), quiet, \(GlanceWords.quietMeta(card.row))")
            .accessibilityHint("Opens the board")
    }

    /// The top of a card: opens the project; long press for its actions.
    private func cardBody(_ card: HomeCard) -> some View {
        let link = HomeProjectLink(computerId: card.computerId, projectId: card.row.projectID)
        let first = (feed.attention[card.id] ?? []).first
        let destination = first.map { fleet.needsDestination($0, answeredBy: card.computerId) }
        let action = first.flatMap { row in destination.map { AskAction.label(row, opens: $0) } }
        let available = destination.map { fleet.unavailable($0) == nil } ?? false
        let ask = first.map { row in [row.displayTitle, action, destination.flatMap(fleet.unavailable)].compactMap { $0 }.joined(separator: ", ") }
            ?? (card.row.attention.count > 0 ? AttentionWords.summary(card.row.attention) : nil)
        return Button { openProject(link) } label: {
            ProjectCardBody(card: card, bots: fleet.glanceBots(card))
        }
        .buttonStyle(GlanceButtonStyle())
        .hoverEffect(.highlight)
        .contextMenu { cardMenu(card) }
        .accessibilityLabel(ProjectCardBody.spoken(card, ask: ask))
        .accessibilityHint("Opens the project")
        .accessibilityActions {
            if let action, let destination, available {
                Button(action) { path.append(destination) }
            }
            Button("Open board") { openProject(link.showing(.board)) }
        }
        // Cached cards show before their computer connects: reload once it does.
        .task(id: "\(card.id)/\(card.row.attention.count)/\(card.row.attention.score)/\(fleet.computer(id: card.computerId)?.store.status == .connected)") {
            if let computer = fleet.computer(id: card.computerId) { await feed.loadAttention(card, on: computer) }
        }
    }

    /// What a card needs from you: the most urgent ask with "N more", or the
    /// whole list once opened (always, under the Needs you filter). Until the
    /// rows load, the summary holds their place.
    @ViewBuilder private func asks(_ card: HomeCard, inList: Bool) -> some View {
        let rows = feed.attention[card.id] ?? []
        let waiting = Int(card.row.attention.count)
        let open = feed.filter == .needsYou || expanded.contains(card.id)
        if !rows.isEmpty {
            ForEach(open ? rows : Array(rows.prefix(1)), id: \.id) { row in
                askButton(row, card: card, primary: row.id == rows.first?.id, inList: inList)
            }
            let more = max(rows.count, waiting) - 1
            if more > 0, feed.filter != .needsYou {
                separated(inList) {
                    Button {
                        withAnimation(.snappy) {
                            if open { expanded.remove(card.id) } else { expanded.insert(card.id) }
                        }
                    } label: {
                        Label(open ? "Show less" : "\(more) more", systemImage: open ? "chevron.up" : "chevron.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.secondaryText)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(GlanceButtonStyle())
                    .accessibilityLabel(open ? "Show less" : "Show \(more) more for \(card.row.name)")
                }
            }
        } else if waiting > 0 {
            separated(inList) {
                ItemRow(title: AttentionWords.summary(card.row.attention), titleTone: .needsYou) {
                    Circle().fill(Tone.needsYou.color.opacity(0.18)).frame(width: 26, height: 26)
                        .overlay { Text("!").font(.system(size: 13, weight: .heavy)).foregroundStyle(Tone.needsYou.text) }
                        .accessibilityHidden(true)
                }
            }
        } else if BoardGlance.state(card) == .setUp, let computer = fleet.computer(id: card.computerId),
                  computer.store.status == .connected, computer.store.canControl {
            separated(inList) {
                Button { addingLead = HomeProjectLink(computerId: card.computerId, projectId: card.row.projectID) } label: {
                    ItemRow(title: "Add a lead to start", subtitle: "No bots work on it yet") {
                        Circle().fill(Color(.tertiarySystemFill)).frame(width: 26, height: 26)
                            .overlay { Image(systemName: "plus").font(.system(size: 12, weight: .bold)) }
                            .accessibilityHidden(true)
                    } trailing: {
                        AskButtonLabel(text: "Add lead", primary: true)
                    }
                }
                .buttonStyle(GlanceButtonStyle())
            }
        }
    }

    /// In the list a row is its own; in a grid tile a line goes above it.
    @ViewBuilder private func separated(_ inList: Bool, @ViewBuilder _ content: () -> some View) -> some View {
        if inList {
            content()
        } else {
            Divider().padding(.leading, 16)
            content().padding(.horizontal, 16).padding(.vertical, 4)
        }
    }

    private func askButton(_ row: HomeAttentionRow, card: HomeCard, primary: Bool, inList: Bool) -> some View {
        let destination = fleet.needsDestination(row, answeredBy: card.computerId)
        let reason = fleet.unavailable(destination)
        let action = AskAction.label(row, opens: destination)
        // Filled only for something to do here, not a note on where to do it.
        let filled: Bool = {
            if case .note = destination { return false }
            return primary
        }()
        let button = Button { path.append(destination) } label: {
            AskRow(row: row, action: action, primary: filled, unavailable: reason)
        }
        .buttonStyle(GlanceButtonStyle())
        .disabled(reason != nil)
        return separated(inList) {
            if inList {
                button.cardMenu(for: row.itemIdText).dismissible(row)
            } else if Dismissal.allowed(row) {
                // No swipe outside a list: Dismiss is in the long-press menu.
                button.dismissible(row, swipe: false)
            } else {
                button.cardMenu(for: row.itemIdText)
            }
        }
    }

    /// Long press on a card (case 6): its board, its lead, the pin, its settings.
    @ViewBuilder private func cardMenu(_ card: HomeCard) -> some View {
        let link = HomeProjectLink(computerId: card.computerId, projectId: card.row.projectID)
        Button("Open board", systemImage: "rectangle.split.3x1") { openProject(link.showing(.board)) }
        if let lead = fleet.lead(of: card) {
            Button("Chat with \(lead.name)", systemImage: "bubble.left") {
                path.append(NeedsDestination.bot(computerId: card.computerId, botId: lead.id, chat: true))
            }
        }
        pinButton(card)
        Button("Project settings", systemImage: "gearshape") { openProject(link.showing(.settings)) }
    }

    @ViewBuilder private func pinButton(_ card: HomeCard) -> some View {
        if let computer = fleet.computers.first(where: { $0.id == card.computerId }), computer.store.canPin {
            Button(card.row.pinned ? "Unpin" : "Pin to top", systemImage: card.row.pinned ? "pin.slash" : "pin") {
                Task {
                    try? await computer.store.pinProject(card.row.projectID, pinned: !card.row.pinned)
                    await feed.refresh(computer, force: true)
                }
            }
        }
    }
}

/// Where an outside route lands on Projects: that screen on an empty stack.
enum NeedsRoute {
    static func path(to destination: NeedsDestination) -> NavigationPath { NavigationPath([destination]) }
}

extension Fleet {
    func computer(id: String) -> Computer? { computers.first { $0.id == id } }

    /// The computer with that daemon id, if the phone talks to it.
    func computer(daemonId: String) -> Computer? {
        daemonId.isEmpty ? nil : computers.first { $0.store.daemonId == daemonId }
    }

    /// Where a Needs-you row opens: on the computer that acts on it (its
    /// `daemon_id`), else the one that answered for the project.
    func needsDestination(_ row: HomeAttentionRow, answeredBy computerId: String) -> NeedsDestination {
        let on = computer(daemonId: row.daemonID) ?? computer(id: computerId)
        let place = on?.name ?? "that computer"
        switch row.target {
        case .decisionID(let id)?:
            if let on { return .decision(computerId: on.id, decisionId: id) }
        case .requestID(let id)?:
            // A terminal command is answered only on its own computer (H-108).
            if let on, let bot = on.store.permissions.first(where: { $0.id == id })?.botId, bot != "terminal" {
                return .bot(computerId: on.id, botId: bot, chat: false)
            }
            return .note(title: row.title, text: "Answer it on \(place), in the Flotilla app.")
        case .bot(let ref)?:
            if let botComputer = computer(daemonId: ref.daemonID) ?? on {
                return .bot(computerId: botComputer.id, botId: ref.botID, chat: true)
            }
        case .releaseID(let id)?:
            if let on { return .release(computerId: on.id, releaseId: id) }
        case .actionID?:
            return .note(title: row.title, text: "Run cards come to the phone in a later update. For now, run or reject it on \(place), in the Flotilla app.")
        case .itemID(let id)?:
            // The card on the computer that keeps its board, where a comment is
            // accepted (H-210); the bot's computer would refuse it.
            if let home = boardComputer(itemId: id) ?? on { return .item(computerId: home.id, itemId: id) }
        case .prNumber?, .cleanupJobID?, .machine?, nil:
            // PR reviews, cleanups and disk space are answered on the computer.
            break
        }
        switch row.kind {
        case .relayedRulings:
            return .note(title: row.title, text: "Confirm them under Decisions on \(place).")
        case .servingOff:
            return .note(title: row.title, text: "\(place) isn't serving the phone securely. Check it in Settings → Computers.")
        default:
            return .note(title: row.title, text: "Open it on \(place).")
        }
    }
}

/// The screens a Needs-you row or a project's Overview opens, in any stack.
struct NeedsDestinations: ViewModifier {
    @Environment(Fleet.self) private var fleet

    func body(content: Content) -> some View {
        content.navigationDestination(for: NeedsDestination.self) { destination in
            switch destination {
            case .decision(let computerId, let decisionId):
                if let computer = fleet.computer(id: computerId) {
                    DecisionDetailView(decisionId: decisionId).computerEnvironment(computer)
                }
            case .bot(let computerId, let botId, let chat):
                if let computer = fleet.computer(id: computerId) {
                    BotDetailView(botId: botId, initialPane: chat ? .chat : nil).computerEnvironment(computer)
                }
            case .item(let computerId, let itemId):
                if let computer = fleet.computer(id: computerId) {
                    ItemView(itemId: itemId).computerEnvironment(computer)
                }
            case .reply(let computerId, let itemId, let commentId):
                if let computer = fleet.computer(id: computerId) {
                    ItemView(itemId: itemId, answering: commentId).computerEnvironment(computer)
                }
            case .release(let computerId, let releaseId):
                if let computer = fleet.computer(id: computerId) {
                    ReleaseView(releaseId: releaseId).computerEnvironment(computer)
                }
            case .note(let title, let text):
                NeedsNote(title: title, text: text)
            }
        }
    }
}

extension View {
    func needsDestinations() -> some View { modifier(NeedsDestinations()) }
    func homeProjectDestinations() -> some View { modifier(HomeProjectDestinations()) }
}

/// A project from the home: its screen, on the page the link asks for.
struct HomeProjectDestinations: ViewModifier {
    @Environment(Fleet.self) private var fleet

    func body(content: Content) -> some View {
        content.navigationDestination(for: HomeProjectLink.self) { link in
            if let computer = fleet.computer(id: link.computerId) {
                switch link.page {
                case .overview: ProjectScreen(projectId: link.projectId).computerEnvironment(computer)
                case .board: ProjectScreen(projectId: link.projectId, segment: .board).computerEnvironment(computer)
                case .settings: ProjectView(projectId: link.projectId).computerEnvironment(computer)
                }
            }
        }
    }
}

/// One thing waiting: what it is and how long it has waited.
/// A permission prompt row as people read it: "Backend Dev wants to run Bash",
/// with the command apart. Parses the daemon's "<bot> asks: <Tool>: <command>";
/// a title in another shape stays as it is.
struct PermissionWords: Equatable {
    let title: String
    let command: String?

    init(_ daemonTitle: String) {
        guard let asks = daemonTitle.range(of: " asks: ") else {
            title = daemonTitle
            command = nil
            return
        }
        let bot = daemonTitle[..<asks.lowerBound]
        let rest = daemonTitle[asks.upperBound...]
        let tool: Substring
        let detail: Substring?
        if let colon = rest.range(of: ": ") {
            tool = rest[..<colon.lowerBound]
            detail = rest[colon.upperBound...]
        } else {
            tool = rest
            detail = nil
        }
        title = "\(bot) wants to run \(PermissionRequest.displayName(ofTool: String(tool)))"
        let line = detail.map { $0.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces) }
        command = line?.isEmpty == false ? line : nil
    }

    /// One line, cut in the middle when long, so both ends stay readable.
    static func middleTruncated(_ text: String, limit: Int = 44) -> String {
        guard text.count > limit else { return text }
        let head = (limit - 1) / 2
        return "\(text.prefix(head))…\(text.suffix(limit - 1 - head))"
    }
}

extension Fleet {
    /// The computer that keeps a card's board: the project's board home from the
    /// projects home, when this phone talks to it (H-210).
    func boardComputer(itemId: String) -> Computer? {
        guard let place = cards.home(for: itemId) else { return nil }
        let daemon = computer(id: place.computerId)?.store.daemonId
        let card = home.cards(computers).first { card in
            card.row.projectID == place.projectId
                || card.row.members.contains { $0.projectID == place.projectId && $0.daemonID == daemon }
        }
        guard let boardHome = card?.row.boardHome, !boardHome.isEmpty else { return nil }
        return computer(daemonId: boardHome)
    }
}

extension HomeAttentionRow {
    /// The card a row is about, for its long-press preview; empty otherwise.
    var itemIdText: String {
        if case .itemID(let id)? = target { return id }
        return ""
    }
}

extension HomeAttentionRow {
    /// A permission prompt in the glossary's words (UX-031), not the daemon's
    /// "Backend Dev asks: Bash: rm -rf build/".
    var permissionWords: PermissionWords? { kind == .permissionPrompt ? PermissionWords(title) : nil }

    /// A row about one card reads "H-293 · <title>" (UX-035 §2).
    var displayTitle: String {
        if let prompt = permissionWords { return prompt.title }
        if case .itemID(let id)? = target, !title.hasPrefix(id) { return "\(id) · \(title)" }
        return title
    }

    /// The command, if any, the kind, and how long it has waited.
    var needsSubtitle: String {
        var parts = [kindWord]
        if let command = permissionWords?.command { parts.insert(PermissionWords.middleTruncated(command), at: 0) }
        if hasCreatedAt { parts.append(createdAt.date.relative) }
        return parts.joined(separator: " · ")
    }

    var kindWord: String {
        switch kind {
        case .releaseAwaiting: "Release to test"
        case .ownerAction: "Run card"
        case .permissionPrompt: "Permission request"
        case .decision: priority == "urgent" || priority == "P0" ? "Urgent decision" : "Decision"
        case .relayedRulings: "Rulings to confirm"
        case .p0Item: "P0 item"
        case .botWaiting: "Waiting for you"
        case .offBoard: "Off the board"
        case .servingOff: "Not serving"
        case .ownerQuestion: "Question"
        case .draftUpdated: "Draft updated"
        default: "Needs you"
        }
    }

    var symbol: String {
        switch kind {
        case .releaseAwaiting: "shippingbox.fill"
        case .ownerAction: "terminal.fill"
        case .permissionPrompt: "hand.raised.fill"
        case .decision: "checklist"
        case .relayedRulings: "checkmark.seal"
        case .p0Item: "exclamationmark.triangle.fill"
        case .botWaiting: "person.crop.circle.badge.clock"
        case .offBoard: "rectangle.dashed"
        case .servingOff: "wifi.slash"
        case .ownerQuestion: "questionmark.bubble.fill"
        case .draftUpdated: "square.and.pencil"
        default: "circle"
        }
    }

    var tone: Tone {
        switch kind {
        case .p0Item, .servingOff: .failed
        case .decision where priority == "urgent" || priority == "P0": .failed
        case .relayedRulings, .offBoard: .quiet
        case .ownerQuestion, .draftUpdated: .working
        default: .needsYou
        }
    }
}

struct NeedsRow: View {
    let row: HomeAttentionRow

    var body: some View {
        // The command gets its own room, so "Permission request · 8m ago" stays whole.
        ItemRow(title: row.displayTitle, subtitle: row.needsSubtitle, titleLines: 2,
                subtitleLines: row.permissionWords?.command == nil ? 1 : 2) {
            IconTile(systemImage: row.symbol, tone: row.tone)
        }
    }
}

/// A row the phone can't act on yet: says where to.
struct NeedsNote: View {
    let title: String
    let text: String

    var body: some View {
        List {
            Section {
                Text(title).font(.headline)
                Text(text).foregroundStyle(Color.secondaryText)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Needs you")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Swipe a stale question away (H-210): `attention_dismiss` on the computer
/// that holds it, then the home reloads. Outside a list, where rows don't
/// swipe, it is in the row's long-press menu.
private struct DismissRow: ViewModifier {
    @Environment(Fleet.self) private var fleet
    let row: HomeAttentionRow
    var swipe = true
    @State private var failure: String?

    func body(content: Content) -> some View {
        if Dismissal.allowed(row) {
            Group {
                if swipe {
                    content.swipeActions(edge: .trailing) {
                        Button("Dismiss", systemImage: "xmark.circle") { dismiss() }
                            .tint(.gray)
                    }
                } else {
                    content.contextMenu {
                        Button("Dismiss", systemImage: "xmark.circle") { dismiss() }
                    }
                }
            }
            .accessibilityAction(named: "Dismiss") { dismiss() }
            .alert("Couldn’t dismiss this question", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
        } else {
            content
        }
    }

    private func dismiss() {
        guard let computer = fleet.computer(daemonId: Dismissal.daemonId(of: row)) else {
            failure = "The computer that holds this question isn’t connected."
            return
        }
        Task {
            do {
                try await computer.store.dismissAttention(row.id)
                await fleet.home.refreshAll(fleet.computers, force: true)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

extension View {
    func dismissible(_ row: HomeAttentionRow, swipe: Bool = true) -> some View { modifier(DismissRow(row: row, swipe: swipe)) }
}
