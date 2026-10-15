import SwiftUI

/// Where a turn came from, in words.
extension LensTrigger {
    var headline: String {
        switch kind {
        case "message":
            let sender = from.isEmpty ? "someone" : from
            switch msgKind {
            case "task": return "Task from \(sender)"
            case "reply": return "Reply from \(sender)"
            case "done": return "\(sender) finished a task"
            case "decision": return "Your ruling"
            case "note": return from == "You" ? "Note from you" : "Note from \(sender)"
            default: return "Message from \(sender)"
            }
        case "owner": return "You"
        case "typed": return "You, in the terminal"
        case "routine": return from.isEmpty ? "Routine" : "Routine \(from)"
        case "background": return "Background job finished"
        default: return "Continued"
        }
    }

    var symbol: String {
        switch kind {
        case "typed", "owner": "person.fill"
        case "routine": "calendar.badge.clock"
        case "background": "clock.arrow.circlepath"
        case "message": msgKind == "task" ? "tray.and.arrow.down.fill" : "bubble.left.fill"
        default: "arrow.turn.down.right"
        }
    }
}

extension LensStats {
    /// "12 commands · 3 files +120 −4 · 2 messages"
    var line: String {
        var parts: [String] = []
        if commands > 0 { parts.append("\(commands) command\(commands == 1 ? "" : "s")") }
        if edits > 0 { parts.append("\(edits) file\(edits == 1 ? "" : "s") +\(added) −\(removed)") }
        if sent > 0 { parts.append("\(sent) message\(sent == 1 ? "" : "s") sent") }
        if parts.isEmpty, reads > 0 { parts.append("read \(reads) file\(reads == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

/// One turn at a glance: who asked, what came of it, how much work it took.
struct TurnCard: View {
    @Environment(AppStore.self) private var store
    let turn: LensTurn
    var showBot = false
    /// For a bot's own list, where turns do not carry the bot id.
    var botIdFallback = ""

    private var botId: String { turn.botId ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if showBot, let bot = store.bot(botId) {
                    AvatarView(avatar: bot.avatar, name: bot.name, size: 26)
                    Text(bot.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                } else if showBot {
                    Text(turn.botName ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                } else {
                    trigger
                }
                Spacer(minLength: 4)
                if turn.open {
                    ProgressView().controlSize(.mini)
                } else if let at = turn.updated {
                    Text(at.relative).font(.caption).foregroundStyle(Color.secondaryText)
                }
            }
            if showBot { trigger }
            if !turn.trigger.text.isEmpty {
                Text(plain(turn.trigger.text))
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(2)
            }
            if turn.open, !turn.current.isEmpty {
                Label(turn.current, systemImage: "play.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.tint)
                    .lineLimit(1)
            }
            outcome
            if let cover = turn.cover, let bot = turn.botId ?? Optional(botIdFallback) {
                LensImageView(source: .bot(bot, cover))
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        if turn.stats.images > 1 {
                            Label("\(turn.stats.images)", systemImage: "photo.on.rectangle")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(6)
                        }
                    }
            }
            if !turn.stats.line.isEmpty || turn.stats.errors > 0 {
                HStack(spacing: 8) {
                    Text(turn.stats.line)
                    if turn.stats.errors > 0 {
                        Label("\(turn.stats.errors)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.warningText)
                    }
                }
                .font(.caption)
                .foregroundStyle(Color.secondaryText)
            }
        }
        .padding(.vertical, 4)
    }

    private var trigger: some View {
        Label(turn.trigger.headline, systemImage: turn.trigger.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.secondaryText)
            .lineLimit(1)
    }

    @ViewBuilder private var outcome: some View {
        switch turn.outcome.kind {
        case "none":
            EmptyView()
        default:
            VStack(alignment: .leading, spacing: 3) {
                if turn.outcome.kind == "message" {
                    Label("To \(turn.outcome.to)", systemImage: "arrowshape.turn.up.right.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tint)
                } else if turn.outcome.kind == "completed" {
                    Label("Task completed", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.successText)
                }
                Text(plain(turn.outcome.text)).font(.callout).lineLimit(4)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    /// Markdown markers stripped, for a few lines of preview.
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\n\n", with: "\n")
    }
}

/// Home: what needs the owner on every computer, then what the bots on
/// this one are doing and have just done.
struct FeedView: View {
    @Environment(AppStore.self) private var store
    @Environment(LensStore.self) private var lens
    /// Shows the Decisions tab for a computer.
    var openDecisions: (Computer) -> Void = { _ in }

    private var working: [LensTurn] { lens.feed.filter(\.open) }
    private var recent: [LensTurn] { lens.feed.filter { !$0.open } }

    var body: some View {
        NavigationStack {
            List {
                NeedsYouSection(openDecisions: openDecisions)
                if !working.isEmpty {
                    Section {
                        ForEach(working) { turn in
                            NavigationLink(value: TurnLink(botId: turn.botId ?? "", turnId: turn.id)) { WorkingRow(turn: turn) }
                        }
                    } header: {
                        SectionTitle("Working now", count: working.count)
                    }
                }
                if !recent.isEmpty {
                    Section {
                        ForEach(recent) { turn in
                            NavigationLink(value: TurnLink(botId: turn.botId ?? "", turnId: turn.id)) { RecentRow(turn: turn) }
                        }
                    } header: {
                        SectionTitle("Recent")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay { if lens.feed.isEmpty { LensEmptyState() } }
            .safeAreaInset(edge: .top, spacing: 0) { ConnectionBanner() }
            .refreshable { await lens.refresh() }
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ComputerSwitcher() }
                ToolbarItem(placement: .topBarTrailing) { SettingsButton() }
            }
            .navigationDestination(for: TurnLink.self) { TurnDetailView(botId: $0.botId, turnId: $0.turnId) }
        }
    }
}

/// A finished turn on Home: who, what came of it, what started it and when.
private struct RecentRow: View {
    @Environment(AppStore.self) private var store
    let turn: LensTurn

    private var summary: String {
        let text = turn.outcome.kind == "none" ? turn.trigger.text : turn.outcome.text
        let plain = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        if turn.outcome.kind == "message", !turn.outcome.to.isEmpty { return "To \(turn.outcome.to): \(plain)" }
        return plain
    }

    private var detail: String {
        var parts = [turn.trigger.headline]
        if let at = turn.updated { parts.append(at.relative) }
        if turn.stats.errors > 0 { parts.append("\(turn.stats.errors) error\(turn.stats.errors == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let bot = store.bot(turn.botId ?? "")
        ItemRow(title: bot?.name ?? turn.botName ?? "A bot", subtitle: summary, detail: detail, subtitleLines: 2) {
            if let bot {
                AvatarView(avatar: bot.avatar, name: bot.name, size: 36)
            } else {
                IconTile(systemImage: "person")
            }
        } trailing: {
            if turn.outcome.kind == "completed" { Pill(text: "Done", tone: .ready) }
        }
    }
}

/// A bot at work: who, and the step it is on.
private struct WorkingRow: View {
    @Environment(AppStore.self) private var store
    let turn: LensTurn

    var body: some View {
        let bot = store.bot(turn.botId ?? "")
        ItemRow(title: bot?.name ?? turn.botName ?? "A bot",
                subtitle: turn.current.isEmpty ? turn.trigger.headline : turn.current,
                detail: turn.current.isEmpty ? nil : turn.trigger.headline) {
            if let bot {
                AvatarView(avatar: bot.avatar, name: bot.name, size: 36)
            } else {
                IconTile(systemImage: "person")
            }
        } trailing: {
            StatusLabel(text: "Working", tone: .working, busy: true)
        }
    }
}

/// Everything waiting on the owner, from every computer the phone knows:
/// tool prompts to answer here, bots asking in their terminal or stuck, and
/// decisions waiting for a ruling.
struct NeedsYouSection: View {
    @Environment(Fleet.self) private var fleet
    var openDecisions: (Computer) -> Void

    private struct Waiting: Identifiable {
        let computer: Computer
        let bot: Bot
        let line: String
        let tone: Tone
        var id: String { "\(computer.id)/\(bot.id)" }
    }

    /// Bots asking in their terminal, or crashed, or locked out.
    private var waiting: [Waiting] {
        fleet.computers.flatMap { computer in
            computer.store.bots.compactMap { bot -> Waiting? in
                guard !bot.isLinked else { return nil }
                // A prompt answered by card is listed as the card.
                if computer.store.permissions.contains(where: { $0.botId == bot.id }) { return nil }
                if let detail = computer.store.approvals[bot.id] { return Waiting(computer: computer, bot: bot, line: detail, tone: .needsYou) }
                switch bot.state {
                case .waitingForUser, .waitingForApproval:
                    return Waiting(computer: computer, bot: bot, line: bot.stateReason.isEmpty ? bot.state.label : bot.stateReason, tone: .needsYou)
                case .crashed, .authFailed:
                    return Waiting(computer: computer, bot: bot, line: bot.stateReason.isEmpty ? bot.state.label : bot.stateReason, tone: .failed)
                default:
                    return nil
                }
            }
        }
    }

    private var decisions: [Computer] { fleet.computers.filter { $0.store.pendingCounts.total > 0 } }
    private var prompts: Int { fleet.computers.reduce(0) { $0 + $1.store.permissions.count } }
    private var count: Int { prompts + waiting.count + decisions.reduce(0) { $0 + $1.store.pendingCounts.total } }
    private var many: Bool { fleet.computers.count > 1 }

    var body: some View {
        if prompts > 0 {
            Section {
                ForEach(fleet.computers) { computer in
                    ForEach(computer.store.permissions) { request in
                        PermissionCard(request: request)
                            .computerEnvironment(computer)
                            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
            } header: {
                SectionTitle("Needs you", count: count)
            }
        }
        if !waiting.isEmpty || !decisions.isEmpty {
            Section {
                ForEach(waiting) { item in
                    NavigationLink {
                        BotDetailView(botId: item.bot.id).computerEnvironment(item.computer)
                    } label: {
                        ItemRow(title: item.bot.name, subtitle: item.line, detail: many ? "on \(item.computer.name)" : nil, subtitleLines: 2) {
                            AvatarView(avatar: item.bot.avatar, name: item.bot.name, size: 36)
                        } trailing: {
                            StatusLabel(text: item.tone == .failed ? item.bot.state.label : "Needs you", tone: item.tone)
                        }
                    }
                }
                ForEach(decisions) { computer in
                    let pending = computer.store.pendingCounts
                    Button { openDecisions(computer) } label: {
                        ItemRow(title: pending.total == 1 ? "1 open decision" : "\(pending.total) open decisions",
                                subtitle: pending.urgent > 0 ? "\(pending.urgent) urgent" : "Bots want your ruling",
                                detail: many ? "on \(computer.name)" : nil) {
                            IconTile(systemImage: "checklist", tone: pending.urgent > 0 ? .failed : .needsYou)
                        } trailing: {
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                if prompts == 0 { SectionTitle("Needs you", count: count) }
            }
        }
    }
}

struct TurnLink: Hashable {
    let botId: String
    let turnId: String
}

/// One bot's turns, newest first, with older ones on demand.
struct BotActivityView: View {
    @Environment(AppStore.self) private var store
    @Environment(LensStore.self) private var lens
    let botId: String
    @State private var turns: [LensTurn] = []
    @State private var hasMore = false
    @State private var loaded = false

    var body: some View {
        List {
            ForEach(turns) { turn in
                NavigationLink(value: TurnLink(botId: botId, turnId: turn.id)) { TurnCard(turn: turn, botIdFallback: botId) }
            }
            if hasMore {
                Button("Load earlier turns") { Task { await loadMore() } }
            }
        }
        .listStyle(.plain)
        .overlay { if loaded, turns.isEmpty { LensEmptyState() } }
        .refreshable { await reload() }
        // Pick up new turns as the latest one moves on.
        .task(id: lens.latest[botId]) { await reload() }
    }

    private func reload() async {
        guard let page = try? await lens.turns(bot: botId) else { loaded = true; return }
        if turns.count > page.turns.count {
            // Earlier pages were loaded: keep them under the fresh first page.
            let fresh = Set(page.turns.map(\.id))
            turns = page.turns + turns.filter { !fresh.contains($0.id) }
        } else {
            turns = page.turns
            hasMore = page.hasMore
        }
        loaded = true
    }

    private func loadMore() async {
        guard let last = turns.last, let page = try? await lens.turns(bot: botId, before: last.id) else { return }
        turns += page.turns
        hasMore = page.hasMore
    }
}

struct LensEmptyState: View {
    @Environment(AppStore.self) private var store
    @Environment(LensStore.self) private var lens

    var body: some View {
        switch lens.status {
        case .unknown:
            ProgressView()
        case .unreachable:
            ContentUnavailableView {
                Label("Lens not reachable", systemImage: "eye.slash")
            } description: {
                Text("The activity view needs the Lens companion running on \(store.computerName), on port \(String(lens.port)). See the README in The Hermes iOS project.")
            }
        case .unauthorized:
            ContentUnavailableView("Token rejected", systemImage: "lock",
                                   description: Text("Lens checks the same device token as the Hermes service. It needs read access."))
        case .ok:
            ContentUnavailableView("Nothing yet", systemImage: "text.bubble",
                                   description: Text("Turns appear here as the bots work."))
        }
    }
}
