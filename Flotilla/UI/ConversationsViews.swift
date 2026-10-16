import SwiftUI

/// Opens a project's Conversations view from the Bots list.
struct ConversationsLink: Hashable {
    let projectId: String
}

/// What a project's bots have said to each other: the pairs that talked,
/// most recently active first.
struct ConversationsView: View {
    @Environment(AppStore.self) private var store
    let projectId: String
    @State private var conversations: [AgentConversation] = []
    @State private var bots: [String: AgentBot] = [:]
    @State private var loaded = false
    @State private var error: String?

    /// The project's bots in the Bots list's order, which decides each pair's sides.
    private var order: [String] {
        store.projects.first { $0.id == projectId }.map { store.bots(in: $0).map(\.id) } ?? []
    }

    var body: some View {
        List {
            if let error {
                Text(error).font(.footnote).foregroundStyle(Color.errorText)
            }
            if loaded, conversations.isEmpty, error == nil {
                EmptyNote(text: "When bots message each other, their conversations appear here.", systemImage: "bubble.left.and.bubble.right")
            }
            if !conversations.isEmpty {
                Section {
                    ForEach(conversations) { conversation in
                        let pair = AgentConversations.sides(conversation.botIds, order: order)
                        NavigationLink {
                            ConversationThreadView(projectId: projectId, pair: pair, knownBots: bots)
                        } label: {
                            PairRow(conversation: conversation, pair: pair, bots: bots)
                        }
                    }
                } header: {
                    SectionTitle("Conversations", count: conversations.count)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Conversations")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: store.status) { await load() }
        .task(id: store.botMessageRevision) {
            guard loaded else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private func load() async {
        guard store.status == .connected else { return }
        do {
            let reply = try await store.agentConversations(projectId: projectId)
            conversations = reply.conversations
            bots = Dictionary(reply.bots.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

/// One pair: both faces, who they are, and the latest word.
private struct PairRow: View {
    let conversation: AgentConversation
    let pair: (left: String, right: String)
    let bots: [String: AgentBot]

    var body: some View {
        ItemRow(title: AgentConversations.title(pair, bots: bots), subtitle: AgentConversations.preview(conversation, bots: bots),
                detail: conversation.lastAt?.relative, subtitleLines: 2) {
            ZStack(alignment: .bottomTrailing) {
                face(pair.left).padding(.trailing, 12).padding(.bottom, 10)
                face(pair.right)
            }
        } trailing: {
            Pill(text: "\(conversation.messageCount)").accessibilityLabel("\(conversation.messageCount) messages")
        }
    }

    private func face(_ id: String) -> some View {
        let bot = AgentConversations.bot(id, in: bots)
        return AvatarView(avatar: bot.avatar, name: bot.name, size: 30)
    }
}

/// One pair's messages, oldest first, as a chat between the two, each bot in
/// its own bubble on its own side.
struct ConversationThreadView: View {
    @Environment(AppStore.self) private var store
    let projectId: String
    let pair: (left: String, right: String)
    let knownBots: [String: AgentBot]
    @State private var messages: [AgentMessage] = []
    @State private var bots: [String: AgentBot] = [:]
    @State private var hasMore = false
    @State private var loaded = false
    @State private var error: String?

    private var allBots: [String: AgentBot] { knownBots.merging(bots) { _, thread in thread } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if hasMore {
                        Button("Load earlier messages") { Task { await loadOlder() } }
                            .buttonStyle(.bordered)
                    }
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(Color.errorText)
                    }
                    ForEach(messages) { message in
                        Bubble(message: message,
                               sender: AgentConversations.bot(message.fromBotId, in: allBots),
                               left: message.fromBotId == pair.left)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .task {
                await load()
                if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .navigationTitle(AgentConversations.title(pair, bots: allBots))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.botMessageRevision) {
            guard loaded else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    /// The newest page, merged into what is loaded.
    private func load() async {
        await fetch(before: nil)
        loaded = true
    }

    private func loadOlder() async {
        await fetch(before: messages.first?.num)
    }

    private func fetch(before: Int?) async {
        guard store.status == .connected else { return }
        do {
            let page = try await store.agentConversation(projectId: projectId, botIds: [pair.left, pair.right], before: before)
            messages = AgentConversations.merge(messages, page.messages)
            for bot in page.bots { bots[bot.id] = bot }
            // Only a page reaching back past what was loaded says whether more exist.
            if before != nil || !loaded { hasMore = page.hasMore }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One message: the sender's avatar beside its own bubble, on its side.
private struct Bubble: View {
    let message: AgentMessage
    let sender: AgentBot
    let left: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if !left { Spacer(minLength: 36) }
            if left { AvatarView(avatar: sender.avatar, name: sender.name, size: 28) }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(sender.label).font(.caption.weight(.semibold))
                    Text(message.kindLabel)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                    if let state = message.taskState {
                        Pill(text: TaskStateLabel.label(state), tone: state == "done" ? .ready : state == "open" ? .needsYou : .quiet)
                    }
                    Spacer(minLength: 0)
                    if let at = message.createdAt {
                        Text(TaskTime.text(at)).font(.caption2).foregroundStyle(Color.secondaryText)
                    }
                }
                MarkdownText(message.body)
            }
            .padding(10)
            .background(left ? Color(.secondarySystemBackground) : Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if !left { AvatarView(avatar: sender.avatar, name: sender.name, size: 28) }
            if left { Spacer(minLength: 36) }
        }
    }
}
