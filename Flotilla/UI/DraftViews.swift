import SwiftUI

// A draft on the phone (K4b, K7): not on the board yet, discussed with a bot
// in that bot's chat, reviewed change by change, then finalized into a
// column or discarded. Only the owner finalizes or discards, from a paired
// device; the daemon refuses the owner token.

/// "✎ Draft · not on the board yet", or a discarded draft's note.
struct DraftBanner: View {
    let item: Hermes_Board_V1_Item
    var boardName: String?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                if item.state == "discarded" {
                    Label("⊘ Discarded draft", systemImage: "archivebox").font(.subheadline.weight(.semibold))
                    Text("It left the drafts and keeps its history.").font(.footnote).foregroundStyle(Color.secondaryText)
                } else {
                    Label("✎ Draft · not on the board yet", systemImage: "square.and.pencil").font(.subheadline.weight(.semibold))
                    Text("Only you and the bots you invite see it.").font(.footnote).foregroundStyle(Color.secondaryText)
                }
                if let boardName { Text("Board: \(boardName)").font(.footnote).foregroundStyle(Color.secondaryText) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("draft-banner")
        }
    }
}

/// Under a draft's description: Discuss with a bot, who it is discussed
/// with (each with its Remove), the changes since you looked, and Finalize
/// or Discard.
struct DraftSections: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    let detail: BoardItemDetail
    let projectId: String?
    /// The draft's board, for the column to finalize into; nil when unknown.
    let board: BoardState?
    @Bindable var model: DraftModel
    let discussion: DiscussionModel
    @Binding var chatting: String?
    let reload: () async -> Void
    @State private var column = ""
    @State private var discarding = false
    @State private var reason = ""
    @State private var busy = false
    @State private var refusal: [String] = []
    /// The bot whose Remove asks first ("Remove Team Lead from RB-20?").
    @State private var removing: String?

    private var item: Hermes_Board_V1_Item { detail.item }

    /// The project's bots, the lead first; workers left out.
    private var bots: [Bot] {
        let lead = store.projects.first { $0.id == projectId }?.leadBotId
        let mine = store.bots.filter { !$0.temporary && $0.deletedAt == nil && (projectId == nil || $0.projectId == projectId) }
        return mine.sorted { a, b in
            if (a.id == lead) != (b.id == lead) { return a.id == lead }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private var leadId: String? { store.projects.first { $0.id == projectId }?.leadBotId }

    private func name(_ botId: String) -> String { DiscussionWords.name(botId) { store.bot($0)?.name } }

    var body: some View {
        Group {
            discuss
            discussingWith
            review
            if store.canControl { finalize }
        }
        .disabled(busy)
        .alert("Discard \(item.id)?", isPresented: $discarding) {
            TextField("Reason", text: $reason)
            Button("Discard", role: .destructive) { discard() }
            Button("Cancel", role: .cancel) { reason = "" }
        } message: {
            Text("It leaves the drafts and keeps its history. Say why, for the bots that discussed it.")
        }
        .alert(DiscussionWords.removeTitle(removing.map(name) ?? "the bot", from: item.id), isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), presenting: removing) { botId in
            Button("Keep", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) { remove(botId) }
        } message: { botId in
            Text(DiscussionWords.removeMessage(name(botId)))
        }
    }

    // MARK: Discuss

    @ViewBuilder private var discuss: some View {
        Section {
            if store.canControl {
                Menu {
                    ForEach(bots) { bot in
                        Button(bot.id == leadId ? "\(bot.name) (lead)" : bot.name) { discuss(with: bot.id) }
                    }
                } label: {
                    HStack {
                        Label("Discuss with a bot", systemImage: "bubble.left.and.text.bubble.right")
                        if discussion.inviting != nil {
                            Spacer(minLength: 8)
                            ProgressView().accessibilityLabel("Waiting for the Flotilla service")
                        }
                    }
                }
                .disabled(bots.isEmpty || discussion.isBusy)
                .accessibilityIdentifier("draft-discuss")
            } else if discussion.invited.isEmpty {
                Text("No bot is discussing it.").foregroundStyle(Color.secondaryText)
            }
            if let failure = discussion.failure {
                Label(failure.capitalizedFirst, systemImage: "xmark.octagon").font(.footnote).foregroundStyle(Color.errorText)
                    .accessibilityIdentifier("draft-discuss-failure")
            }
        } header: {
            SectionTitle("Discussion")
        } footer: {
            Text(discussion.invited.isEmpty
                 ? "A bot you invite is sent the draft and its files, and can edit it while you talk in its chat."
                 : "Picking a bot again sends it the draft again.")
                .foregroundStyle(Color.secondaryText)
        }
    }

    /// "Discussing with": each invited bot opens its chat, with a Remove that asks first.
    @ViewBuilder private var discussingWith: some View {
        if !discussion.invited.isEmpty {
            Section {
                ForEach(discussion.invited, id: \.self) { botId in
                    invitee(botId)
                }
            } header: {
                SectionTitle("Discussing with")
            } footer: {
                if store.canControl {
                    Text("Removing a bot ends its discussion: it is told, and can no longer see or change the draft.")
                        .foregroundStyle(Color.secondaryText)
                }
            }
        }
    }

    private func invitee(_ botId: String) -> some View {
        let name = name(botId)
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout())
        return layout {
            Button { chatting = botId } label: {
                Label(name, systemImage: "bubble.left.and.bubble.right")
            }
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
            .accessibilityHint("Opens the chat with \(name) about the draft")
            .accessibilityIdentifier("draft-invitee-\(botId)")
            if store.canControl {
                if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                if discussion.removing == botId {
                    ProgressView().frame(minWidth: 44, minHeight: 44).accessibilityLabel("Removing \(name)")
                } else {
                    Button("Remove") { removing = botId }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.errorText)
                        .buttonStyle(.borderless)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .disabled(discussion.isBusy)
                        .accessibilityLabel(DiscussionWords.removeLabel(name))
                        .accessibilityIdentifier("draft-remove-\(botId)")
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if store.canControl {
                Button("Remove") { removing = botId }
                    .tint(.red)
                    .disabled(discussion.isBusy)
            }
        }
    }

    /// Always `item_invite`, so the bot is sent the draft again; the chat
    /// opens once the daemon answers. A second tap meanwhile sends nothing.
    private func discuss(with botId: String) {
        guard !discussion.isBusy else { return }
        Task {
            if await discussion.discuss(with: botId) {
                chatting = botId
                await reload()
            }
        }
    }

    /// `item_invite{remove: true}`; the bot's chat closes.
    private func remove(_ botId: String) {
        removing = nil
        guard !discussion.isBusy else { return }
        Task {
            if await discussion.remove(botId) {
                if chatting == botId { chatting = nil }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await reload()
            }
        }
    }

    // MARK: Review

    @ViewBuilder private var review: some View {
        Section {
            let line = DraftWords.unseenLine(model.revisions, seen: model.seen) { store.bot($0)?.name }
            NavigationLink {
                DraftChangesView(itemId: item.id, model: model)
            } label: {
                if let line {
                    Label(line, systemImage: "sparkles").foregroundStyle(Color.primary)
                } else {
                    Label(model.revisions.isEmpty ? "No changes yet" : "All changes (\(model.revisions.count))", systemImage: "clock.arrow.circlepath")
                }
            }
            .disabled(model.revisions.isEmpty)
            .accessibilityIdentifier("draft-review")
            if let failure = model.failure {
                Text(failure).font(.footnote).foregroundStyle(Color.errorText)
            }
        } header: {
            SectionTitle("Changes")
        }
    }

    // MARK: Finalize and discard

    private var columns: [BoardColumnRow] {
        (board?.allColumns ?? []).filter { $0.visible && ![.done, .cancelled].contains($0.effectiveKind) }
    }

    @ViewBuilder private var finalize: some View {
        Section {
            if columns.isEmpty {
                Text("It goes to the board’s first open column.").font(.footnote).foregroundStyle(Color.secondaryText)
            } else {
                Picker("Column", selection: $column) {
                    ForEach(columns, id: \.key) { column in
                        Text("\(column.name) · \(ColumnKindWords.chip(column.effectiveKind))").tag(column.key)
                    }
                }
            }
            Button { finalizeNow() } label: { Label("Finalize", systemImage: "checkmark.circle") }
                .fontWeight(.semibold)
                .accessibilityIdentifier("draft-finalize")
            ForEach(refusal, id: \.self) { line in
                Label(line, systemImage: "xmark.octagon").font(.footnote).foregroundStyle(Color.errorText)
            }
            Button(role: .destructive) { discarding = true } label: { Label("Discard…", systemImage: "trash") }
        } header: {
            SectionTitle("Put it on the board")
        } footer: {
            Text("The column’s entry rules apply as for any new item. Finalizing marks the changes seen.")
                .foregroundStyle(Color.secondaryText)
        }
        .onAppear {
            if column.isEmpty { column = board?.firstOpenColumn?.key ?? columns.first?.key ?? "" }
        }
        .onChange(of: board?.firstOpenColumn?.key) { _, key in
            if column.isEmpty, let key { column = key }
        }
    }

    private func finalizeNow() {
        busy = true
        refusal = []
        Task {
            defer { busy = false }
            switch await model.finalize(version: item.version, column: column.isEmpty ? nil : column) {
            case .done?:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .refused(let unmet)?:
                refusal = MoveOutcome.lines(unmet)
            case .conflict?:
                refusal = ["\(item.id) changed meanwhile. Look again, then finalize."]
            case nil:
                // The daemon's refusal, said where Finalize is.
                refusal = [model.failure?.capitalizedFirst ?? "Not finalized."]
                model.failure = nil
            }
            await reload()
        }
    }

    private func discard() {
        let why = reason
        reason = ""
        busy = true
        Task {
            defer { busy = false }
            if await model.discard(version: item.version, reason: why) {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                refusal = [model.failure?.capitalizedFirst ?? "Not discarded."]
                model.failure = nil
            }
            await reload()
        }
    }
}

/// Every change to a draft, newest first, with who made it and its own
/// Undo (`item_draft_undo`, as the desktop's review). Opening it marks the
/// bots' changes seen. Undoing is the owner's: the home takes it from a
/// paired device and says so otherwise.
struct DraftChangesView: View {
    @Environment(AppStore.self) private var store
    let itemId: String
    @Bindable var model: DraftModel
    @State private var detail: BoardItemDetail?
    @State private var undoing: Int64?
    @State private var failure: String?

    var body: some View {
        List {
            Section {
                if model.revisions.isEmpty { EmptyNote(text: "No changes yet", systemImage: "clock.arrow.circlepath") }
                ForEach(model.newestFirst, id: \.id) { revision in
                    row(revision)
                }
            } footer: {
                Text("Undo takes one change back: a field returns to what it was, an attachment or link it added goes, one it removed comes back. The undo is a change of yours.")
                    .foregroundStyle(Color.secondaryText)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Changes to \(itemId)")
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert("Couldn’t undo the change.", $failure)
        .task {
            detail = try? await store.item(itemId)
            await model.load()
            await model.markSeen()
        }
    }

    private func row(_ revision: DraftRevision) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(DraftWords.author(revision.actor) { store.bot($0)?.name }).font(.caption.weight(.semibold))
                if revision.hasAt { Text(revision.at.date.relative).font(.caption2).foregroundStyle(Color.secondaryText) }
                if model.isNew(revision) { Pill(text: "● New", tone: .working) }
                Spacer(minLength: 4)
                if model.undone.contains(revision.id) {
                    Text("↶ Undone").font(.caption.weight(.semibold)).foregroundStyle(Color.secondaryText)
                } else if store.canControl, detail?.item.state == "draft" {
                    if undoing == revision.id {
                        ProgressView()
                    } else {
                        Button("Undo") { run(revision) }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.borderless)
                            .frame(minWidth: 44, minHeight: 44)
                            .disabled(undoing != nil)
                            .accessibilityLabel("Undo: \(DraftWords.change(revision))")
                    }
                }
            }
            Text(DraftWords.change(revision)).font(.callout)
            if revision.field == "description" || revision.field == "acceptance_criteria", revision.hasTo, !revision.to.isEmpty {
                Text(revision.to).font(.footnote).foregroundStyle(Color.secondaryText).lineLimit(6)
            }
        }
        .padding(.vertical, 2)
    }

    private func run(_ revision: DraftRevision) {
        guard let detail else { return }
        undoing = revision.id
        Task {
            defer { undoing = nil }
            do {
                try await model.undo(revision, version: detail.item.version)
            } catch {
                failure = error.localizedDescription
            }
            // The version moved on, or someone else's did: read it again either way.
            self.detail = try? await store.item(itemId)
        }
    }
}

/// "Discuss with a bot": the bot's own chat, pinned to the draft. Every
/// message goes with the draft's id, so the bot reads it with the draft.
/// Removed from the discussion on another device meanwhile, the chat stays
/// (what was said stays in it) but unpins: messages go without the draft.
struct DraftChatView: View {
    @Environment(AppStore.self) private var store
    let botId: String
    let itemId: String
    let title: String
    /// Who is discussing the draft, followed while the chat is open; nil
    /// when the screen that opened the chat doesn't know.
    var discussion: DiscussionModel? = nil
    var projectId: String? = nil
    @State private var searching = false
    @State private var following: UUID?

    private var pinned: Bool { discussion?.invited.contains(botId) ?? true }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: pinned ? "pin.fill" : "pin.slash").foregroundStyle(Color.secondaryText).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pinned ? "✎ Draft · \(itemId)" : DiscussionWords.ended(itemId))
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.secondaryText)
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemGroupedBackground))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(pinned
                                ? "Pinned: draft \(itemId), \(title). Every message goes with it."
                                : "\(DiscussionWords.ended(itemId)), \(title). Messages go without the draft.")
            .accessibilityIdentifier(pinned ? "draft-chat-pin" : "draft-chat-unpinned")
            Divider()
            if store.hasChat {
                BotChatPane(botId: botId, searching: $searching, itemId: pinned ? itemId : nil)
            } else {
                ContentUnavailableView("Chat needs an update", systemImage: "arrow.up.circle",
                                       description: Text("Update Flotilla on \(store.computerName) to discuss the draft here."))
            }
        }
        .navigationTitle(store.bot(botId)?.name ?? "Bot")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task { await follow() }
        .reloadsOnReconnect { await follow() }
        .onDisappear { stopFollowing() }
    }

    /// The draft's pushes while the chat is open: a removal made elsewhere unpins it.
    private func follow() async {
        guard let discussion, let projectId else { return }
        if following == nil {
            following = store.listen(projectId: projectId) { event in
                guard event.itemID == itemId else { return }
                discussion.take(card: event.card)
                Task { await discussion.refresh() }
            }
        }
        _ = try? await store.watchBoard(projectId: projectId)
        await discussion.refresh()
    }

    private func stopFollowing() {
        guard let following, let projectId else { return }
        store.stopListening(projectId: projectId, following)
        self.following = nil
    }
}
