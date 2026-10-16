import SwiftUI

// UX-024: a project opens on its Overview; Board and Team follow, then
// Releases and Meetings. Board, releases and meetings come from the board's
// home; bots from the computer that answered (H-128 R2.1).

struct ProjectScreen: View {
    @Environment(Fleet.self) private var fleet
    @Environment(AppStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    let projectId: String
    @State private var segment = Segment.overview
    @State private var showingArtifacts = false

    enum Segment: String, CaseIterable {
        case overview = "Overview", board = "Board", team = "Team", releases = "Releases", meetings = "Meetings"
    }

    private var project: Project? { store.projects.first { $0.id == projectId } }
    private var name: String { project?.name ?? card?.row.name ?? "Project" }

    /// The computer that keeps the board (UX-029): the board home's member name.
    private var boardHomeName: String? {
        guard let card else { return nil }
        return card.row.members.first { $0.daemonID == card.row.boardHome }?.computerName.nilIfEmpty
    }

    /// "▲ 4 need you" and the release pill under the name, as on desktop (U2).
    @ViewBuilder private var header: some View {
        let waiting = Int(card?.row.attention.count ?? 0)
        let release = card?.row.hasCurrentRelease == true ? card?.row.currentRelease : nil
        if sizeClass == .regular || waiting > 0 || release != nil {
            VStack(alignment: .leading, spacing: 6) {
                if sizeClass == .regular {
                    Text(name).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                }
                HStack(spacing: 6) {
                    if waiting > 0 { Pill(text: "▲ \(waiting) need you", tone: .needsYou) }
                    if let release {
                        let (text, tone) = ReleaseStatusWords.pill(release)
                        Pill(text: text, tone: tone)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    /// This project's card on the home, for its members and board home.
    private var card: HomeCard? {
        fleet.home.cards(fleet.computers).first { card in
            card.row.projectID == projectId || card.row.members.contains { $0.projectID == projectId && $0.daemonID == store.daemonId }
        }
    }

    /// The board's home and the project's id there, when the phone talks to
    /// it; else this computer, which mirrors or forwards.
    private var home: (computer: Computer, projectId: String)? {
        if let card, let computer = fleet.computer(daemonId: card.row.boardHome),
           let member = card.row.members.first(where: { $0.daemonID == card.row.boardHome }) {
            return (computer, member.projectID)
        }
        return fleet.computers.first { $0.store === store }.map { ($0, projectId) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Picker("Section", selection: $segment) {
                ForEach(Segment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            Group {
                switch segment {
                case .overview: OverviewPane(projectId: projectId, card: card, home: home)
                case .board: BoardPane(home: home, homeName: boardHomeName)
                case .team: TeamPane(projectId: projectId)
                case .releases: ReleasesPane(home: home)
                case .meetings: MeetingsPane(home: home)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        // iPad keyboard (UX-023 §2.7): ⌘1–5 pick a segment.
        .background {
            ForEach(Array(Segment.allCases.enumerated()), id: \.offset) { index, choice in
                Button(choice.rawValue) { segment = choice }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .navigationTitle(sizeClass == .regular ? "" : name)
        // iPad's detail column draws no large title, so the header carries the name (UX-029).
        .navigationBarTitleDisplayMode(sizeClass == .regular ? .inline : .large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Artifacts", systemImage: "doc.on.doc") { showingArtifacts = true }
                    NavigationLink { ConversationsView(projectId: projectId) } label: {
                        Label("Conversations", systemImage: "bubble.left.and.bubble.right")
                    }
                    NavigationLink { ProjectView(projectId: projectId) } label: {
                        Label("Project settings", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
        }
        .sheet(isPresented: $showingArtifacts) { ReportsView() }
        #if DEBUG
        .task {
            if let name = UserDefaults.standard.string(forKey: "openSegment"),
               let chosen = Segment.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(name.lowercased()) }) {
                segment = chosen
            }
        }
        #endif
    }
}

/// Words for a board kept on another computer (UX-029).
enum BoardWords {
    static func elsewhere(_ home: String?) -> String {
        "This project's board is kept on \(home ?? "another computer"). Open it there, or link this computer to see it here."
    }

    /// The service's "not the board's home here" answers.
    static func isElsewhere(_ error: Error) -> Bool {
        if let error = error as? DaemonError, ["no_board", "not_home", "elsewhere"].contains(error.code) { return true }
        let text = error.localizedDescription.lowercased()
        return text.contains("linked with another computer") || text.contains("open it there")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: Overview

struct OverviewPane: View {
    @Environment(Fleet.self) private var fleet
    let projectId: String
    let card: HomeCard?
    let home: (computer: Computer, projectId: String)?
    @State private var dashboard: Dashboard?
    @State private var failure: String?

    /// An older service's rows are read live from its store, which fills in after connect.
    private var needs: [HomeAttentionRow] {
        guard let card else { return [] }
        if let computer = fleet.computer(id: card.computerId), card.row.legacy || !computer.store.hasHome {
            return computer.store.legacyAttention(projectId: card.row.projectID)
        }
        return fleet.home.attention[card.id] ?? []
    }

    var body: some View {
        List {
            if let card, card.row.attention.count > 0 {
                Section {
                    if needs.isEmpty {
                        Text(AttentionWords.summary(card.row.attention, limit: 5)).foregroundStyle(Color.secondaryText)
                    }
                    // Up to 5 here; the rest wait in Needs you (UX-029).
                    ForEach(needs.prefix(5), id: \.id) { row in
                        NavigationLink(value: fleet.needsDestination(row, answeredBy: card.computerId)) { NeedsRow(row: row) }
                            .cardMenu(for: row.itemIdText)
                            .dismissible(row)
                    }
                    let total = max(Int(card.row.attention.count), needs.count)
                    if total > 5 {
                        Button("See all \(total) in Needs you ›") { fleet.home.needsFocus = card.id }
                            .font(.subheadline.weight(.semibold))
                    }
                } header: {
                    SectionTitle("Needs you", count: Int(card.row.attention.count))
                }
            }
            Section {
                if let summary = card?.row.latestSummary, !summary.text.isEmpty {
                    ItemRow(title: "Latest summary", subtitle: summary.text, detail: summary.hasAt ? summary.at.date.relative : nil,
                            subtitleLines: 4) { IconTile(systemImage: "text.quote", tone: .working) }
                }
                ForEach(dashboard?.meetings.filter { $0.lastSummary != nil } ?? []) { meeting in
                    ItemRow(title: "\(meeting.name) minutes", subtitle: meeting.lastSummary, detail: meeting.lastHeldAt?.relative,
                            subtitleLines: 3) { IconTile(systemImage: "person.3") }
                }
                if card?.row.hasLatestSummary != true, dashboard?.meetings.contains(where: { $0.lastSummary != nil }) != true {
                    EmptyNote(text: "Nothing reported yet", systemImage: "text.quote")
                }
            } header: {
                SectionTitle("From the team")
            }
            if let dashboard, dashboard.hasBoard {
                Section {
                    Text(stripLine(dashboard)).font(.subheadline)
                    if dashboard.blocked > 0 || dashboard.stale > 0 {
                        Text([dashboard.blocked > 0 ? "\(dashboard.blocked) blocked" : nil,
                              dashboard.stale > 0 ? "\(dashboard.stale) stale" : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(Color.warningText)
                    }
                    if let done = dashboard.doneThisWeek {
                        Text("This week: \(done) done, \(dashboard.reworkThisWeek ?? 0) sent back")
                            .font(.footnote).foregroundStyle(Color.secondaryText)
                    }
                } header: {
                    SectionTitle("Board")
                }
            }
            if let release = dashboard?.releases.first, let home {
                Section {
                    NavigationLink(value: NeedsDestination.release(computerId: home.computer.id, releaseId: release.id)) {
                        ReleaseRow(release: release)
                    }
                } header: {
                    SectionTitle("Release")
                }
            }
            if let actions = dashboard?.actions, !actions.isEmpty {
                Section {
                    ForEach(actions) { action in
                        ItemRow(title: action.text, subtitle: actionLine(action)) {
                            IconTile(systemImage: "checkmark.circle", tone: action.overdue ? .needsYou : nil)
                        }
                    }
                } header: {
                    SectionTitle("Action items", count: actions.count)
                }
            }
            if let failure {
                Text(failure).font(.footnote).foregroundStyle(Color.errorText)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
        .task(id: home?.computer.store.status == .connected) { await load() }
    }

    private func load() async {
        if let card, let computer = fleet.computer(id: card.computerId) { await fleet.home.loadAttention(card, on: computer) }
        guard let home else { return }
        do {
            dashboard = try await home.computer.store.dashboard(projectId: home.projectId)
            failure = nil
        } catch {
            failure = "Couldn’t load the overview. \(error.localizedDescription)"
        }
    }

    /// "Doing 3 · Review 2/3 · Verify 3/3 full".
    private func stripLine(_ dashboard: Dashboard) -> String {
        let strip = dashboard.strip
        guard !strip.isEmpty else { return "No cards in progress" }
        return strip.map { column in
            // "Doing 0 of 1" (UX-038), not "0/1".
            let count = column.wipLimit.map { "\(column.count) of \($0)" } ?? "\(column.count)"
            return "\(column.name) \(count)\(column.full ? " full" : "")"
        }.joined(separator: " · ")
    }

    private func actionLine(_ action: Dashboard.Action) -> String {
        var parts: [String] = []
        if let meeting = action.meetingName { parts.append(meeting) }
        if let due = action.dueAt { parts.append((action.overdue ? "Overdue since " : "Due ") + due.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: Team

struct TeamPane: View {
    @Environment(AppStore.self) private var store
    @Environment(Fleet.self) private var fleet
    let projectId: String

    private var bots: [Bot] {
        guard let project = store.projects.first(where: { $0.id == projectId }) else { return [] }
        return store.bots(in: project)
    }

    var body: some View {
        List {
            if bots.isEmpty { EmptyNote(text: "No bots yet", systemImage: "person") }
            ForEach(bots) { bot in
                NavigationLink(value: NeedsDestination.bot(computerId: fleet.computers.first { $0.store === store }?.id ?? "", botId: bot.id, chat: false)) {
                    // With owner threads, the thread is the truth: no thread, nothing unread.
                    BotRow(bot: bot, unread: store.hasOwnerThreads ? (threadsLoaded ? (unread[bot.id] ?? 0) : 0) : nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        // How many of each bot's messages to you are unread (owner threads).
        .task(id: store.ownerThreadsVersion) {
            guard store.hasOwnerThreads, let threads = try? await store.ownerThreads() else { return }
            unread = Dictionary(threads.map { ($0.bot.botID, Int($0.unread)) }, uniquingKeysWith: max)
            threadsLoaded = true
        }
    }

    @State private var unread: [String: Int] = [:]
    @State private var threadsLoaded = false
}

// MARK: Releases

struct ReleaseRow: View {
    let release: Release

    var body: some View {
        let (words, tone) = release.statusWords
        VStack(alignment: .leading, spacing: 6) {
            ItemRow(title: release.version, subtitle: release.itemsTotal > 0 ? "\(release.itemsReady) of \(release.itemsTotal) items ready" : nil) {
                IconTile(systemImage: "shippingbox", tone: tone)
            } trailing: {
                Pill(text: words.replacingOccurrences(of: release.version + " ", with: "").capitalizedFirst, tone: tone)
            }
            // What only the owner can give it (H-248).
            WaitingPill(count: release.ownerBlockers?.count ?? 0).padding(.leading, 44)
        }
    }
}

struct ReleasesPane: View {
    let home: (computer: Computer, projectId: String)?
    @State private var releases: [Release]?
    @State private var failure: String?

    var body: some View {
        List {
            if let store = home?.computer.store { InstallOfferBanner(store: store) }
            if let releases {
                if releases.isEmpty { EmptyNote(text: "No releases yet", systemImage: "shippingbox") }
                ForEach(releases) { release in
                    NavigationLink(value: NeedsDestination.release(computerId: home?.computer.id ?? "", releaseId: release.id)) {
                        ReleaseRow(release: release)
                    }
                }
            } else if let failure {
                Text(failure).foregroundStyle(Color.errorText)
            } else {
                ProgressView()
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
        .task { await load() }
        .reloadsOnReconnect { await load() }
    }

    private func load() async {
        guard let home else { return }
        do { releases = try await home.computer.store.releases(projectId: home.projectId) } catch { failure = error.localizedDescription }
    }
}

/// A package: where it stands, its items and tests. Ruling on it comes with the release review.
struct ReleaseView: View {
    @Environment(Fleet.self) private var fleet
    @Environment(AppStore.self) private var store
    let releaseId: String
    @State private var release: Release?
    @State private var failure: String?
    /// What this package offers for install on this device (H-230).
    @State private var install: ReleaseInstallInfo?
    /// The owner's choices before approving: items left out, and where they go.
    @State private var leftOut: [String: LeftOut] = [:]
    @State private var leavingOut: String?
    @State private var holding = false
    @State private var rejecting = false
    @State private var busy = false
    /// Approvals wait out their Undo app-wide (UX-040): this screen shows the bar too.
    private var pending: RulingQueue.Pending? {
        fleet.rulings.pending.flatMap { $0.releaseId == releaseId ? $0 : nil }
    }

    /// The computer this release was read from.
    private var computerId: String { fleet.computers.first { $0.store === store }?.id ?? "" }

    /// Where Review… on the ruling scrolls to (UX-040's release review).
    private static let reviewAnchor = "release-review"
    /// "Now: waiting for you, …" goes to its row.
    private static let waitingAnchor = "waiting-for-you"

    /// The phone rules on a package waiting for the owner, when it may (H-160 AC4).
    private var reviewing: Bool {
        guard let release else { return false }
        return release.status == "awaiting_owner" && release.canRule && store.canApprove
    }

    var body: some View {
        ScrollViewReader { proxy in
        List {
            if let release {
                // What only the owner can give it, at the top (H-248, UX-048).
                if let blockers = release.ownerBlockers, !blockers.isEmpty {
                    WaitingSection(blockers: blockers, computerId: computerId) {
                        withAnimation { proxy.scrollTo(Self.reviewAnchor, anchor: .top) }
                    }
                    .id(Self.waitingAnchor)
                }
                Section {
                    let (words, tone) = release.statusWords
                    Pill(text: words, tone: tone)
                    if let by = release.createdBy.flatMap({ store.bot($0)?.name }) ?? release.createdBy {
                        Text([by, release.createdAt.map { $0.formatted(date: .omitted, time: .shortened) }].compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(Color.secondaryText)
                    }
                    if let changelog = release.changelog, !changelog.isEmpty {
                        LinkedText(markdown: changelog)
                    }
                    if release.status == "awaiting_owner", let why = ReleaseReview.cannotRule(release, canApprove: store.canApprove) {
                        Text(why).font(.footnote).foregroundStyle(Color.secondaryText)
                    }
                }
                // Install on this device, under the status and above the items (H-230).
                if let install { InstallSection(info: install) }
                if !release.tests.isEmpty {
                    Section {
                        ForEach(release.tests) { test in
                            LabeledContent(test.machine, value: test.result == "pass" ? "✓ Passed" : "✗ \(test.result.capitalizedFirst)")
                        }
                    } header: {
                        SectionTitle("Tests")
                    }
                }
                Section {
                    // Who it waits on now (UX-048 §3).
                    if ReleaseNow.shows(release) {
                        let now = ReleaseNow.line(release) { store.bot($0)?.name }
                        if now.waitsForYou {
                            Button(now.text) { withAnimation { proxy.scrollTo(Self.waitingAnchor, anchor: .top) } }
                                .font(.subheadline.weight(.medium))
                        } else {
                            Text(now.text).font(.subheadline.weight(.medium))
                        }
                    }
                    // A service without owner_blockers: point to Needs you (a row, not the
                    // footer, which only showed while the package was still being built).
                    if ReleaseNow.pointsToNeedsYou(release) {
                        Button(WaitingWords.olderService) { fleet.home.needsFocus = "" }
                            .font(.footnote)
                            .accessibilityHint("Opens Needs you")
                    }
                    ForEach(release.items) { item in itemRow(release, item) }
                } header: {
                    SectionTitle(release.showsProgress ? "Progress" : "Items", count: release.items.count)
                } footer: {
                    if release.showsProgress {
                        Text(release.readinessLine).foregroundStyle(Color.secondaryText)
                    } else if reviewing, let line = ReleaseReview.leftOutLine(leftOut.count) {
                        Text(line).foregroundStyle(Color.secondaryText)
                    }
                }
                if reviewing { actions(release).id(Self.reviewAnchor) }
                if let failure {
                    Text(failure).font(.footnote).foregroundStyle(Color.errorText)
                }
            } else if let failure {
                Text(failure).foregroundStyle(Color.errorText)
            } else {
                ProgressView()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(release?.version ?? "Release")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .reloadsOnReconnect { await load() }
        // Its owner_blockers changed (H-248): read it again.
        .onChange(of: store.releaseUpdated) { _, update in if update?.releaseId == releaseId { Task { await load() } } }
        // An approval for this package ended (here or elsewhere): show it as it is now.
        .task(id: fleet.rulings.outcome?.id) {
            guard let outcome = fleet.rulings.outcome, outcome.releaseId == releaseId else { return }
            await load()
            if outcome.clearsChoices { leftOut = [:] }
        }
        .sheet(item: Binding(get: { leavingOut.map(ItemRef.init) }, set: { leavingOut = $0?.id })) { ref in
            LeaveOutSheet(itemId: ref.id, title: release?.plan.first { $0.itemId == ref.id }?.title ?? "") { out in
                leftOut[ref.id] = out
                leavingOut = nil
            }
        }
        .sheet(isPresented: $holding) {
            if let release {
                HoldReleaseSheet(version: release.version) { note, remind in
                    holding = false
                    act { self.release = try await store.holdRelease(release, note: note, remindAt: remind) }
                }
            }
        }
        .sheet(isPresented: $rejecting) {
            if let release {
                RejectReleaseSheet(release: release) { reason, returns in
                    rejecting = false
                    act {
                        try await OwnerAuth.confirm("Reject \(release.version)?", action: .reject, computer: store.computerName)
                        self.release = try await store.ruleRelease(release,
                                                                   verdicts: ReleaseReview.rejection(release, reason: reason, returns: returns))
                    }
                }
            }
        }
        }
    }

    @ViewBuilder private func itemRow(_ release: Release, _ item: Release.Item) -> some View {
        let state = release.state(of: item) { store.bot($0)?.name }
        let out = leftOut[item.itemId]
        HStack(alignment: .top, spacing: 8) {
            // The row is the card: tap opens it, long-press previews it (H-204).
            NavigationLink(value: NeedsDestination.item(computerId: fleet.cards.home(for: item.itemId)?.computerId ?? computerId,
                                                        itemId: item.itemId)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.title).font(.subheadline.weight(.medium)).lineLimit(3)
                    if let meta = state.meta {
                        Text(meta).font(.caption).foregroundStyle(Color.secondaryText)
                    }
                    if let out {
                        Pill(text: "⤼ " + ReleaseReview.outWords(out), tone: .quiet)
                    } else if let pill = state.pill, let tone = state.tone {
                        Pill(text: pill, tone: tone)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .contentShape(Rectangle())
                .hoverEffect(.highlight)
            }
            .cardMenu(id: item.itemId)
            if reviewing {
                Button(out == nil ? "Leave out" : "Include") {
                    if out == nil { leavingOut = item.itemId } else { leftOut[item.itemId] = nil }
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.bordered)
                .accessibilityLabel(out == nil ? "Leave out \(item.itemId)" : "Include \(item.itemId)")
            }
        }
    }

    @ViewBuilder private func actions(_ release: Release) -> some View {
        Section {
            if let pending {
                HStack {
                    Text(pending.label).font(.subheadline)
                    Spacer()
                    Button("Undo") { fleet.rulings.undo() }.fontWeight(.semibold)
                }
            } else {
                Button {
                    approve(release)
                } label: {
                    Label(ReleaseReview.approveButton(release, leftOut: leftOut.count), systemImage: "faceid")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || leftOut.count == release.items.count)
                Button("Hold") { holding = true }.disabled(busy)
                Button("Reject…", role: .destructive) { rejecting = true }.disabled(busy)
            }
        } footer: {
            Text(ReleaseReview.approveBody(release, leftOut: leftOut.count)).foregroundStyle(Color.secondaryText)
        }
    }

    /// Face ID, then 5 s to Undo (app-wide), then `release_rule`.
    private func approve(_ release: Release) {
        let verdicts = ReleaseReview.approval(release, leftOut: leftOut)
        let count = leftOut.count
        let store = store
        act {
            try await OwnerAuth.confirm(ReleaseReview.approveQuestion(release, leftOut: count),
                                        action: .approve, computer: store.computerName)
            fleet.rulings.approve(release, leftOut: count) {
                try await store.ruleRelease(release, verdicts: verdicts)
            }
        }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            do {
                try await work()
                failure = nil
            } catch {
                // CE: the package changed under the owner: reload it and say so.
                if let release, RulingWords.isConflict(error) {
                    await load()
                    leftOut = [:]
                    failure = RulingWords.changed(release)
                } else {
                    failure = error.localizedDescription
                }
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            busy = false
        }
    }

    private func load() async {
        do { release = try await store.release(releaseId) } catch { failure = error.localizedDescription }
        // A service before 0.17.5 has no release_install: no install section.
        install = (try? await store.releaseInstall(releaseId)) ?? nil
    }
}

private struct ItemRef: Identifiable { let id: String }

/// "Leave out H-117?": where it goes, and why (desktop LeaveOutDialog).
struct LeaveOutSheet: View {
    @Environment(\.dismiss) private var dismiss
    let itemId: String
    let title: String
    let done: (LeftOut) -> Void
    @State private var verdict = LeftOut.Verdict.hold
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                if !title.isEmpty { Text(title) }
                Section("It goes") {
                    Picker("It goes", selection: $verdict) {
                        Text("Hold: it waits for the next release").tag(LeftOut.Verdict.hold)
                        Text("Rework: back to Doing, with a note").tag(LeftOut.Verdict.rework)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section(verdict == .rework ? "What needs rework" : "Note (optional)") {
                    TextField(verdict == .rework ? "What needs rework" : "Note (optional)", text: $note,
                              prompt: .placeholder(verdict == .rework ? "What needs rework" : "Note (optional)"), axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .navigationTitle("Leave out \(itemId)?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Leave out") { done(LeftOut(verdict: verdict, note: note.trimmingCharacters(in: .whitespacesAndNewlines))) }
                        .disabled(verdict == .rework && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// "Hold 0.17.0?": a note and when to be reminded (desktop HoldDialog).
struct HoldReleaseSheet: View {
    @Environment(\.dismiss) private var dismiss
    let version: String
    let done: (String, Date?) -> Void
    @State private var note = ""
    @State private var remind = ReleaseReview.Remind.tomorrow

    var body: some View {
        NavigationStack {
            Form {
                Section("Note (optional)") {
                    TextField("Note (optional)", text: $note, prompt: .placeholder("Note (optional)"), axis: .vertical).lineLimit(2...5)
                }
                Section("Remind me") {
                    Picker("Remind me", selection: $remind) {
                        ForEach(ReleaseReview.Remind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle("Hold \(version)?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hold") { done(note.trimmingCharacters(in: .whitespacesAndNewlines), remind.date()) }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// "Reject 0.17.0?": a reason for every item, and where each goes (desktop RejectDialog).
struct RejectReleaseSheet: View {
    @Environment(\.dismiss) private var dismiss
    let release: Release
    let done: (String, [String: LeftOut.Verdict]) -> Void
    @State private var reason = ""
    @State private var returns: [String: LeftOut.Verdict] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section("Reason (sent to DevOps and copied to every item)") {
                    TextField("Reason", text: $reason, prompt: .placeholder("Reason"), axis: .vertical).lineLimit(2...5)
                }
                Section {
                    ForEach(release.items) { item in
                        Picker(release.plan.first { $0.itemId == item.itemId }.map { "\(item.itemId) · \($0.title)" } ?? item.itemId,
                               selection: Binding(get: { returns[item.itemId] ?? .rework }, set: { returns[item.itemId] = $0 })) {
                            Text("Back to Doing").tag(LeftOut.Verdict.rework)
                            Text("Back to Ready").tag(LeftOut.Verdict.hold)
                        }
                        .accessibilityLabel("Where \(item.itemId) goes")
                    }
                } header: {
                    Text("Where each item goes")
                } footer: {
                    if let hint = ReleaseReview.rejectHint(returns.merging(Dictionary(uniqueKeysWithValues: release.items.map { ($0.itemId, LeftOut.Verdict.rework) })) { mine, _ in mine },
                                                           items: release.items.count) {
                        Text(hint).foregroundStyle(Color.secondaryText)
                    }
                }
            }
            .navigationTitle("Reject \(release.version)?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Reject", role: .destructive) { done(reason.trimmingCharacters(in: .whitespacesAndNewlines), returns) }
                        .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: Meetings

struct MeetingsPane: View {
    @Environment(Fleet.self) private var fleet
    let home: (computer: Computer, projectId: String)?
    @State private var dashboard: Dashboard?
    @State private var failure: String?

    var body: some View {
        List {
            if let dashboard {
                if dashboard.meetings.isEmpty { EmptyNote(text: "No meetings set up", systemImage: "person.3") }
                ForEach(dashboard.meetings) { meeting in
                    Section {
                        ItemRow(title: meeting.name, subtitle: line(meeting)) {
                            IconTile(systemImage: "person.3", tone: meeting.collecting ? .working : nil)
                        }
                        if let summary = meeting.lastSummary {
                            LinkedText(markdown: summary)
                        }
                    }
                }
            } else if let failure {
                Text(failure).foregroundStyle(Color.errorText)
            } else {
                ProgressView()
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
        .task { await load() }
        .reloadsOnReconnect { await load() }
    }

    private func line(_ meeting: Dashboard.Meeting) -> String {
        var parts: [String] = []
        if meeting.collecting { parts.append("Collecting now") }
        if let next = meeting.nextAt { parts.append("Next \(next.formatted(date: .abbreviated, time: .shortened))") }
        if let held = meeting.lastHeldAt { parts.append("Last held \(held.relative)") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard let home else { return }
        do { dashboard = try await home.computer.store.dashboard(projectId: home.projectId) } catch { failure = error.localizedDescription }
    }
}

extension String {
    /// "ship" → "Ship".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst().replacingOccurrences(of: "_", with: " ") }
}
