import SwiftUI

/// The bot's DM thread on the message bus. The bot reads these between tool
/// calls; what it says in its own terminal shows on the Terminal pane instead.
struct ChatView: View {
    @Environment(AppStore.self) private var store
    let botId: String
    @State private var draft = ""
    @State private var error: String?

    private var thread: [BusMessage] {
        guard let conversation = store.conversations[botId] else { return [] }
        return store.messages[conversation.id] ?? []
    }

    private var hasMore: Bool {
        store.conversations[botId].flatMap { store.messagesHaveMore[$0.id] } ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ListEnd(hasMore: hasMore, noun: "messages", loaded: thread.count) {
                            await store.loadOlderMessages(botId: botId)
                        }
                        ForEach(thread) { message in
                            MessageBubble(message: message).id(message.id)
                        }
                    }
                    .padding(12)
                }
                .overlay {
                    if thread.isEmpty {
                        ContentUnavailableView("No messages", systemImage: "bubble.left.and.bubble.right",
                                               description: Text("Messages sent here are delivered to the bot's inbox."))
                    }
                }
                .onChange(of: thread.last?.id) { _, last in
                    if let last { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
                }
                .onAppear {
                    if let last = thread.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            if store.canControl { composer }
        }
        .task(id: store.status) { await store.loadMessages(botId: botId) }
        .errorAlert("Couldn’t send the message.", $error)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, prompt: .placeholder("Message"), axis: .vertical)
                .lineLimit(1...6)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Button {
                let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                draft = ""
                Task {
                    do { try await store.sendMessage(botId: botId, body: body) } catch {
                        draft = body
                        self.error = error.localizedDescription
                    }
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct MessageBubble: View {
    let message: BusMessage

    var body: some View {
        VStack(alignment: message.fromUser ? .trailing : .leading, spacing: 3) {
            HStack(spacing: 6) {
                if !message.fromUser { Text(message.senderName).font(.caption.weight(.semibold)) }
                if message.kind != "chat" {
                    Text(MessageKind.label(message.kind)).font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if let at = message.createdAt {
                    Text(at, style: .time).font(.caption2).foregroundStyle(Color.secondaryText)
                }
            }
            Text(message.body)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(message.fromUser ? .white : .primary)
                .background(
                    message.fromUser ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.secondarySystemBackground)),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: message.fromUser ? .trailing : .leading)
    }
}
