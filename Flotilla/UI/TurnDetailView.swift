import SwiftUI

/// One turn told in order: what came in, what the bot said and sent, and the
/// mechanical steps folded into groups between them.
struct TurnDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(LensStore.self) private var lens
    let botId: String
    let turnId: String
    @State private var turn: LensTurn?
    @State private var events: [LensEvent] = []
    @State private var error: String?

    private var blocks: [TurnBlock] { TurnBlock.blocks(events) }

    var body: some View {
        List {
            if let turn {
                header(turn)
                ForEach(blocks) { block in
                    switch block {
                    case .event(let event): EventRow(botId: botId, event: event)
                    case .steps(let steps):
                        StepGroup(botId: botId, steps: steps, expanded: steps.count <= 4)
                        let images = steps.flatMap { $0.images ?? [] }
                        if !images.isEmpty { ImageStrip(botId: botId, refs: images) }
                    }
                }
                if turn.open {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Working…").foregroundStyle(Color.secondaryText)
                    }
                }
            } else if let error {
                Text(error).foregroundStyle(Color.secondaryText)
            } else {
                ProgressView()
            }
        }
        .listStyle(.plain)
        .navigationTitle(store.bot(botId)?.name ?? turn?.botName ?? "Turn")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(for: StepLink.self) { StepDetailView(botId: $0.botId, event: $0.event) }
        .navigationDestination(for: LensArtifact.self) { ReportView(artifact: $0) }
        .task { await follow() }
        .refreshable { await load() }
    }

    private func header(_ turn: LensTurn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(turn.trigger.headline, systemImage: turn.trigger.symbol)
                .font(.subheadline.weight(.semibold))
            if let started = turn.started {
                Text(started.formatted(date: .abbreviated, time: .shortened)
                     + (turn.durationMs.map { " · took \(Self.duration($0))" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(Color.secondaryText)
            }
            if !turn.trigger.text.isEmpty {
                MarkdownText(turn.trigger.text)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if !turn.stats.line.isEmpty {
                Text(turn.stats.line).font(.caption).foregroundStyle(Color.secondaryText)
            }
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        do {
            let reply = try await lens.turn(bot: botId, id: turnId)
            turn = reply.turn
            events = reply.events
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Reload while the turn is still running.
    private func follow() async {
        await load()
        while !Task.isCancelled, turn?.open == true {
            try? await Task.sleep(for: .seconds(3))
            await load()
        }
    }

    static func duration(_ ms: Int) -> String {
        let seconds = ms / 1000
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h \(seconds % 3600 / 60) min"
    }
}

struct StepLink: Hashable {
    let botId: String
    let event: LensEvent
}

/// Consecutive tool steps collapse into one group; everything else stands alone.
enum TurnBlock: Identifiable {
    case event(LensEvent)
    case steps([LensEvent])

    var id: String {
        switch self {
        case .event(let event): event.id
        case .steps(let steps): "steps-\(steps.first?.id ?? "")"
        }
    }

    static func blocks(_ events: [LensEvent]) -> [TurnBlock] {
        var result: [TurnBlock] = []
        var run: [LensEvent] = []
        for event in events {
            if event.kind == "tool" {
                run.append(event)
                continue
            }
            if !run.isEmpty { result.append(.steps(run)); run = [] }
            result.append(.event(event))
        }
        if !run.isEmpty { result.append(.steps(run)) }
        return result
    }
}

/// A run of tool steps, summarised and folded when long.
struct StepGroup: View {
    let botId: String
    let steps: [LensEvent]
    @State var expanded: Bool
    /// Kept by the owner of the list instead (H-228), so it outlives the row.
    var isExpanded: Binding<Bool>? = nil
    /// Held open, e.g. while searching, so matches inside can be seen.
    var forceExpanded = false
    /// Marks the steps that match a search, and the one in view.
    var highlight: (String) -> Color? = { _ in nil }
    /// A prefix for each step's scroll id.
    var anchorPrefix = ""

    private var summary: String {
        let commands = steps.filter { $0.tool == "Bash" }.count
        let reads = steps.filter { $0.tool == "Read" }.count
        let edits = steps.filter { ["Edit", "Write", "MultiEdit"].contains($0.tool ?? "") }.count
        var parts: [String] = []
        if commands > 0 { parts.append("\(commands) command\(commands == 1 ? "" : "s")") }
        if edits > 0 { parts.append("\(edits) edit\(edits == 1 ? "" : "s")") }
        if reads > 0 { parts.append("\(reads) read\(reads == 1 ? "" : "s")") }
        let other = steps.count - commands - reads - edits
        if other > 0 { parts.append("\(other) other") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { forceExpanded || (isExpanded?.wrappedValue ?? expanded) },
                                            set: { if let isExpanded { isExpanded.wrappedValue = $0 } else { expanded = $0 } })) {
            ForEach(steps) { step in
                NavigationLink(value: StepLink(botId: botId, event: step)) { StepRow(step: step) }
                    .disabled(step.hasDetail != true)
                    .background(highlight(step.id) ?? .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .id(anchorPrefix + step.id)
            }
        } label: {
            HStack {
                Image(systemName: "gearshape.2").foregroundStyle(Color.secondaryText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(steps.count) step\(steps.count == 1 ? "" : "s")").font(.subheadline.weight(.medium))
                    Text(summary).font(.caption).foregroundStyle(Color.secondaryText)
                }
                if steps.contains(where: { !($0.images ?? []).isEmpty }) {
                Spacer()
                Image(systemName: "photo").foregroundStyle(Color.secondaryText)
            }
            if steps.contains(where: { $0.error == true }) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
    }
}

struct StepRow: View {
    let step: LensEvent

    static func symbol(_ tool: String?) -> String {
        switch tool ?? "" {
        case "Bash": "terminal"
        case "Read", "NotebookRead": "doc.text"
        case "Edit", "MultiEdit", "NotebookEdit": "pencil"
        case "Write": "doc.badge.plus"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Task", "Agent": "person.2"
        default: BusTool.isBus(tool ?? "") ? "point.3.connected.trianglepath.dotted" : "wrench.and.screwdriver"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Self.symbol(step.tool))
                .frame(width: 20)
                .foregroundStyle(step.error == true ? AnyShapeStyle(.orange) : AnyShapeStyle(Color.secondaryText))
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.subheadline)
                    .foregroundStyle(step.minor == true ? .secondary : .primary)
                    .lineLimit(2)
                if let subtitle = step.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption.monospaced()).foregroundStyle(Color.secondaryText).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if step.running == true { ProgressView().controlSize(.mini) }
            if let added = step.added, let removed = step.removed, added + removed > 0 {
                Text("+\(added) −\(removed)").font(.caption.monospaced()).foregroundStyle(Color.secondaryText)
            }
        }
    }
}

/// Messages in and out, replies and task results: the narrative of a turn.
struct EventRow: View {
    @Environment(LensStore.self) private var lens
    let botId: String
    let event: LensEvent

    var body: some View {
        switch event.kind {
        case "incoming" where event.from == nil:
            // From the daemon: a message that came in while the bot worked, already in words.
            bubble(label: "Came in while working", symbol: "arrow.down.left",
                   tint: .secondary, background: Color(.secondarySystemBackground))
        case "incoming":
            bubble(label: "From \(event.from ?? "") · \(event.msgKind ?? "")", symbol: "arrow.down.left",
                   tint: .secondary, background: Color(.secondarySystemBackground))
        case "sent":
            bubble(label: "To \(event.to ?? "") · \(event.msgKind ?? "")", symbol: "arrow.up.right",
                   tint: .accentColor, background: Color.accentColor.opacity(0.10))
        case "completed":
            VStack(alignment: .leading, spacing: 8) {
                bubble(label: "Task completed", symbol: "checkmark.seal.fill", tint: .successText, background: Color.green.opacity(0.10))
                ForEach(event.artifacts ?? [], id: \.self) { path in
                    if let report = lens.report(forPath: path) {
                        NavigationLink(value: LensArtifact(project: report.project, name: report.name,
                                                           title: report.name, size: 0, modifiedAt: "")) {
                            Label(report.name, systemImage: "doc.richtext")
                                .font(.footnote)
                                .lineLimit(1)
                        }
                    } else {
                        Label(path, systemImage: "doc").font(.caption.monospaced()).foregroundStyle(Color.secondaryText)
                    }
                }
            }
        case "compacted":
            Label("Memory compacted, the bot continued from a summary", systemImage: "arrow.down.right.and.arrow.up.left")
                .font(.caption)
                .foregroundStyle(Color.secondaryText)
        case "interrupted":
            Label(event.text?.isEmpty == false ? event.text! : "You interrupted the turn", systemImage: "stop.circle")
                .font(.caption)
                .foregroundStyle(Color.secondaryText)
        case "decision":
            if let id = event.decisionId {
                NavigationLink {
                    DecisionDetailView(decisionId: id)
                } label: {
                    decisionLabel
                }
            } else {
                decisionLabel
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                Label("Said", systemImage: "text.bubble").font(.caption.weight(.semibold)).foregroundStyle(Color.secondaryText)
                MarkdownText(event.text ?? "")
                if let images = event.images, !images.isEmpty { ImageStrip(botId: botId, refs: images, size: 70) }
            }
            .padding(.vertical, 4)
        }
    }

    private var decisionLabel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Asked you to decide", systemImage: "checklist").font(.caption.weight(.semibold)).foregroundStyle(.purple)
            Text(event.title).font(.subheadline)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func bubble(label: String, symbol: String, tint: Color, background: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(label, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(tint)
                Spacer()
                if let at = event.date { Text(at, style: .time).font(.caption2).foregroundStyle(Color.secondaryText) }
            }
            if let text = event.text, !text.isEmpty { MarkdownText(text) }
            if let images = event.images, !images.isEmpty { ImageStrip(botId: botId, refs: images, size: 70) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.vertical, 2)
    }
}
