import SwiftUI

/// A bot's thread in the main chat, on the computer that holds it.
struct ThreadLink: Hashable {
    let computerId: String
    let botId: String
}

/// The main chat (UX-024): a thread per bot on every computer, newest
/// questions first, and a composer that reaches any bot without opening it.
struct MainChatView: View {
    @Environment(Fleet.self) private var fleet
    /// Set from outside (a notification): opens that bot's chat on the computer on screen.
    var openBot: Binding<BotLink?> = .constant(nil)
    /// Set in the iPad inspector, which shows the title inline (UX-029).
    var title: String?
    /// Set from outside (the iPad's ✎): opens that bot's thread.
    var openThread: Binding<ThreadLink?> = .constant(nil)
    @State private var path = NavigationPath()
    @State private var threads: [ThreadCard] = []
    @State private var loaded = false
    @State private var failure: String?
    @State private var picking = false

    private var connected: [Computer] { fleet.computers.filter { $0.store.status == .connected } }
    /// Computers older than owner threads: their bots are listed to chat with directly.
    private var older: [Computer] { connected.filter { !$0.store.hasOwnerThreads } }
    private var versions: String {
        connected.map { "\($0.id):\($0.store.ownerThreadsVersion):\($0.store.hasOwnerThreads)" }.joined(separator: ",")
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if loaded, threads.isEmpty, older.isEmpty {
                    EmptyNote(text: "No messages yet. Write to any bot with ✎.", systemImage: "bubble.left.and.bubble.right")
                }
                if !threads.isEmpty {
                    Section {
                        ForEach(threads) { card in
                            NavigationLink(value: ThreadLink(computerId: card.computerId, botId: card.botId)) {
                                ThreadRow(card: card, project: projectName(card))
                            }
                        }
                    }
                }
                ForEach(older) { computer in
                    Section {
                        ForEach(computer.store.bots.filter { !$0.temporary }) { bot in
                            NavigationLink(value: ThreadLink(computerId: computer.id, botId: bot.id)) {
                                Text(bot.name)
                            }
                        }
                    } header: {
                        SectionTitle(computer.name)
                    } footer: {
                        Text("Threads come with The Hermes 0.17 on \(computer.name). Until then, these open the bot’s chat.")
                            .foregroundStyle(Color.secondaryText)
                    }
                }
                if let failure {
                    Text(failure).font(.footnote).foregroundStyle(Color.errorText)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title ?? "Chat")
            .navigationBarTitleDisplayMode(title == nil ? .automatic : .inline)
            .toolbar {
                // In the iPad inspector the window's toolbar holds ✎ (UX-029: ✉ · ✎ · ⋯).
                if title == nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { picking = true } label: { Image(systemName: "square.and.pencil") }
                            .accessibilityLabel("Message a bot")
                            .keyboardShortcut("n", modifiers: .command)
                    }
                }
            }
            .onChange(of: openThread.wrappedValue, initial: true) { _, link in
                guard let link else { return }
                path = NavigationPath([link])
                openThread.wrappedValue = nil
            }
            .refreshable { await load() }
            .task(id: versions) { await load() }
            .reloadsOnReconnect { await load() }
            .navigationDestination(for: ThreadLink.self) { link in
                if let computer = fleet.computer(id: link.computerId) {
                    Group {
                        if computer.store.hasOwnerThreads {
                            OwnerThreadView(botId: link.botId)
                        } else {
                            BotDetailView(botId: link.botId, initialPane: .chat)
                        }
                    }
                    .computerEnvironment(computer)
                }
            }
            .navigationDestination(for: BotLink.self) { BotDetailView(botId: $0.botId, initialPane: $0.pane) }
            .needsDestinations()
            .onChange(of: openBot.wrappedValue, initial: true) { _, link in
                guard let link else { return }
                path = NavigationPath([link])
                openBot.wrappedValue = nil
            }
            .sheet(isPresented: $picking) {
                BotPicker { link in
                    picking = false
                    path.append(link)
                }
            }
        }
        // Card ids anywhere in this stack open the card here (H-204).
        .opensCardLinks { path.append($0) }
    }

    private func projectName(_ card: ThreadCard) -> String? {
        fleet.computer(id: card.computerId)?.store.projects.first { $0.id == card.projectId }?.name
    }

    private func load() async {
        var lists: [(computerId: String, daemonId: String?, threads: [Hermes_Home_V1_OwnerThread])] = []
        var failed: [String] = []
        await withTaskGroup(of: (Computer, [Hermes_Home_V1_OwnerThread]?).self) { group in
            for computer in connected where computer.store.hasOwnerThreads {
                group.addTask { (computer, try? await computer.store.ownerThreads()) }
            }
            for await (computer, result) in group {
                if let result {
                    lists.append((computer.id, computer.store.daemonId, result))
                } else {
                    failed.append(computer.name)
                }
            }
        }
        var merged = ThreadMerge.merge(lists)
        // A thread with an open question previews it: read those few threads.
        for index in merged.indices where merged[index].openQuestion {
            guard let computer = fleet.computer(id: merged[index].computerId) else { continue }
            let entries = try? await computer.store.ownerThread(botId: merged[index].botId)
            merged[index].preview(question: entries?.openQuestion)
        }
        threads = merged
        failure = failed.isEmpty ? nil : "Couldn’t load the threads on \(failed.joined(separator: ", "))."
        loaded = true
    }
}

private struct ThreadRow: View {
    let card: ThreadCard
    let project: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(card.botName).font(.body.weight(card.unread > 0 ? .semibold : .regular))
                if let project { Text(project).font(.caption).foregroundStyle(Color.secondaryText) }
                Spacer(minLength: 4)
                if let at = card.at { Text(at.relative).font(.caption).foregroundStyle(Color.secondaryText) }
            }
            HStack(alignment: .top, spacing: 6) {
                if card.openQuestion { Pill(text: "Question", tone: .needsYou) }
                Text((card.lastFromOwner ? "You: " : "") + card.last)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if card.unread > 0 {
                    Text("\(card.unread)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                        .accessibilityLabel("\(card.unread) unread")
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
    }
}

/// One bot's thread with the owner: its notes and questions, the owner's
/// messages, and a composer (`send_user_message`).
struct OwnerThreadView: View {
    @Environment(AppStore.self) private var store
    let botId: String
    @State private var entries: [ThreadEntry] = []
    @State private var draft = ""
    @State private var sending = false
    @State private var failure: String?

    private var bot: Bot? { store.bot(botId) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if entries.isEmpty {
                        Text("Nothing here yet. Your message goes to \(bot?.name ?? "the bot") as a chat.")
                            .font(.footnote).foregroundStyle(Color.secondaryText)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(entries) { entry in
                        ThreadBubble(entry: entry).id(entry.id)
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: entries.last?.id) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle(bot?.name ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: BotLink(botId: botId, pane: nil)) { Image(systemName: "person.crop.circle") }
                    .accessibilityLabel("Open \(bot?.name ?? "the bot")")
            }
        }
        .task(id: store.ownerThreadsVersion) { await load() }
        .reloadsOnReconnect { await load() }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let failure { Text(failure).font(.caption).foregroundStyle(Color.errorText) }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message \(bot?.name ?? "the bot")", text: $draft,
                          prompt: .placeholder("Message \(bot?.name ?? "the bot")"), axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                Button {
                    send()
                } label: {
                    if sending { ProgressView() } else { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                }
                .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canControl)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }

    private func load() async {
        do {
            entries = try await store.ownerThread(botId: botId)
            failure = nil
            if let last = entries.last?.num, last > 0 { await store.markThreadRead(botId: botId, upTo: last) }
        } catch {
            failure = "Couldn’t load the thread. \(error.localizedDescription)"
        }
    }

    private func send() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        sending = true
        Task {
            do {
                try await store.sendMessage(botId: botId, body: body)
                draft = ""
                failure = nil
                await load()
            } catch {
                failure = error.localizedDescription
            }
            sending = false
        }
    }
}

private struct ThreadBubble: View {
    @Environment(Fleet.self) private var fleet
    let entry: ThreadEntry

    var body: some View {
        HStack {
            if entry.fromOwner { Spacer(minLength: 40) }
            VStack(alignment: entry.fromOwner ? .trailing : .leading, spacing: 4) {
                // A bot's question, labelled as on desktop (UX-031).
                if entry.asks && !entry.fromOwner {
                    Text(ThreadWords.asks(entry.at))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(entry.open ? Color.warningText : Color.secondaryText)
                }
                // Each card id its own link: tap, long-press, hover, VoiceOver (H-207).
                LinkedText(markdown: OwnerText.stripEnvelope(entry.text))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(entry.fromOwner ? Color.accentColor.opacity(0.15) : Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                if let at = entry.at, !(entry.asks && !entry.fromOwner) {
                    Text(at.relative).font(.caption2).foregroundStyle(Color.secondaryText)
                }
            }
            if !entry.fromOwner { Spacer(minLength: 40) }
        }
    }
}

/// Every bot on every computer, by project, to start a message (UX-024 Q2:
/// one recipient per message).
struct BotPicker: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    let pick: (ThreadLink) -> Void
    @State private var search = ""

    private struct Group: Identifiable {
        let id: String
        let title: String
        let computerId: String
        let bots: [Bot]
    }

    private var groups: [Group] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return fleet.computers.filter { $0.store.status == .connected }.flatMap { computer in
            computer.store.projects.compactMap { project -> Group? in
                let bots = computer.store.bots
                    .filter { $0.projectId == project.id && !$0.temporary }
                    .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                guard !bots.isEmpty else { return nil }
                let title = fleet.computers.count > 1 ? "\(project.name) · \(computer.name)" : project.name
                return Group(id: "\(computer.id)/\(project.id)", title: title, computerId: computer.id, bots: bots)
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.bots) { bot in
                            Button {
                                pick(ThreadLink(computerId: group.computerId, botId: bot.id))
                            } label: {
                                HStack {
                                    Text(bot.name).foregroundStyle(.primary)
                                    if let peer = bot.peerName {
                                        Text("on \(peer)").font(.caption).foregroundStyle(Color.secondaryText)
                                    }
                                    Spacer()
                                    Text(bot.state.label).font(.caption).foregroundStyle(Color.secondaryText)
                                }
                            }
                        }
                    } header: {
                        SectionTitle(group.title)
                    }
                }
                if groups.isEmpty {
                    EmptyNote(text: search.isEmpty ? "No bots on a connected computer." : "No bot named “\(search)”.",
                              systemImage: "person.2")
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Bot")
            .navigationTitle("Message a bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
