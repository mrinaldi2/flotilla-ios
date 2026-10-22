import SwiftUI

/// A card in full: description, criteria, attachments and comments; the
/// owner can comment. A draft (0.19) shows its discussion, its changes and
/// Finalize or Discard instead of comments.
struct ItemView: View {
    @Environment(Fleet.self) private var fleet
    @Environment(AppStore.self) private var store
    let itemId: String
    /// A comment to answer at once: "Reply to <bot>" opens on it (H-248).
    var answering: String? = nil
    /// The project, when the screen that opened it knows; else found by the id's prefix.
    var projectId: String? = nil
    @State private var openedReply = false
    @State private var detail: BoardItemDetail?
    @State private var draft = ""
    /// What this device posted (H-202): shown at once, then confirmed or failed.
    @State private var pending: [PendingComment] = []
    @State private var replyTo: CommentRow?
    @State private var replying: CommentRow?
    @State private var failure: String?
    @FocusState private var composing: Bool
    /// A draft's review, its board (for the column to finalize into) and the
    /// bot whose chat is open about it.
    @State private var draftModel: DraftModel?
    /// Who the draft is discussed with (`invited`), and the invite or removal in flight.
    @State private var discussion: DiscussionModel?
    @State private var board: BoardState?
    @State private var chatting: String?
    /// Following the draft's project for its pushes, since which reconnect.
    @State private var following: (project: String, token: UUID, reconnects: Int)?
    /// "Move to…" from the card itself, with its board's columns.
    @State private var moving: MoveTarget?
    @State private var moveFailure: String?
    @State private var assignFailure: String?
    /// The home holds the card in Research (0.21, `start.research`): its next move waits for code research.
    @State private var researchBlock: BoardUnmet?
    /// The Design cards this task builds (`LINK_KIND_DESIGN`).
    @State private var designs: [BoardItemDetail] = []
    /// The plan node the card belongs to: "Feature: Hitstop on heavy hits".
    @State private var planNode: PlanNode?
    /// The card's questions for the owner (0.22, `questions_v1`), kept live while on screen.
    @State private var questions: QuestionsModel?

    /// The home keeps a "Code research" section on tasks and bugs (0.21).
    private func codeResearch(_ item: Flotilla_Board_V1_Item) -> String? {
        guard store.hasResearchColumn else { return nil }
        if let section = CodeResearch.section(in: item.description_p) { return section }
        return CodeResearch.applies(to: item.type) ? "" : nil
    }

    private struct MoveTarget: Identifiable {
        let card: BoardCard
        let columns: [BoardColumnRow]
        var id: String { card.id }
    }

    private var project: String? { projectId ?? fleet.cards.home(for: itemId)?.projectId }

    /// Who an owner comment reaches (H-201): the card's assignee and the project's lead.
    private var told: [String] {
        var names: [String] = []
        if let assignee = detail?.item, assignee.hasAssignee, let name = store.bot(assignee.assignee)?.name { names.append(name) }
        if let lead = store.projects.first(where: { $0.id == project })?.leadBotId,
           let name = store.bot(lead)?.name, !names.contains(name) {
            names.append(name)
        }
        return names
    }

    private var groups: [CommentGroup] {
        CommentThread.grouped(CommentThread.rows(comments: detail?.comments ?? [], history: detail?.history ?? [],
                                                 pending: pending))
    }

    var body: some View {
        List {
            if let detail {
                let item = detail.item
                let live = item.state != "draft" && item.state != "discarded"
                if !live {
                    DraftBanner(item: item, boardName: (board?.boards.count ?? 0) > 1 ? board?.board?.name : nil)
                }
                Section {
                    Text(item.title).font(.headline)
                    // Where the card stands (UX-037): "Doing · Desktop Dev", flags.
                    let facts = CardPreview.of(item) { store.bot($0)?.name }
                    if live, let place = facts.placeLine { Text(place).font(.subheadline) }
                    if !live, item.hasAssignee { Text("Assignee: \(store.bot(item.assignee)?.name ?? "a bot")").font(.subheadline) }
                    if let flags = facts.flagsLine { Text(flags).font(.subheadline).foregroundStyle(Color.warningText) }
                    if let planNode {
                        PlanNodeChip(node: planNode, showsKind: true).accessibilityIdentifier("item-plan-node")
                    }
                    // Every label in full (`platform:ios`); a 0.18 home's platforms as `platform:` labels.
                    if !item.allLabels.isEmpty {
                        Text("Labels: \(item.allLabels.joined(separator: ", "))").font(.subheadline).foregroundStyle(Color.secondaryText)
                            .accessibilityIdentifier("item-labels")
                    }
                    // Code research has its own section below, so it shows once.
                    let full = codeResearch(item) == nil ? item.description_p : CodeResearch.removing(from: item.description_p)
                    let description = store.hasItemTypesV2 ? TemplateSections.droppingEmpty(full) : full
                    if !description.isEmpty {
                        LinkedText(markdown: AttachmentText.inline(description, attachments: detail.attachments))
                    }
                } header: {
                    // The id is the navigation title; the header says what kind of card it is.
                    if let kind = CardPreview.of(item, botName: { _ in nil }).kindLine { SectionTitle(kind) }
                }
                if live, let researchBlock {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Can’t start yet").font(.headline).foregroundStyle(Color.warningText)
                            Text("Waiting for the bot’s code research findings.").font(.subheadline)
                            Text(MoveOutcome.lines([researchBlock]).joined(separator: " "))
                                .font(.footnote).foregroundStyle(Color.secondaryText)
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("item-research-block")
                    }
                }
                if let research = codeResearch(item) {
                    Section {
                        if research.isEmpty {
                            Text("Not written yet.").foregroundStyle(Color.secondaryText)
                        } else {
                            LinkedText(markdown: research)
                        }
                    } header: {
                        SectionTitle(CodeResearch.heading)
                    }
                    .accessibilityIdentifier("item-code-research")
                }
                if !designs.isEmpty {
                    Section {
                        ForEach(designs, id: \.item.id) { design in
                            NavigationLink { DesignDocsView(detail: design, projectId: project) } label: {
                                ItemRow(title: design.item.title, subtitle: DesignWords.line(design.attachments)) {
                                    IconTile(systemImage: "paintbrush.pointed", tone: .working)
                                }
                            }
                            .accessibilityIdentifier("item-design-\(design.item.id)")
                        }
                    } header: {
                        SectionTitle("Design")
                    }
                }
                if !item.acceptanceCriteria.isEmpty {
                    Section {
                        ForEach(item.acceptanceCriteria, id: \.idx) { criterion in
                            Label(criterion.text, systemImage: criterion.checked ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(criterion.checked ? Color.successText : Color.primary)
                        }
                    } header: {
                        SectionTitle("Acceptance criteria")
                    }
                }
                AttachmentsSection(attachments: detail.attachments, projectId: project)
                if item.state == "draft", let draftModel, let discussion {
                    DraftSections(detail: detail, projectId: project, board: board, model: draftModel,
                                  discussion: discussion, chatting: $chatting) { await load() }
                }
                if let questions { QuestionsSection(model: questions) }
                // A push or a command a bot asks the owner to run for this card (0.24.0).
                if live, store.hasOwnerActions { CardOwnerActions(projectId: project ?? "", itemId: itemId) }
                if live {
                    Section {
                        if groups.isEmpty { EmptyNote(text: "No comments yet", systemImage: "text.bubble") }
                        ForEach(groups) { group in
                            commentRow(group.comment, reply: false)
                            ForEach(group.replies) { commentRow($0, reply: true) }
                        }
                        if store.canControl { composer }
                    } header: {
                        SectionTitle("Comments")
                    }
                }
            } else if let failure {
                Text(failure).foregroundStyle(Color.errorText)
            } else {
                ProgressView()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(itemId)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .reloadsOnReconnect { await load() }
        .onDisappear {
            stopFollowing()
            // Back on screen, the card is read again and its questions followed anew.
            questions?.stop()
            questions = nil
        }
        .toolbar {
            if let item = detail?.item, item.state.isEmpty || item.state == "live", store.canControl, store.speaksProto, project != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Move to…") { openMove(item) }
                        .accessibilityIdentifier("item-move")
                }
                if let project {
                    ToolbarItem(placement: .topBarTrailing) {
                        AssignMenu(itemId: item.id, version: item.version, assignee: item.hasAssignee ? item.assignee : nil,
                                   projectId: project, roles: board?.snapshot.roles) { assignFailure = $0 } assigned: {
                            Task { await load() }
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("item-assign")
                    }
                }
            }
        }
        .sheet(item: $moving, onDismiss: { Task { await load() } }) { target in
            MoveSheet(model: MoveModel(card: target.card, service: store), columns: target.columns)
        }
        .errorAlert("Couldn’t check the columns.", $moveFailure)
        .errorAlert("Couldn’t assign the card.", $assignFailure)
        .navigationDestination(item: $chatting) { botId in
            DraftChatView(botId: botId, itemId: itemId, title: detail?.item.title ?? "", discussion: discussion, projectId: project)
        }
        .sheet(item: $replying) { row in
            ReplySheet(to: CommentWords.author(row.author) { store.bot($0)?.name }, quote: row.body ?? "") { body in
                replying = nil
                post(body, replyTo: row.id)
            }
        }
    }

    /// The card's board, then the Move sheet on it.
    private func openMove(_ item: Flotilla_Board_V1_Item) {
        guard let project else { return }
        Task {
            do {
                let state = BoardState(snapshot: try await store.board(projectId: project), remembered: item.boardID)
                var card = BoardCard()
                card.id = item.id
                card.title = item.title
                card.columnKey = item.columnKey
                card.version = item.version
                card.boardID = item.boardID
                moving = MoveTarget(card: card, columns: state.allColumns)
            } catch {
                moveFailure = error.localizedDescription
            }
        }
    }

    /// A draft refreshes as its bot edits it: its project's pushes, while on screen.
    private func followDraft(_ fresh: BoardItemDetail) async {
        if draftModel == nil { draftModel = DraftModel(itemId: itemId, service: store) }
        if discussion == nil { discussion = DiscussionModel(itemId: itemId, service: store) }
        discussion?.take(fresh)
        await draftModel?.load()
        guard let project, following?.reconnects != store.reconnects else { return }
        let token = following?.token ?? store.listen(projectId: project) { event in
            guard event.itemID == itemId else { return }
            // Another device's removal shows at once from a home whose cards carry `invited`.
            discussion?.take(card: event.card)
            Task { await load() }
        }
        following = (project, token, store.reconnects)
        if let snapshot = try? await store.watchBoard(projectId: project) {
            board = BoardState(snapshot: snapshot, remembered: fresh.item.boardID)
            discussion?.take(drafts: snapshot.drafts)
        }
    }

    private func stopFollowing() {
        guard let following else { return }
        store.stopListening(projectId: following.project, following.token)
        self.following = nil
    }

    @ViewBuilder private func commentRow(_ row: CommentRow, reply: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if reply { Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(Color.secondaryText) }
                Text(author(row.author)).font(.caption.weight(.semibold))
                if let at = row.at { Text(at.relative).font(.caption2).foregroundStyle(Color.secondaryText) }
                Spacer(minLength: 4)
                statusLabel(row)
            }
            Group {
                if let body = row.body {
                    LinkedText(markdown: body)
                } else {
                    Text("A comment. Its text shows once the Flotilla service on \(store.computerName.isEmpty ? "your computer" : store.computerName) is updated.")
                        .foregroundStyle(Color.secondaryText)
                }
            }
            .font(.callout)
            .textSelection(.enabled)
            if row.status == .sent {
                // Who the comment reached (UX-041): the assignee and the lead.
                Text(CommentWords.posted(told: told)).font(.caption).foregroundStyle(Color.successText)
            }
            if case .failed(let message) = row.status {
                HStack(spacing: 12) {
                    Text(CommentWords.couldntPost(message)).font(.caption).foregroundStyle(Color.errorText)
                    if let id = row.pendingId {
                        // Caption-sized words, 44 pt targets.
                        Button("Retry") { retry(id) }.font(.caption.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                        Button("Discard", role: .destructive) { pending.removeAll { $0.id == id } }.font(.caption)
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                }
                .buttonStyle(.borderless)
            } else if row.status == .onBoard, store.canControl, !reply {
                // A sheet with the comment and a focused field (H-210): the inline
                // composer sits at the end of the list, often off screen.
                Button("Reply") { replying = row }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
            }
        }
        .padding(.leading, reply ? 16 : 0)
        .padding(.vertical, 2)
    }

    @ViewBuilder private func statusLabel(_ row: CommentRow) -> some View {
        switch row.status {
        case .onBoard: EmptyView()
        case .sending:
            Label("Sending…", systemImage: "clock").font(.caption2).foregroundStyle(Color.secondaryText)
        case .sent:
            // The line under the comment says it: "✓ Posted. … are told."
            EmptyView()
        case .failed:
            Label("Couldn’t post", systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(Color.errorText)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let replyTo {
                HStack {
                    Text(CommentWords.replying(to: replyTo.author) { author($0) }).font(.caption).foregroundStyle(Color.secondaryText)
                    Button("Cancel") { self.replyTo = nil }.font(.caption).buttonStyle(.borderless)
                }
            }
            HStack(alignment: .bottom) {
                TextField("Comment", text: $draft, prompt: .placeholder(replyTo == nil ? "Comment on \(itemId)" : "Reply"), axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composing)
                Button("Send") { post() }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderless)
            }
        }
    }

    private func author(_ actor: String) -> String {
        CommentWords.author(actor) { store.bot($0)?.name }
    }

    private func load() async {
        do {
            let fresh = try await store.item(itemId)
            detail = fresh
            pending = CommentThread.stillPending(pending, comments: fresh.comments)
            failure = nil
            if fresh.item.state == "draft" { await followDraft(fresh) }
            await loadQuestions(fresh)
            await loadPlanParts(fresh)
            if let answering, !openedReply,
               let row = CommentThread.rows(comments: fresh.comments, history: fresh.history, pending: []).first(where: { $0.id == answering }) {
                openedReply = true
                replying = row
            }
        } catch {
            if detail == nil { failure = error.localizedDescription }
        }
    }

    /// The card's questions, open first, from its detail; then followed so
    /// an answer from another device or a new question shows at once.
    private func loadQuestions(_ fresh: BoardItemDetail) async {
        guard store.hasQuestions, let project else { return }
        let model = questions ?? QuestionsModel(projectId: project, scope: .item(itemId), service: store)
        model.seed(fresh.questions)
        if questions == nil {
            questions = model
            await model.start()
        }
    }

    /// The 0.21 parts, each on a home that serves it: the Research hold, the
    /// attached designs and the plan node.
    private func loadPlanParts(_ fresh: BoardItemDetail) async {
        let item = fresh.item
        let live = item.state.isEmpty || item.state == "live"
        if store.hasResearchColumn, live, CodeResearch.applies(to: item.type), store.speaksProto,
           let check = try? await store.moveCheck(itemId: item.id) {
            researchBlock = CodeResearch.blocks(check)
        } else {
            researchBlock = nil
        }
        if store.hasResearchColumn {
            var found: [BoardItemDetail] = []
            for id in fresh.designIds { if let design = try? await store.item(id) { found.append(design) } }
            designs = found
        }
        if store.hasPlan, item.hasPlanNodeID, !item.planNodeID.isEmpty {
            planNode = try? await store.planNode(item.planNodeID).node
        }
    }

    /// Shows the comment at once, then sends it.
    private func post() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        draft = ""
        let to = replyTo?.status == .onBoard ? replyTo?.id : nil
        replyTo = nil
        post(body, replyTo: to)
    }

    private func post(_ body: String, replyTo: String?) {
        let comment = PendingComment(body: body, replyTo: replyTo)
        pending.append(comment)
        send(comment.id)
    }

    private func retry(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].state = .sending
        send(id, retrying: true)
    }

    /// A retry re-reads the card first: the comment may have landed after all (H-225).
    private func send(_ id: UUID, retrying: Bool = false) {
        guard let comment = pending.first(where: { $0.id == id }) else { return }
        Task {
            do {
                if retrying {
                    _ = try await CommentThread.retry(comment, reread: {
                        let fresh = try await store.item(itemId)
                        detail = fresh
                        return fresh.comments
                    }, post: {
                        try await store.postComment(on: itemId, comment.body, replyTo: comment.replyTo)
                    })
                } else {
                    try await store.postComment(on: itemId, comment.body, replyTo: comment.replyTo)
                }
                if let index = pending.firstIndex(where: { $0.id == id }) {
                    pending[index].state = .sent
                    pending[index].sentAt = Date()
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await load()
                // The bot's question on this card closes with your comment: Needs you follows.
                await fleet.home.refreshAll(fleet.computers, force: true)
                // "✓ Posted" shows on the board's copy, then goes (QA-006).
                try? await Task.sleep(for: .seconds(CommentThread.postedFor))
                pending = CommentThread.stillPending(pending, comments: detail?.comments ?? [])
            } catch {
                if let index = pending.firstIndex(where: { $0.id == id }) {
                    pending[index].state = .failed(error.localizedDescription)
                }
            }
        }
    }
}

/// A Design card a task builds (0.21): its documents and mockups, read in place.
struct DesignDocsView: View {
    let detail: BoardItemDetail
    let projectId: String?

    var body: some View {
        List {
            Section {
                Text(detail.item.title).font(.headline)
                Text("Design · \(Release.PlanItem.column(detail.item.columnKey))").font(.subheadline).foregroundStyle(Color.secondaryText)
            }
            if detail.attachments.allSatisfy(\.removed) {
                Section { EmptyNote(text: "No documents on this design yet", systemImage: "doc") }
            }
            AttachmentsSection(attachments: detail.attachments, projectId: projectId)
            Section {
                NavigationLink("Open \(detail.item.id)") { ItemView(itemId: detail.item.id, projectId: projectId) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(detail.item.id)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// "Reply to Desktop Dev": the comment you answer, and a field ready to type (H-210).
struct ReplySheet: View {
    @Environment(\.dismiss) private var dismiss
    let to: String
    let quote: String
    let send: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if !quote.isEmpty {
                    Section(to) {
                        Text(quote).font(.callout).foregroundStyle(Color.secondaryText).lineLimit(6)
                    }
                }
                Section {
                    TextField("Your reply", text: $text, prompt: .placeholder("Your reply"), axis: .vertical)
                        .lineLimit(3...10)
                        .focused($focused)
                }
            }
            .navigationTitle(CommentWords.replyTitle(to))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}
