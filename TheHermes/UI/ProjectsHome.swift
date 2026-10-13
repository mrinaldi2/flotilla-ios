import SwiftUI

// UX-024: the app opens on Projects, ranked by how much each needs you, and
// Needs you gathers what is waiting across projects. Both span every
// computer and show the last answer at once.

/// A project to open from the home, on the computer that answered for it.
struct HomeProjectLink: Hashable {
    let computerId: String
    let projectId: String
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
    static func pill(_ release: Hermes_Home_V1_ReleaseBrief) -> (String, Tone) {
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

struct ProjectsHomeView: View {
    @Environment(Fleet.self) private var fleet
    @State private var path = NavigationPath()
    @State private var debugOpened = false
    /// Set from outside (a notification, Needs you): opens that project.
    var openProject: Binding<HomeProjectLink?> = .constant(nil)
    /// On iPad the sidebar shows the project: a card selects it there instead of pushing.
    var open: ((HomeProjectLink) -> Void)?

    private var feed: HomeFeed { fleet.home }
    private var cards: [HomeCard] { feed.cards(fleet.computers) }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if cards.isEmpty {
                    EmptyNote(text: fleet.computers.contains { $0.store.status == .connected }
                              ? "No projects yet" : "Connecting…", systemImage: "folder")
                }
                ForEach(cards) { card in
                    Section {
                        let link = HomeProjectLink(computerId: card.computerId, projectId: card.row.projectID)
                        Group {
                            if let open {
                                Button { open(link) } label: { ProjectCard(card: card).contentShape(Rectangle()) }
                                    .buttonStyle(.plain)
                            } else {
                                NavigationLink(value: link) { ProjectCard(card: card) }
                            }
                        }
                        // iPad pointer (UX-023 §2.7).
                        .hoverEffect(.highlight)
                        .contextMenu { pinButton(card) }
                        // The project that needs you most is outlined (UX-024).
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(.secondarySystemGroupedBackground))
                                .overlay {
                                    if card.rank == 1 {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange, lineWidth: 2)
                                    }
                                }
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(10)
            .navigationTitle("Projects")
            .refreshable { await feed.refreshAll(fleet.computers, force: true) }
            #if DEBUG
            .onChange(of: cards.map(\.row.projectID), initial: true) {
                guard !debugOpened, let name = UserDefaults.standard.string(forKey: "openProject"),
                      let card = cards.first(where: { $0.row.name.lowercased().hasPrefix(name.lowercased()) }) else { return }
                debugOpened = true
                let link = HomeProjectLink(computerId: card.computerId, projectId: card.row.projectID)
                if let open { open(link) } else { path = NavigationPath([link]) }
            }
            #endif
            .navigationDestination(for: HomeProjectLink.self) { link in
                if let computer = fleet.computers.first(where: { $0.id == link.computerId }) {
                    ProjectScreen(projectId: link.projectId).computerEnvironment(computer)
                }
            }
            .needsDestinations()
            // A card link from outside (iPad: PadRootView opens it in the project column).
            // On a cold start the link arrives before the projects: try again as they load (H-216).
            .onChange(of: fleet.openCard, initial: true) { openLinkedCard() }
            .onChange(of: fleet.cards.homes) { openLinkedCard() }
            .onChange(of: fleet.cards.settled) { openLinkedCard() }
            .onChange(of: openProject.wrappedValue, initial: true) { _, link in
                guard let link else { return }
                path = NavigationPath([link])
                openProject.wrappedValue = nil
            }
        }
        // Card ids anywhere in this stack open the card here (H-204).
        .opensCardLinks { path.append($0) }
    }

    private func openLinkedCard() {
        guard open == nil, let (id, home) = fleet.takeOpenCard() else { return }
        path.append(NeedsDestination.item(computerId: home.computerId, itemId: id))
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

/// One project on the home: why it ranks, its release, what is running, the
/// lead's latest word.
struct ProjectCard: View {
    let card: HomeCard

    private var row: HomeRow { card.row }
    private var waiting: Bool { row.attention.count > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                RankBadge(rank: card.rank)
                Text(row.name).font(.headline).lineLimit(1)
                if row.pinned {
                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(Color.secondaryText)
                        .accessibilityLabel("Pinned")
                }
            }
            Text(AttentionWords.summary(row.attention))
                .font(.subheadline.weight(waiting ? .medium : .regular))
                .foregroundStyle(waiting ? Color.warningText : Color.secondaryText)
            if row.hasCurrentRelease {
                let (text, tone) = ReleaseStatusWords.pill(row.currentRelease)
                Pill(text: text, tone: tone)
            }
            Text(running).font(.subheadline).foregroundStyle(Color.secondaryText)
            if row.hasLatestSummary, !row.latestSummary.text.isEmpty {
                Text("“\(row.latestSummary.text)”").font(.subheadline).lineLimit(2)
            }
            if row.legacy {
                Label("Update needed for full info", systemImage: "arrow.up.circle")
                    .font(.footnote).foregroundStyle(Color.secondaryText)
            } else if !card.staleNames.isEmpty {
                Label(staleLine, systemImage: "wifi.slash").font(.footnote).foregroundStyle(Color.secondaryText)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// "5 tasks running · 8 bots, 5 working, 1 waiting for you".
    private var running: String {
        var parts: [String] = []
        if row.openTasks > 0 { parts.append("\(row.openTasks) task\(row.openTasks == 1 ? "" : "s") running") }
        var bots = "\(row.bots) bot\(row.bots == 1 ? "" : "s")"
        if row.botsWorking > 0 { bots += ", \(row.botsWorking) working" }
        if row.botsWaiting > 0 { bots += ", \(row.botsWaiting) waiting for you" }
        if row.bots > 0, row.botsWorking == 0, row.botsWaiting == 0 { bots += ", all idle" }
        parts.append(bots)
        return parts.joined(separator: " · ")
    }

    /// "imac is offline · last seen 10:42", as on desktop (UX-029).
    private var staleLine: String {
        let names = ListFormatter.localizedString(byJoining: card.staleNames)
        let offline = "\(names) \(card.staleNames.count > 1 ? "are" : "is") offline"
        guard let since = card.staleSince else { return offline }
        return "\(offline) · last seen \(since.formatted(date: .omitted, time: .shortened))"
    }
}

/// "#1": the project's place by how much it needs you; a dash when nothing does.
struct RankBadge: View {
    let rank: Int?
    /// On a selected (accent-filled) sidebar row: white on a white outline (UX-029).
    var selected = false

    var body: some View {
        Text(rank.map { "#\($0)" } ?? "—")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(selected ? Color.white : rank == nil ? Color.secondaryText : Color.warningText)
            .background(selected ? Color.white.opacity(0.2) : (rank == nil ? Tone.quiet : Tone.needsYou).color.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay { if selected { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white, lineWidth: 1) } }
            .accessibilityLabel(rank.map { "Rank \($0)" } ?? "Nothing needs you")
    }
}

// MARK: Needs you

/// Where an outside route lands in Needs you: that screen on an empty stack.
enum NeedsRoute {
    static func path(to destination: NeedsDestination) -> NavigationPath { NavigationPath([destination]) }
}

struct NeedsYouView: View {
    @Environment(Fleet.self) private var fleet
    @State private var path = NavigationPath()
    @State private var showingDecisions = false
    /// Set from outside, e.g. a notification: opens that decision.
    var openDecision: Binding<NeedsDestination?> = .constant(nil)

    private var feed: HomeFeed { fleet.home }
    private var waiting: [HomeCard] { feed.cards(fleet.computers).filter { $0.row.attention.count > 0 } }
    private var hasTerminal: Bool { fleet.computers.contains { $0.store.permissions.contains(where: \.isTerminal) } }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
            List {
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
                if waiting.isEmpty, !hasTerminal {
                    EmptyNote(text: "Nothing is waiting on you.", systemImage: "checkmark.circle")
                }
                ForEach(waiting) { card in
                    Section {
                        let rows = feed.attention[card.id] ?? []
                        if rows.isEmpty {
                            Text(AttentionWords.summary(card.row.attention, limit: 5))
                                .font(.subheadline).foregroundStyle(Color.secondaryText)
                        }
                        ForEach(rows, id: \.id) { row in
                            NavigationLink(value: fleet.needsDestination(row, answeredBy: card.computerId)) { NeedsRow(row: row) }
                            .cardMenu(for: row.itemIdText)
                            .dismissible(row)
                        }
                    } header: {
                        SectionTitle(card.rank.map { "\(card.row.name) · #\($0)" } ?? card.row.name)
                    }
                    .id(card.id)
                    // Cached cards show before their computer connects: reload once it does.
                    .task(id: "\(card.id)/\(card.row.attention.count)/\(card.row.attention.score)/\(fleet.computer(id: card.computerId)?.store.status == .connected)") {
                        if let computer = fleet.computer(id: card.computerId) { await feed.loadAttention(card, on: computer) }
                    }
                }
            }
            // "See all in Needs you" on a project's Overview: scroll to that project.
            .onChange(of: feed.needsFocus, initial: true) { _, id in
                guard let id else { return }
                path = NavigationPath()
                withAnimation { proxy.scrollTo(id, anchor: .top) }
                feed.needsFocus = nil
            }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Needs you")
            .toolbar {
                // Every decision, settled ones too (UX-024: Needs you → Decisions).
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Decisions") { showingDecisions = true }
                }
            }
            .sheet(isPresented: $showingDecisions) { DecisionsView(openDecision: .constant(nil)) }
            .refreshable { await feed.refreshAll(fleet.computers, force: true) }
            .needsDestinations()
            .onChange(of: openDecision.wrappedValue, initial: true) { _, destination in
                guard let destination else { return }
                openDecision.wrappedValue = nil
                // On iPad a route switches the sidebar to Needs you and arrives as this
                // column first shows; pushed in that same update it is lost, since the
                // split view rebuilds the detail stack right after. Push on the next turn (H-230).
                Task { @MainActor in path = NeedsRoute.path(to: destination) }
            }
        }
        // Card ids anywhere in this stack open the card here (H-204).
        .opensCardLinks { path.append($0) }
    }

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
            return .note(title: row.title, text: "Answer it on \(place), in The Hermes app.")
        case .bot(let ref)?:
            if let botComputer = computer(daemonId: ref.daemonID) ?? on {
                return .bot(computerId: botComputer.id, botId: ref.botID, chat: true)
            }
        case .releaseID(let id)?:
            if let on { return .release(computerId: on.id, releaseId: id) }
        case .actionID?:
            return .note(title: row.title, text: "Run cards come to the phone in a later update. For now, run or reject it on \(place), in The Hermes app.")
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

struct NeedsRow: View {
    let row: HomeAttentionRow

    /// A permission prompt in the glossary's words (UX-031), not the daemon's
    /// "Backend Dev asks: Bash: rm -rf build/".
    private var prompt: PermissionWords? { row.kind == .permissionPrompt ? PermissionWords(row.title) : nil }

    /// A row about one card reads "H-293 · <title>" (UX-035 §2).
    private var title: String {
        if let prompt { return prompt.title }
        if case .itemID(let id)? = row.target, !row.title.hasPrefix(id) { return "\(id) · \(row.title)" }
        return row.title
    }

    var body: some View {
        // The command gets its own room, so "Permission request · 8m ago" stays whole.
        ItemRow(title: title, subtitle: subtitle, titleLines: 2,
                subtitleLines: prompt?.command == nil ? 1 : 2) {
            IconTile(systemImage: symbol, tone: tone)
        }
    }

    private var subtitle: String {
        var parts = [kindWord]
        if let command = prompt?.command { parts.insert(PermissionWords.middleTruncated(command), at: 0) }
        if row.hasCreatedAt { parts.append(row.createdAt.date.relative) }
        return parts.joined(separator: " · ")
    }

    private var kindWord: String {
        switch row.kind {
        case .releaseAwaiting: "Release to test"
        case .ownerAction: "Run card"
        case .permissionPrompt: "Permission request"
        case .decision: row.priority == "urgent" || row.priority == "P0" ? "Urgent decision" : "Decision"
        case .relayedRulings: "Rulings to confirm"
        case .p0Item: "P0 item"
        case .botWaiting: "Waiting for you"
        case .offBoard: "Off the board"
        case .servingOff: "Not serving"
        case .ownerQuestion: "Question"
        default: "Needs you"
        }
    }

    private var symbol: String {
        switch row.kind {
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
        default: "circle"
        }
    }

    private var tone: Tone {
        switch row.kind {
        case .p0Item, .servingOff: .failed
        case .decision where row.priority == "urgent" || row.priority == "P0": .failed
        case .relayedRulings, .offBoard: .quiet
        case .ownerQuestion: .working
        default: .needsYou
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
/// that holds it, then Needs you reloads.
private struct DismissRow: ViewModifier {
    @Environment(Fleet.self) private var fleet
    let row: HomeAttentionRow
    @State private var failure: String?

    func body(content: Content) -> some View {
        if Dismissal.allowed(row) {
            content
                .swipeActions(edge: .trailing) {
                    Button("Dismiss", systemImage: "xmark.circle") { dismiss() }
                        .tint(.gray)
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
    func dismissible(_ row: HomeAttentionRow) -> some View { modifier(DismissRow(row: row)) }
}
