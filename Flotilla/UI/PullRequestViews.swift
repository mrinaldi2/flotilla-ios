import SwiftUI

// Pull requests on the phone (H-261, `pull_requests`): on a card, a
// project's list, and one PR with its reviews, findings, checks and the
// owner's Approve, Request changes and Undo. Every line that names a branch
// names the PR's own base.

extension PRTone {
    var color: Color {
        switch self {
        case .dim: Color.secondaryText
        default: tone.text
        }
    }
}

/// One PR as a row: its number and title, the line that says where it stands, its reviewers.
struct PRRow: View {
    let pr: PullRequest
    var showsCard = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 4) {
                Text(PRWords.title(pr)).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(PRWords.stateLine(pr, now: context.date))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(PRWords.stateTone(pr).color)
                    .lineLimit(2)
                if pr.state == .open {
                    let chips = PRWords.roles(pr).map { PRWords.chip(pr, role: $0).text }
                    if !chips.isEmpty {
                        Text(chips.joined(separator: "  ")).font(.caption).foregroundStyle(Color.secondaryText).lineLimit(2)
                    }
                }
                Text([showsCard && !pr.itemID.isEmpty ? pr.itemID : nil, PRWords.meta(pr)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(Color.secondaryText).lineLimit(1)
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .combine)
    }
}

extension Fleet {
    /// The computer whose store this is.
    func computer(of store: AppStore) -> Computer? { computers.first { $0.store === store } }
}

/// A card's PRs (H-261): each with its state in one line; a tap opens it.
struct CardPullRequests: View {
    @Environment(Fleet.self) private var fleet
    @Environment(AppStore.self) private var store
    let projectId: String
    let itemId: String
    @State private var prs: [PullRequest] = []

    var body: some View {
        Group {
            if !prs.isEmpty {
                Section {
                    ForEach(prs, id: \.id) { pr in
                        NavigationLink(value: NeedsDestination.pullRequest(computerId: fleet.computer(of: store)?.id ?? "",
                                                                           projectId: projectId, number: pr.number)) {
                            PRRow(pr: pr, showsCard: false)
                        }
                        .accessibilityIdentifier("card-pr-\(pr.number)")
                    }
                } header: {
                    SectionTitle(prs.count == 1 ? "Pull request" : "Pull requests", count: prs.count > 1 ? prs.count : nil)
                }
            }
        }
        .task(id: "\(store.reconnects)/\(store.prRevision[projectId] ?? 0)") { await load() }
    }

    private func load() async {
        guard store.hasPullRequests, store.status == .connected, !projectId.isEmpty else { return }
        if let all = try? await store.pullRequests(projectId: projectId, states: PRWords.allStates) {
            prs = PRWords.ordered(all.filter { $0.itemID == itemId })
        }
    }
}

/// A project's few open PRs on its Overview, and the way to all of them.
struct OverviewPullRequests: View {
    @Environment(Fleet.self) private var fleet
    let computer: Computer
    let projectId: String
    @State private var open: [PullRequest]?

    private var store: AppStore { computer.store }

    var body: some View {
        Group {
            if store.hasPullRequests {
                Section {
                    ForEach((open ?? []).prefix(3), id: \.id) { pr in
                        NavigationLink(value: NeedsDestination.pullRequest(computerId: computer.id, projectId: projectId, number: pr.number)) {
                            PRRow(pr: pr)
                        }
                    }
                    if open?.isEmpty == true {
                        EmptyNote(text: "No open pull requests", systemImage: "arrow.triangle.pull")
                    }
                    NavigationLink(value: NeedsDestination.pullRequests(computerId: computer.id, projectId: projectId)) {
                        Label("All pull requests", systemImage: "arrow.triangle.pull")
                    }
                    .accessibilityIdentifier("project-pull-requests")
                } header: {
                    SectionTitle("Pull requests", count: (open?.isEmpty ?? true) ? nil : open?.count)
                }
                .task(id: "\(store.reconnects)/\(store.prRevision[projectId] ?? 0)") {
                    guard store.status == .connected else { return }
                    open = PRWords.ordered((try? await store.pullRequests(projectId: projectId, states: [])) ?? open ?? [])
                }
            }
        }
    }
}

/// A project's PRs: open and merging first, then merged and closed.
struct ProjectPullRequestsScreen: View {
    @Environment(Fleet.self) private var fleet
    @Environment(AppStore.self) private var store
    let projectId: String
    @State private var prs: [PullRequest]?
    @State private var failure: String?

    private var live: [PullRequest] { (prs ?? []).filter { $0.state == .open || $0.state == .merging } }
    private var done: [PullRequest] { (prs ?? []).filter { $0.state == .merged || $0.state == .closed } }

    var body: some View {
        List {
            if prs != nil {
                Section {
                    if live.isEmpty { EmptyNote(text: "No open pull requests", systemImage: "arrow.triangle.pull") }
                    ForEach(live, id: \.id) { row($0) }
                } header: {
                    SectionTitle("Open", count: live.isEmpty ? nil : live.count)
                }
                if !done.isEmpty {
                    Section {
                        ForEach(done, id: \.id) { row($0) }
                    } header: {
                        SectionTitle("Merged and closed", count: done.count)
                    }
                }
            }
            if let failure {
                Section { Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.errorText) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Pull requests")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if prs == nil && failure == nil { ProgressView() } }
        .refreshable { await load() }
        .task(id: "\(store.reconnects)/\(store.prRevision[projectId] ?? 0)") { await load() }
    }

    private func row(_ pr: PullRequest) -> some View {
        NavigationLink(value: NeedsDestination.pullRequest(computerId: fleet.computer(of: store)?.id ?? "", projectId: projectId, number: pr.number)) {
            PRRow(pr: pr)
        }
        .accessibilityIdentifier("pr-\(pr.number)")
    }

    private func load() async {
        guard store.hasPullRequests else {
            failure = "Update Flotilla on \(store.computerName) to see pull requests here."
            return
        }
        do {
            prs = PRWords.ordered(try await store.pullRequests(projectId: projectId, states: PRWords.allStates))
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// One PR: where it stands, its reviews (each role's latest), findings and
/// checks, and the owner's Approve, Request changes and Undo.
struct PRDetailScreen: View {
    @Environment(Fleet.self) private var fleet
    @Environment(AppStore.self) private var store
    let projectId: String
    let number: UInt32
    @State private var model: PRReviewModel?
    @State private var noting = false

    var body: some View {
        List {
            if let model, let pr = model.pr {
                header(pr)
                banner(pr, model: model)
                reviews(pr)
                findings(pr)
                checks(pr)
                if let failure = model.failure {
                    Section { Label(failure, systemImage: "xmark.octagon").foregroundStyle(Color.errorText) }
                }
                if pr.state == .open, !store.canApprove {
                    Section {
                        Text("This device can’t review pull requests. Review it on \(store.computerName), in the Flotilla app.")
                            .font(.footnote).foregroundStyle(Color.secondaryText)
                    }
                }
            } else if let failure = model?.loadFailure {
                Text(failure).foregroundStyle(Color.errorText)
            } else {
                ProgressView()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("#\(number)")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if let model, let pr = model.pr, store.canApprove { actions(pr, model: model) }
        }
        .task(id: "\(store.reconnects)/\(store.prRevision[projectId] ?? 0)") {
            if model == nil { model = PRReviewModel(projectId: projectId, number: number, service: store) }
            await model?.load()
        }
        .sheet(isPresented: $noting) {
            if let model {
                PRChangesSheet(note: Binding(get: { model.note }, set: { model.note = $0 })) {
                    noting = false
                    Task { await model.requestChanges() }
                }
            }
        }
    }

    @ViewBuilder private func header(_ pr: PullRequest) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(pr.title.isEmpty ? pr.itemTitle : pr.title).font(.headline)
                Text(PRWords.meta(pr)).font(.footnote).foregroundStyle(Color.secondaryText)
                if !pr.repo.isEmpty {
                    Text(pr.repo).font(.caption.monospaced()).foregroundStyle(Color.secondaryText)
                }
            }
            .accessibilityElement(children: .combine)
            if !pr.itemID.isEmpty {
                NavigationLink(value: NeedsDestination.item(computerId: fleet.boardComputer(itemId: pr.itemID)?.id
                                                                ?? fleet.computer(of: store)?.id ?? "", itemId: pr.itemID)) {
                    Label(pr.itemTitle.isEmpty ? pr.itemID : "\(pr.itemID) · \(pr.itemTitle)", systemImage: "square.stack")
                        .lineLimit(2)
                }
                .accessibilityIdentifier("pr-card")
            }
        }
    }

    /// How it ended, or the merge rule and what it waits for; the Undo window while it merges.
    @ViewBuilder private func banner(_ pr: PullRequest, model: PRReviewModel) -> some View {
        Section {
            TimelineView(.periodic(from: .now, by: pr.state == .merging ? 1 : 60)) { context in
                VStack(alignment: .leading, spacing: 6) {
                    if let done = PRWords.doneLine(pr, now: context.date) {
                        Text(done).font(.subheadline.weight(.semibold)).foregroundStyle(PRWords.stateTone(pr).color)
                        if pr.state == .merging, model.canUndo(now: context.date) {
                            Text("In \(model.secondsLeft(now: context.date)) s. Nothing is pushed until then.")
                                .font(.footnote).foregroundStyle(Color.secondaryText)
                        }
                    } else {
                        Text(PRWords.mergeRule(pr)).font(.subheadline.weight(.semibold))
                        if pr.mergeable.ok {
                            Text("Everything is in: it merges into \(PRWords.base(pr)) next.").font(.subheadline)
                                .foregroundStyle(PRTone.ok.color)
                        } else if !PRWords.waitingFor(pr).isEmpty {
                            Text("Waiting for: \(PRWords.waitingFor(pr)).").font(.subheadline)
                                .foregroundStyle(PRWords.waitsForYou(pr) ? PRTone.you.color : Color.primary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("pr-banner")
            }
            if pr.state == .open {
                ForEach(Array(PRWords.otherBlockers(pr).enumerated()), id: \.offset) { _, blocker in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(blocker.text, systemImage: blocker.kind == .conflicts ? "exclamationmark.triangle" : "arrow.down.circle")
                            .font(.footnote)
                        if !blocker.paths.isEmpty {
                            Text(blocker.paths.joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(Color.secondaryText)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func reviews(_ pr: PullRequest) -> some View {
        let roles = PRWords.roles(pr)
        if !roles.isEmpty {
            Section {
                ForEach(roles, id: \.self) { role in
                    let state = PRWords.reviewState(pr, role: role)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(PRWords.role(role)).font(.subheadline.weight(.semibold))
                            Spacer(minLength: 4)
                            Text("\(state.glyph) \(state.text)").font(.footnote.weight(.medium)).foregroundStyle(state.tone.color)
                        }
                        Text(PRWords.reviewMeta(pr, role: role)).font(.footnote).foregroundStyle(Color.secondaryText).lineLimit(3)
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("pr-review-\(role)")
                }
            } header: {
                SectionTitle("Reviews")
            }
        }
    }

    @ViewBuilder private func findings(_ pr: PullRequest) -> some View {
        let all = PRWords.findings(pr)
        if !all.isEmpty {
            Section {
                ForEach(Array(all.enumerated()), id: \.offset) { _, entry in
                    let state = PRWords.findingState(entry.finding)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(PRWords.severity(entry.finding)) · \(PRWords.role(entry.role))").font(.caption.weight(.semibold))
                                .foregroundStyle(entry.finding.severity == .must && state.open ? Tone.needsYou.text : Color.secondaryText)
                            Spacer(minLength: 4)
                            Text(state.text).font(.caption.weight(.medium))
                                .foregroundStyle(state.open ? Color.secondaryText : PRTone.ok.color)
                        }
                        Text(entry.finding.text).font(.footnote)
                        if !entry.finding.path.isEmpty {
                            Text(entry.finding.line > 0 ? "\(entry.finding.path):\(entry.finding.line)" : entry.finding.path)
                                .font(.caption.monospaced()).foregroundStyle(Color.secondaryText)
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            } header: {
                SectionTitle("Findings", count: all.count)
            }
        }
    }

    @ViewBuilder private func checks(_ pr: PullRequest) -> some View {
        if !pr.checks.isEmpty {
            Section {
                ForEach(Array(pr.checks.enumerated()), id: \.offset) { _, check in
                    let state = PRWords.check(check)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(check.name).font(.subheadline.monospaced()).lineLimit(1)
                            if !check.required { Text("optional").font(.caption).foregroundStyle(Color.secondaryText) }
                            Spacer(minLength: 4)
                            Text(state.text).font(.footnote.weight(.medium)).foregroundStyle(state.tone.color)
                        }
                        let detail = [check.ranOn.isEmpty ? nil : "on \(check.ranOn)", check.note.isEmpty ? nil : check.note]
                            .compactMap { $0 }.joined(separator: " · ")
                        if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(Color.secondaryText).lineLimit(2) }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                SectionTitle("Checks")
            }
        }
    }

    /// Approve and Request changes while open; Undo while it merges.
    @ViewBuilder private func actions(_ pr: PullRequest, model: PRReviewModel) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Group {
                if pr.state == .merging, model.canUndo(now: context.date) {
                    Button { Task { await model.undo() } } label: {
                        AskButtonLabel(text: model.busy ? "Undoing…" : "Undo · \(model.secondsLeft(now: context.date)) s", wide: true)
                    }
                    .disabled(model.busy)
                    .accessibilityIdentifier("pr-undo")
                } else if pr.state == .open {
                    VStack(alignment: .leading, spacing: 6) {
                        if PRWords.youApproved(pr) {
                            Text("✓ You approved \(PRWords.sha7(pr.headSha))").font(.footnote.weight(.medium)).foregroundStyle(PRTone.ok.color)
                        }
                        HStack(spacing: 10) {
                            if !PRWords.youApproved(pr) {
                                Button { Task { await model.approve() } } label: {
                                    AskButtonLabel(text: model.busy ? "Sending…" : "Approve", primary: true, enabled: model.canReview, wide: true)
                                }
                                .disabled(!model.canReview)
                                .accessibilityIdentifier("pr-approve")
                            }
                            Button { noting = true } label: {
                                AskButtonLabel(text: "Request changes", enabled: model.canReview, wide: true)
                            }
                            .disabled(!model.canReview)
                            .accessibilityIdentifier("pr-request-changes")
                        }
                        Text("On \(PRWords.sha7(pr.headSha)), the head as it is now.").font(.caption).foregroundStyle(Color.secondaryText)
                    }
                }
            }
            .buttonStyle(GlanceButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// Request changes: the note the author gets, required.
private struct PRChangesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var note: String
    let send: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Note", text: $note, prompt: .placeholder("What should change"), axis: .vertical)
                        .lineLimit(3...10)
                        .focused($focused)
                        .accessibilityIdentifier("pr-changes-note")
                } footer: {
                    Text("The PR’s author is asked to make the changes, and its card goes back to Doing.")
                        .foregroundStyle(Color.secondaryText)
                }
            }
            .navigationTitle("Request changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send() }
                        .disabled(note.trimmed.isEmpty)
                        .accessibilityIdentifier("pr-changes-send")
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}
