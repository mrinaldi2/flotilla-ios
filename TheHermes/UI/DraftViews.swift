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

/// Under a draft's description: Discuss with a bot, the changes since you
/// looked, and Finalize or Discard.
struct DraftSections: View {
    @Environment(AppStore.self) private var store
    let detail: BoardItemDetail
    let projectId: String?
    /// The draft's board, for the column to finalize into; nil when unknown.
    let board: BoardState?
    @Bindable var model: DraftModel
    @Binding var chatting: String?
    let reload: () async -> Void
    @State private var column = ""
    @State private var discarding = false
    @State private var reason = ""
    @State private var busy = false
    @State private var refusal: [String] = []

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

    var body: some View {
        Group {
            discuss
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
    }

    // MARK: Discuss

    @ViewBuilder private var discuss: some View {
        Section {
            ForEach(detail.invited, id: \.self) { id in
                Button { chatting = id } label: {
                    Label("Open the chat with \(store.bot(id)?.name ?? "the bot")", systemImage: "bubble.left.and.bubble.right")
                }
            }
            if store.canControl {
                Menu {
                    ForEach(bots) { bot in
                        Button(bot.id == leadId ? "\(bot.name) (lead)" : bot.name) { discuss(with: bot.id) }
                    }
                } label: {
                    Label("Discuss with a bot", systemImage: "bubble.left.and.text.bubble.right")
                }
                .disabled(bots.isEmpty)
                .accessibilityIdentifier("draft-discuss")
            }
        } header: {
            SectionTitle("Discussion")
        } footer: {
            Text(detail.invited.isEmpty
                 ? "A bot you invite reads the draft and its files, and can edit it while you talk in its chat."
                 : "Discussing with \(ListFormatter.localizedString(byJoining: detail.invited.map { store.bot($0)?.name ?? "a bot" })).")
                .foregroundStyle(Color.secondaryText)
        }
    }

    private func discuss(with botId: String) {
        if detail.invited.contains(botId) {
            chatting = botId
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await store.invite(itemId: item.id, botId: botId)
                await reload()
                chatting = botId
            } catch {
                model.failure = error.localizedDescription
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

/// Every change to a draft, newest first, with who made it and an Undo for
/// each one that can be put back. Opening it marks the bots' changes seen.
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
                Text("Undo puts one change back. A field changed again since needs its later change undone first.")
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
        let undo = detail.flatMap { DraftUndo.of(revision, among: model.revisions, detail: $0) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(DraftWords.author(revision.actor) { store.bot($0)?.name }).font(.caption.weight(.semibold))
                if revision.hasAt { Text(revision.at.date.relative).font(.caption2).foregroundStyle(Color.secondaryText) }
                if model.isNew(revision) { Pill(text: "● New", tone: .working) }
                Spacer(minLength: 4)
                if let undo {
                    if undoing == revision.id {
                        ProgressView()
                    } else {
                        Button("Undo") { run(revision, undo) }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.borderless)
                            .frame(minWidth: 44, minHeight: 44)
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

    private func run(_ revision: DraftRevision, _ undo: DraftUndo) {
        guard let detail else { return }
        undoing = revision.id
        Task {
            defer { undoing = nil }
            do {
                try await model.undo(revision, detail: detail)
                self.detail = try? await store.item(itemId)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// "Discuss with a bot": the bot's own chat, pinned to the draft. Every
/// message goes with the draft's id, so the bot reads it with the draft.
struct DraftChatView: View {
    @Environment(AppStore.self) private var store
    let botId: String
    let itemId: String
    let title: String
    @State private var searching = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "pin.fill").foregroundStyle(Color.secondaryText).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("✎ Draft · \(itemId)").font(.caption.weight(.semibold)).foregroundStyle(Color.secondaryText)
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemGroupedBackground))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Pinned: draft \(itemId), \(title). Every message goes with it.")
            .accessibilityIdentifier("draft-chat-pin")
            Divider()
            if store.hasChat {
                BotChatPane(botId: botId, searching: $searching, itemId: itemId)
            } else {
                ContentUnavailableView("Chat needs an update", systemImage: "arrow.up.circle",
                                       description: Text("Update The Hermes on \(store.computerName) to discuss the draft here."))
            }
        }
        .navigationTitle(store.bot(botId)?.name ?? "Bot")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}
