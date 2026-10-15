import SwiftUI

/// A bot's conversation read from its transcript by the daemon, oldest first,
/// with a composer: Gravity's chat pane, on the phone.
struct BotChatPane: View {
    @Environment(AppStore.self) private var store
    @Environment(LensStore.self) private var lens
    let botId: String
    @Binding var searching: Bool
    /// A card or draft every message goes with (`send_user_message{item_id}`, K7).
    var itemId: String? = nil
    @State private var search = ChatSearchState()
    /// Which step groups the owner opened or closed, kept here rather than in the
    /// rows: a turn moving from the drawn tail into the lazy stack keeps it (H-228).
    @State private var expansions = StepExpansions()
    @State private var draft = ""
    @State private var pending: [PendingMessage] = []
    @State private var error: String?
    @State private var loaded = false
    /// Off once the owner scrolls up to read; new turns then stay put.
    @State private var following = true
    /// The repeated jumps to the end after a send; the owner's own scrolling stops them.
    @State private var jumper = EndJumper()

    private var turns: [ChatTurn] { lens.chats[botId] ?? [] }
    private var hasMore: Bool { lens.chatHasMore[botId] ?? false }
    private var canLoadEarlier: Bool { ChatPaging.canLoadEarlier(loaded: turns.count, hasMore: hasMore) }
    private var bot: Bot? { store.bot(botId) }

    var body: some View {
        VStack(spacing: 0) {
            if searching {
                ChatSearchBar(search: $search, turns: turns, hasMore: hasMore) { searching = false }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    // Older turns are lazy (H-228): laid out, a turn costs ~1.9 MB. The newest
                    // turns, pending messages and the end marker are not: a jump to the end
                    // from far up left a fully lazy stack with nothing drawn (H-227).
                    VStack(alignment: .leading, spacing: 18) {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            if canLoadEarlier {
                                Button("Show earlier activity") {
                                    following = false
                                    Task { await loadOlder() }
                                }
                                .buttonStyle(.bordered)
                                .frame(maxWidth: .infinity)
                            } else if hasMore {
                                Text(ChatPaging.capped(computer: store.computerName, bot: bot?.name ?? "the bot"))
                                    .font(.footnote)
                                    .foregroundStyle(Color.secondaryText)
                                    .frame(maxWidth: .infinity)
                            }
                            if let error {
                                Text(error).font(.footnote).foregroundStyle(Color.errorText)
                            }
                            if loaded, turns.isEmpty, pending.isEmpty {
                                Text("Nothing here yet. Messages you send, and everything \(bot?.name ?? "the bot") does, show up here.")
                                    .font(.callout)
                                    .foregroundStyle(Color.secondaryText)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 40)
                            }
                            ForEach(turns.dropLast(Self.eagerTurns)) { turn in
                                ChatTurnView(botId: botId, turn: turn, search: search, expansions: expansions)
                            }
                        }
                        ForEach(turns.suffix(Self.eagerTurns)) { turn in
                            ChatTurnView(botId: botId, turn: turn, search: search, expansions: expansions)
                        }
                        ForEach(pending) { message in PendingBubble(message: message) }
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                // The first row starts below the floating search button.
                .contentMargins(.top, 52, for: .scrollContent)
                .scrollDismissesKeyboard(.interactively)
                .modifier(TracksBottom(following: $following))
                // The owner scrolls: no jump pulls them back (H-228 M1).
                .modifier(OnOwnerScroll { jumper.ownerScrolled() })
                .accessibilityIdentifier("chat-transcript")
                // Search sits on the transcript, not in the navigation bar, so
                // the bot's state there is never cut short.
                .overlay(alignment: .topTrailing) {
                    if !searching {
                        Button { searching = true } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.body.weight(.medium))
                                .frame(width: 44, height: 44)
                                .background(.regularMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 6)
                        .padding(.trailing, 10)
                        .accessibilityLabel("Search this chat")
                    }
                }
                .onChange(of: turns.last) { _, _ in
                    if following, !searching { withAnimation { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
                }
                // Only a message sent: the bot picking one up shrinks the list (H-228 M1).
                .onChange(of: pending.count) { old, new in
                    if ChatScroll.jumpsOnPendingChange(from: old, to: new) { jumpToEnd(proxy) }
                }
                .onChange(of: search.focus) { _, focus in
                    if let focus { withAnimation { proxy.scrollTo(focus, anchor: .center) } }
                }
                .task {
                    await load()
                    jumpToEnd(proxy)
                }
            }
            ChatComposer(draft: $draft, botName: bot?.name ?? "the bot", blocked: blockedReason, send: send)
        }
        .onChange(of: turns) { _, turns in
            search.refind(in: turns)
            // A message shows as pending until the bot has read it into a turn.
            pending.removeAll { message in turns.contains { $0.mentions(message.text) } }
        }
        .onChange(of: searching) { _, open in
            if !open { search = ChatSearchState() }
        }
        .navigationDestination(for: StepLink.self) { StepDetailView(botId: $0.botId, event: $0.event) }
        .navigationDestination(for: LensArtifact.self) { ReportView(artifact: $0) }
    }

    private static let bottom = "chat-bottom"
    /// Drawn always, below the lazy stack, so the end has something to land on.
    private static let eagerTurns = 2

    /// From far up, a jump through lazy rows lands short: their heights were only
    /// estimated. Jump again as they are laid out (H-228).
    private func jumpToEnd(_ proxy: ScrollViewProxy) {
        jumper.jump { proxy.scrollTo(Self.bottom, anchor: .bottom) }
    }

    private var blockedReason: String? {
        if !store.canControl { return "This device can read but not write: it needs control access." }
        if store.status != .connected { return store.status.label }
        return nil
    }

    private func load() async {
        do {
            try await lens.loadChat(botId)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func loadOlder() async {
        do { try await lens.loadOlderChat(botId) } catch { self.error = error.localizedDescription }
        search.refind(in: turns)
    }

    private func send(_ text: String) async {
        following = true
        // A slash command is the terminal's: type it there, as the owner would.
        if text.hasPrefix("/") {
            await store.submitToTerminal(botId, text: text)
            return
        }
        var message = PendingMessage(text: text)
        pending.append(message)
        do {
            if let itemId {
                try await store.sendMessage(botId: botId, body: text, itemId: itemId)
            } else {
                try await store.sendMessage(botId: botId, body: text)
            }
            message.state = .sent
        } catch {
            message.state = .failed(error.localizedDescription)
        }
        if let index = pending.firstIndex(where: { $0.id == message.id }) { pending[index] = message }
    }
}

/// When the chat jumps to its end (H-228).
enum ChatScroll {
    /// Lazy rows lay out after the first jump lands: go again at these delays.
    static let repeats: [Duration] = [.milliseconds(100), .milliseconds(300), .milliseconds(600)]

    /// A message sent adds one; the bot picking one up removes it, and that
    /// must not move the owner (M1).
    static func jumpsOnPendingChange(from old: Int, to new: Int) -> Bool { new > old }
}

/// Jumps to the end, then again at `ChatScroll.repeats` as lazy rows lay out,
/// until the owner scrolls (M1).
@MainActor
final class EndJumper {
    private var task: Task<Void, Never>?

    func jump(_ scroll: @escaping @MainActor () -> Void) {
        task?.cancel()
        scroll()
        task = Task { @MainActor in
            for delay in ChatScroll.repeats {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
                scroll()
            }
        }
    }

    func ownerScrolled() {
        task?.cancel()
        task = nil
    }
}

/// Runs `action` when the owner starts scrolling: the scroll phase on iOS 18,
/// a drag on iOS 17.
private struct OnOwnerScroll: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollPhaseChange { _, phase in if phase == .interacting { action() } }
        } else {
            content.simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { _ in action() })
        }
    }
}

/// Step groups the owner opened or closed, by group (H-228).
@MainActor @Observable
final class StepExpansions {
    private var chosen: [String: Bool] = [:]

    func isExpanded(_ key: String, default open: Bool) -> Bool { chosen[key] ?? open }
    func set(_ key: String, _ open: Bool) { chosen[key] = open }

    func binding(_ key: String, default open: Bool) -> Binding<Bool> {
        Binding(get: { self.isExpanded(key, default: open) }, set: { self.set(key, $0) })
    }
}

// MARK: A turn

/// One turn in the chat: who woke the bot, what it said and did, how it ended.
struct ChatTurnView: View {
    @Environment(AppStore.self) private var store
    let botId: String
    let turn: ChatTurn
    let search: ChatSearchState
    var expansions: StepExpansions?

    private var events: [LensEvent] { turn.lensEvents }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            trigger
            ForEach(TurnBlock.blocks(events)) { block in
                switch block {
                case .event(let event):
                    EventRow(botId: botId, event: event)
                        .searchMark(search.color(turn.id, event.id), radius: 12)
                        .id(ChatSearchState.anchor(turn.id, event.id))
                case .steps(let steps):
                    StepGroup(botId: botId, steps: steps, expanded: turn.open || steps.count <= 4,
                              isExpanded: expansions?.binding(ChatSearchState.anchor(turn.id, steps.first?.id ?? ""),
                                                              default: turn.open || steps.count <= 4),
                              forceExpanded: search.active,
                              highlight: { search.color(turn.id, $0) },
                              anchorPrefix: ChatSearchState.anchor(turn.id, ""))
                    let images = steps.flatMap { $0.images ?? [] }
                    if !images.isEmpty { ImageStrip(botId: botId, refs: images) }
                }
            }
            if turn.open {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Working…").font(.footnote).foregroundStyle(Color.secondaryText)
                }
            }
            if let lens = turn.lensTurn(botName: nil), !lens.stats.line.isEmpty {
                Text(lens.stats.line).font(.caption).foregroundStyle(Color.secondaryText)
            }
        }
        // Outside a List, links and disclosure labels would take the accent colour.
        .tint(.primary)
    }

    private var lensTrigger: LensTrigger? { turn.lensTurn(botName: nil)?.trigger }

    private var header: some View {
        HStack(spacing: 6) {
            if let lensTrigger {
                Label(lensTrigger.headline, systemImage: lensTrigger.symbol).font(.caption.weight(.semibold))
            }
            Spacer()
            if let started = WireDate.parse(turn.startedAt) {
                Text(started.formatted(date: .abbreviated, time: .shortened)
                     + (turn.durationMs.map { " · took \(TurnDetailView.duration($0))" } ?? ""))
                    .font(.caption2)
            }
        }
        .foregroundStyle(Color.secondaryText)
    }

    /// The owner's words sit on the right, like a sent message; everything else is labelled.
    @ViewBuilder private var trigger: some View {
        let text = turn.trigger.text ?? ""
        if !text.isEmpty {
            let own = turn.trigger.kind == "owner"
            HStack {
                if own { Spacer(minLength: 40) }
                MarkdownText(text)
                    .padding(10)
                    .background(own ? Color.accentColor.opacity(0.16) : Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .searchMark(search.color(turn.id, ChatSearchState.triggerId), radius: 14)
                if !own { Spacer(minLength: 0) }
            }
            .id(ChatSearchState.anchor(turn.id, ChatSearchState.triggerId))
        }
    }
}

private extension View {
    /// A search match, laid over the item so its own background cannot hide it.
    func searchMark(_ color: Color?, radius: CGFloat) -> some View {
        overlay {
            if let color {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(color)
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(color, lineWidth: 2))
                    .allowsHitTesting(false)
            }
        }
    }
}

extension ChatTurn {
    /// Whether this turn delivered `text`: as its trigger, or as a message that came in mid-turn.
    func mentions(_ text: String) -> Bool {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        if trigger.kind == "owner", (trigger.text ?? "").contains(needle) { return true }
        return items.contains { $0.type == "aside" && $0.kind == "incoming" && ($0.text ?? "").contains(needle) }
    }
}

// MARK: Sending

struct PendingMessage: Identifiable, Equatable {
    enum State: Equatable {
        case queued, sent
        case failed(String)
    }

    let id = UUID()
    let text: String
    var state = State.queued

    var label: String {
        switch state {
        case .queued: "Queued"
        case .sent: "Delivered — waiting for the bot to read it"
        case .failed(let reason): "Not delivered: \(reason)"
        }
    }
}

/// A message the owner sent that the bot has not read yet.
private struct PendingBubble: View {
    let message: PendingMessage

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(message.text)
                .padding(10)
                .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(message.label)
                .font(.caption2)
                .foregroundStyle(message.state == .sent || message.state == .queued ? AnyShapeStyle(Color.secondaryText) : AnyShapeStyle(Color.errorText))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 40)
    }
}

private struct ChatComposer: View {
    @Binding var draft: String
    let botName: String
    /// Why the owner cannot write, or nil.
    let blocked: String?
    let send: (String) async -> Void
    @State private var sending = false
    @State private var dictation = Dictation()
    /// What was typed before dictation started; the words heard go after it.
    @State private var typed = ""

    private var text: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let blocked {
                Text(blocked).font(.caption).foregroundStyle(Color.secondaryText)
            } else if case .failed(let reason) = dictation.phase {
                Text(reason).font(.caption).foregroundStyle(Color.errorText)
            } else if dictation.isListening {
                Label("Listening… tap the microphone when you are done.", systemImage: "waveform")
                    .font(.caption).foregroundStyle(Color.errorText)
            } else if text.hasPrefix("/") {
                Text("Runs in the terminal, as if you typed it there.").font(.caption).foregroundStyle(Color.secondaryText)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message \(botName)", text: $draft, prompt: .placeholder("Message \(botName)"), axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .disabled(blocked != nil)
                Button { toggleDictation() } label: {
                    Image(systemName: dictation.isListening ? "mic.fill" : "mic")
                        .font(.title3)
                        .foregroundStyle(dictation.isListening ? .red : .accentColor)
                        .symbolEffect(.pulse, isActive: dictation.isListening)
                }
                .disabled(blocked != nil || sending)
                .accessibilityLabel(dictation.isListening ? "Stop dictating" : "Dictate a message")
                Button {
                    if dictation.isListening { dictation.stop() }
                    let message = text
                    draft = ""
                    sending = true
                    Task {
                        await send(message)
                        sending = false
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(text.isEmpty || blocked != nil || sending)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onChange(of: dictation.transcript) { _, heard in
            guard dictation.isListening else { return }
            draft = typed.isEmpty ? heard : typed + " " + heard
        }
        .onDisappear { dictation.cancel() }
    }

    /// Talk instead of typing: the words land in the box to check before sending.
    private func toggleDictation() {
        if dictation.isListening {
            dictation.stop()
            return
        }
        dictation.clearError()
        typed = text
        Task { await dictation.start() }
    }
}

// MARK: Search

/// Find in the chat: every case-insensitive match in the loaded turns, the
/// one in view apart, and the way between them.
struct ChatSearchState: Equatable {
    var query = ""
    /// Each match's scroll anchor, in reading order; an anchor repeats once per match in it.
    private(set) var matches: [String] = []
    private(set) var current = 0
    private var matched: Set<String> = []

    static let triggerId = "trigger"

    static func anchor(_ turnId: String, _ itemId: String) -> String { "\(turnId)#\(itemId)" }

    /// Searching opens folded steps so their text can be found.
    var active: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    var count: Int { matches.count }
    var focus: String? { matches.indices.contains(current) ? matches[current] : nil }

    var countLabel: String {
        guard active else { return "" }
        return matches.isEmpty ? "No matches" : "\(current + 1) of \(matches.count)"
    }

    mutating func setQuery(_ query: String, in turns: [ChatTurn]) {
        self.query = query
        current = 0
        refind(in: turns)
    }

    mutating func refind(in turns: [ChatTurn]) {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        matches = []
        if !needle.isEmpty {
            for turn in turns {
                for (itemId, text) in Self.texts(turn) {
                    let count = text.lowercased().components(separatedBy: needle).count - 1
                    matches += Array(repeating: Self.anchor(turn.id, itemId), count: max(count, 0))
                }
            }
        }
        matched = Set(matches)
        current = min(current, max(matches.count - 1, 0))
    }

    mutating func next() { if !matches.isEmpty { current = (current + 1) % matches.count } }
    mutating func previous() { if !matches.isEmpty { current = (current - 1 + matches.count) % matches.count } }

    func color(_ turnId: String, _ itemId: String) -> Color? {
        let anchor = Self.anchor(turnId, itemId)
        if anchor == focus { return .orange.opacity(0.35) }
        return matched.contains(anchor) ? .yellow.opacity(0.25) : nil
    }

    /// The words a turn shows, by the item they belong to.
    private static func texts(_ turn: ChatTurn) -> [(String, String)] {
        var result: [(String, String)] = [(triggerId, turn.trigger.text ?? "")]
        for item in turn.items {
            let words = [item.markdown, item.title, item.subtitle, item.body, item.result, item.text]
                .compactMap { $0 }.joined(separator: "\n")
            result.append((item.id, words))
        }
        return result
    }
}

private struct ChatSearchBar: View {
    @Binding var search: ChatSearchState
    let turns: [ChatTurn]
    let hasMore: Bool
    let done: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Search this chat", text: Binding(
                    get: { search.query },
                    set: { search.setQuery($0, in: turns) }), prompt: .placeholder("Search this chat"))
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.search)
                    .onSubmit { search.next(); focused = true }
                Text(search.countLabel).font(.caption.monospacedDigit()).foregroundStyle(Color.secondaryText)
                Button { search.previous() } label: { Image(systemName: "chevron.up") }
                    .disabled(search.count == 0)
                    .accessibilityLabel("Previous match")
                Button { search.next() } label: { Image(systemName: "chevron.down") }
                    .disabled(search.count == 0)
                    .accessibilityLabel("Next match")
                Button("Done", action: done)
            }
            if hasMore, search.active {
                Text("Only loaded turns are searched.").font(.caption2).foregroundStyle(Color.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onAppear { focused = true }
    }
}

/// Reading back up stops the chat jumping to new turns; the bottom resumes it.
/// Before iOS 18 the chat always follows.
private struct TracksBottom: ViewModifier {
    @Binding var following: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 80
            } action: { _, atBottom in
                following = atBottom
            }
        } else {
            content
        }
    }
}
