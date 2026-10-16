import SwiftUI

// Board glance (0.20): a project on Projects as its board, its fleet and the
// one thing it needs from you (BG-Rules §1–§6). The rules are in
// Core/BoardGlance.swift; these are the pieces a card is drawn from.

extension ProjectState {
    var tone: Tone {
        switch self {
        case .readOnly: .away
        case .needsYou: .needsYou
        case .working: .working
        case .setUp, .idle: .quiet
        }
    }
}

extension HomeCard {
    /// Its tile's colour: the project's id on the board's home, so both
    /// computers give it the same one.
    var glyphSeed: String { row.members.first { $0.daemonID == row.boardHome }?.projectID ?? row.projectID }
}

/// A project's tile: its monogram on a colour of its own.
struct ProjectGlyph: View {
    let name: String
    let seed: String
    var size: CGFloat = 34
    @ScaledMetric(relativeTo: .headline) private var scale: CGFloat = 1

    var body: some View {
        let side = size * min(scale, 1.4)
        let rgb = Color.projectGlyphs[GlanceWords.paletteIndex(seed, count: Color.projectGlyphs.count)]
        RoundedRectangle(cornerRadius: side * 0.26, style: .continuous)
            .fill(Color(light: rgb, dark: rgb))
            .frame(width: side, height: side)
            .overlay {
                Text(GlanceWords.monogram(name))
                    .font(.system(size: side * 0.38, weight: .bold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// The card's one state: a glyph and a word in a tinted capsule.
struct StatePill: View {
    let state: ProjectState

    var body: some View {
        Pill(text: state.pill, tone: state.tone).accessibilityLabel(state.spoken)
    }
}

// MARK: Mini board

/// The board as one bar: a segment per column, as long as its cards; an
/// empty column draws none, and a board with nothing yet an empty track.
struct MiniBoardBar: View {
    let segments: [BoardSegment]
    var height: CGFloat = 10
    private static let gap: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            let drawn = segments.filter { $0.count > 0 }
            if drawn.isEmpty {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color(.tertiarySystemFill))
            } else {
                let room = proxy.size.width - Self.gap * CGFloat(drawn.count - 1)
                let widths = Self.widths(drawn.map(\.count), room: room)
                HStack(spacing: Self.gap) {
                    ForEach(Array(drawn.enumerated()), id: \.offset) { index, segment in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(segment.shade.color)
                            .overlay { if segment.shade == .more { Hatch() } }
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                            .frame(width: widths[index])
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    /// Widths by count, none under `minimum` so one card next to thirty still shows.
    static func widths(_ counts: [Int], room: CGFloat, minimum: CGFloat = 4) -> [CGFloat] {
        let total = CGFloat(counts.reduce(0, +))
        guard total > 0, room > 0 else { return counts.map { _ in 0 } }
        let raw = counts.map { room * CGFloat($0) / total }
        let short = raw.filter { $0 < minimum }.count
        let tall = raw.filter { $0 >= minimum }.reduce(0, +)
        let left = room - CGFloat(short) * minimum
        return raw.map { $0 < minimum ? minimum : (tall > 0 ? $0 * left / tall : $0) }
    }
}

/// "+N more" is striped, so it reads as several columns, not one.
private struct Hatch: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 5
            }
            context.stroke(path, with: .color(.white.opacity(0.4)), lineWidth: 1.5)
        }
    }
}

/// Counts and names under the bar: "9 To do".
struct MiniBoardLegend: View {
    let segments: [BoardSegment]

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                (Text("\(segment.count)").font(.footnote.weight(.semibold)).foregroundStyle(.primary)
                    + Text(" \(segment.name)").font(.caption).foregroundStyle(Color.secondaryText))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityHidden(true)
    }
}

/// At accessibility text sizes the bar becomes a row per column (§6, case 7).
struct MiniBoardRows: View {
    let segments: [BoardSegment]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if index > 0 { Divider() }
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(segment.shade.color)
                        .frame(width: 14, height: 14)
                    Text(segment.name).fontWeight(segment.shade == .review ? .bold : .regular)
                    Spacer(minLength: 8)
                    Text("\(segment.count)").fontWeight(.bold)
                }
                .frame(minHeight: 50)
                .padding(.horizontal, 14)
            }
        }
        .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: Fleet

/// A bot on a card: who is on its Doing cards and who is working.
struct GlanceBot: Identifiable, Equatable {
    let id: String
    let name: String
    /// The bot's own avatar when this phone knows it; empty draws its monogram.
    let avatar: String
    let working: Bool
}

extension Fleet {
    /// The bots a card shows (§1): those on its Doing cards, looked up on the
    /// computers this phone talks to, then other working bots of the computer
    /// that answered; at most four.
    func glanceBots(_ card: HomeCard) -> [GlanceBot] {
        // From 0.20 the row lists its bots across computers (`overview_bots`).
        if !card.row.botList.isEmpty {
            return GlanceFleet.shown(card.row.botList).map { bot in
                GlanceBot(id: "\(bot.daemonID)/\(bot.botID)", name: bot.name, avatar: bot.avatar, working: bot.status == .working)
            }
        }
        var seen = Set<String>()
        var bots: [GlanceBot] = []
        func known(_ id: String) -> Bot? {
            guard !id.isEmpty else { return nil }
            for computer in computers { if let bot = computer.store.bot(id) { return bot } }
            return nil
        }
        for doing in card.row.doing {
            let key = doing.assigneeBotID.isEmpty ? doing.assigneeName : doing.assigneeBotID
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            let bot = known(doing.assigneeBotID)
            bots.append(GlanceBot(id: key, name: bot?.name ?? doing.assigneeName, avatar: bot?.avatar ?? "",
                                  working: bot.map { $0.state == .working || $0.state == .starting } ?? (card.row.botsWorking > 0)))
        }
        for bot in computer(id: card.computerId)?.store.bots ?? []
        where bot.projectId == card.row.projectID && bot.state == .working && !bot.temporary {
            guard seen.insert(bot.id).inserted else { continue }
            bots.append(GlanceBot(id: bot.id, name: bot.name, avatar: bot.avatar, working: true))
        }
        return Array(bots.prefix(4))
    }

    /// The project's lead, when the computer that answered knows it.
    func lead(of card: HomeCard) -> Bot? {
        guard let store = computer(id: card.computerId)?.store,
              let id = store.projects.first(where: { $0.id == card.row.projectID })?.leadBotId else { return nil }
        return store.bot(id)
    }

    /// Why an ask's screen can't open from here, or nil: it needs a computer
    /// the phone isn't connected to (§5). A note only explains, so it always opens.
    func unavailable(_ destination: NeedsDestination) -> String? {
        guard let id = destination.computerId, let computer = computer(id: id) else { return nil }
        switch computer.store.status {
        case .connected: return nil
        case .connecting: return "Connecting to \(computer.name)…"
        default: return "Not connected to \(computer.name)"
        }
    }
}

/// Working bots, ringed, overlapping a little.
struct FleetAvatars: View {
    let bots: [GlanceBot]

    var body: some View {
        HStack(spacing: -6) {
            ForEach(bots) { bot in
                AvatarView(avatar: bot.avatar, name: bot.name, size: 26)
                    .clipShape(Circle())
                    .padding(3)
                    .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
                    .overlay {
                        if bot.working { Circle().strokeBorder(Tone.working.color, lineWidth: 2) }
                    }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: The card

/// The top of a card: header, mini board, fleet, and a line when a computer
/// is away. Its asks follow it as rows of their own.
struct ProjectCardBody: View {
    let card: HomeCard
    var bots: [GlanceBot] = []
    @Environment(\.dynamicTypeSize) private var typeSize

    private var row: HomeRow { card.row }
    private var state: ProjectState { BoardGlance.state(card) }
    private var readOnly: Bool { state == .readOnly }
    private var segments: [BoardSegment] { MiniBoard.segments(row.columns) }
    private var large: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 12 : 10) {
            header
            board
            fleet
            if let offline = GlanceWords.offline(card) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "wifi.slash").font(.footnote.weight(.semibold)).foregroundStyle(Color.awayText)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(offline).font(.subheadline.weight(.semibold)).foregroundStyle(Color.awayText)
                        if let seen = GlanceWords.lastSeen(card, readOnly: readOnly) {
                            Text(seen).font(.footnote).foregroundStyle(Color.secondaryText)
                        }
                    }
                }
            }
            if row.legacy {
                Label("Update needed for full info", systemImage: "arrow.up.circle")
                    .font(.footnote).foregroundStyle(Color.secondaryText)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var header: some View {
        if large {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ProjectGlyph(name: row.name, seed: card.glyphSeed, size: 34)
                    name
                }
                StatePill(state: state)
            }
        } else {
            HStack(spacing: 10) {
                ProjectGlyph(name: row.name, seed: card.glyphSeed)
                name
                Spacer(minLength: 6)
                StatePill(state: state)
            }
        }
    }

    private var name: some View {
        HStack(spacing: 5) {
            Text(row.name).font(large ? .title2.bold() : .headline).lineLimit(2)
            if row.pinned {
                Image(systemName: "pin.fill").font(.caption).foregroundStyle(Color.secondaryText)
            }
        }
    }

    @ViewBuilder private var board: some View {
        if segments.isEmpty {
            if !row.legacy {
                VStack(alignment: .leading, spacing: 6) {
                    MiniBoardBar(segments: [])
                    Text("No board yet").font(.caption).foregroundStyle(Color.secondaryText)
                }
            }
        } else if large {
            MiniBoardRows(segments: segments)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                MiniBoardBar(segments: segments).opacity(readOnly ? 0.6 : 1)
                MiniBoardLegend(segments: segments)
            }
        }
    }

    @ViewBuilder private var fleet: some View {
        if large {
            Text(GlanceWords.fleetSentence(row, readOnly: readOnly)).font(.body).foregroundStyle(Color.secondaryText)
        } else {
            HStack(spacing: 8) {
                if !bots.isEmpty, !readOnly { FleetAvatars(bots: bots) }
                Text(GlanceWords.fleet(row, readOnly: readOnly)).font(.footnote).foregroundStyle(Color.secondaryText)
            }
        }
    }

    /// The card as VoiceOver reads it (§6): name, state, board, fleet, ask.
    static func spoken(_ card: HomeCard, ask: String?) -> String {
        let state = BoardGlance.state(card)
        let readOnly = state == .readOnly
        var parts = [card.row.name, state.spoken]
        if card.row.pinned { parts.append("Pinned") }
        if !card.row.columns.isEmpty || !card.row.legacy { parts.append(MiniBoard.spoken(MiniBoard.segments(card.row.columns))) }
        parts.append(GlanceWords.fleetSentence(card.row, readOnly: readOnly))
        if let offline = GlanceWords.offline(card) {
            parts.append([offline, GlanceWords.lastSeen(card, readOnly: readOnly)].compactMap { $0 }.joined(separator: ", "))
        }
        if let ask { parts.append(ask) }
        if card.row.legacy { parts.append("Update needed for full info") }
        return parts.joined(separator: ", ")
    }
}

/// An ask's one action, drawn in the row; the whole row is the button.
struct AskButtonLabel: View {
    let text: String
    var primary = false
    var enabled = true

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .foregroundStyle(enabled ? (primary ? Color.onAskButton : Color.primary) : Color.secondaryText)
            .background {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                if enabled {
                    shape.fill(primary ? Color.askButton : Color(.tertiarySystemFill))
                } else {
                    shape.strokeBorder(Color.secondaryText.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
    }
}

/// One thing that needs you, on its project's card: what it is, how long it
/// has waited, and its action. The most urgent one's action is filled.
struct AskRow: View {
    let row: HomeAttentionRow
    let action: String
    var primary = false
    /// Why the action waits, when it does.
    var unavailable: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text(row.displayTitle).font(.headline).foregroundStyle(row.tone.text)
                Text(row.needsSubtitle).font(.subheadline).foregroundStyle(Color.secondaryText)
                if let unavailable { Text(unavailable).font(.subheadline).foregroundStyle(Color.secondaryText) }
                AskButtonLabel(text: action, primary: primary, enabled: unavailable == nil)
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        } else {
            ItemRow(title: row.displayTitle, subtitle: row.needsSubtitle, detail: unavailable, titleLines: 2,
                    subtitleLines: row.permissionWords?.command == nil ? 1 : 2) {
                AskGlyph(row: row)
            } trailing: {
                AskButtonLabel(text: action, primary: primary, enabled: unavailable == nil)
            }
            .frame(minHeight: 50)
        }
    }
}

/// An ask's kind as a small round icon.
struct AskGlyph: View {
    let row: HomeAttentionRow

    var body: some View {
        Circle()
            .fill(row.tone.color.opacity(0.18))
            .frame(width: 26, height: 26)
            .overlay {
                Image(systemName: row.symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(row.tone.text)
            }
            .accessibilityHidden(true)
    }
}

/// A quiet project (§3): a slim row, its tile, name, cards and age. In the
/// iPad's strip of tiles the cards and age go under the name.
struct QuietRow: View {
    let card: HomeCard
    var stacked = false

    var body: some View {
        HStack(spacing: 12) {
            ProjectGlyph(name: card.row.name, seed: card.glyphSeed, size: 28)
            if stacked {
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.row.name).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(GlanceWords.quietMeta(card.row)).font(.caption).foregroundStyle(Color.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 4)
            } else {
                Text(card.row.name).font(.body.weight(.medium)).lineLimit(1)
                Spacer(minLength: 8)
                Text(GlanceWords.quietMeta(card.row)).font(.footnote).foregroundStyle(Color.secondaryText)
            }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.secondaryText)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// All · Needs you · Working · Quiet, each with its number.
struct FilterChips: View {
    @Binding var filter: HomeFilter
    let counts: [HomeFilter: Int]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(HomeFilter.allCases) { choice in
                    let on = choice == filter
                    let count = counts[choice] ?? 0
                    Button {
                        withAnimation(.snappy) { filter = choice }
                    } label: {
                        HStack(spacing: 5) {
                            Text(choice.title).fontWeight(.semibold)
                            Text("\(count)").opacity(0.8)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 34)
                        .foregroundStyle(on ? Color(.systemBackground) : Color.primary)
                        .background(on ? Color.primary : Color(.tertiarySystemFill), in: Capsule())
                        // 44 pt to tap, 34 pt to see.
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(choice.title), \(count)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .scrollClipDisabled()
    }
}

/// Dims on press, for buttons that are a whole row or card.
struct GlanceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .contentShape(Rectangle())
    }
}

/// The phone can't reach a computer whose projects it shows (§5): what it
/// last sent stays readable, and Retry tries now.
struct NotConnectedBanner: View {
    let computer: Computer
    let asOf: Date?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Not connected to \(computer.name)").font(.subheadline.weight(.semibold))
                Text(asOf.map { "Showing the tab as of \($0.formatted(date: .omitted, time: .shortened))" } ?? computer.store.status.label)
                    .font(.footnote).foregroundStyle(Color.secondaryText)
            }
            Spacer(minLength: 8)
            if computer.store.status == .connecting {
                ProgressView().controlSize(.small)
            } else if case .disconnected = computer.store.status {
                Button("Retry") { computer.store.client.reconnectNow() }
                    .buttonStyle(.bordered)
                    .fontWeight(.semibold)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// + on Projects and in the iPad sidebar: the New project sheet on the
/// computer on screen, then its first bot. (Phase 2 brings the guided flow.)
struct NewProjectButton: View {
    @Environment(Fleet.self) private var fleet
    var prominent = false
    @State private var creating: Creating?

    private enum Creating: Identifiable {
        case project(computerId: String)
        case bot(computerId: String, projectId: String)

        var id: String {
            switch self {
            case .project(let computer): "project/\(computer)"
            case .bot(let computer, let project): "bot/\(computer)/\(project)"
            }
        }
    }

    /// The computer on screen when it can take it, else any that can.
    private var computer: Computer? {
        let able = { (computer: Computer) in computer.store.status == .connected && computer.store.canControl }
        if let selected = fleet.selected, able(selected) { return selected }
        return fleet.computers.first(where: able)
    }

    var body: some View {
        Group {
            if prominent {
                Button { start() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("New project")
                    }
                    .fontWeight(.semibold)
                    .frame(minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button { start() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New project")
            }
        }
        .disabled(computer == nil)
        .accessibilityHint(computer == nil ? "Available when a computer is connected" : "")
        .sheet(item: $creating) { item in
            switch item {
            case .project(let id):
                if let computer = fleet.computer(id: id) {
                    NewProjectSheet { project, addBot in
                        creating = nil
                        Task { await fleet.home.refresh(computer, force: true) }
                        if addBot {
                            // Let the first sheet go before the next one comes up.
                            Task {
                                try? await Task.sleep(for: .milliseconds(450))
                                creating = .bot(computerId: id, projectId: project.id)
                            }
                        }
                    }
                    .computerEnvironment(computer)
                }
            case .bot(let id, let projectId):
                if let computer = fleet.computer(id: id) {
                    NewBotSheet(projectId: projectId) { _ in
                        creating = nil
                        Task { await fleet.home.refresh(computer, force: true) }
                    }
                    .computerEnvironment(computer)
                }
            }
        }
    }

    private func start() {
        if let computer { creating = .project(computerId: computer.id) }
    }
}
