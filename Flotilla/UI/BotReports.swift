import SwiftUI

/// A bot opens on what it reported (UX-024): its latest note to you, the
/// questions it asked, and what it is doing. Owner threads (H-128 D6) hold
/// the reports; an older daemon shows the bot's latest activity instead.
struct BotReportsPane: View {
    @Environment(AppStore.self) private var store
    @Environment(LensStore.self) private var lens
    @Environment(Fleet.self) private var fleet
    let botId: String
    /// Opens the bot's chat, to answer it.
    let openChat: () -> Void
    @State private var entries: [ThreadEntry]?
    @State private var failure: String?

    private var bot: Bot? { store.bot(botId) }
    private var reports: [ThreadEntry] { (entries ?? []).filter { !$0.fromOwner }.reversed() }
    /// Each of the bot's messages shows once (QA-004): open questions under
    /// Sent to you, the newest other one as the latest report, the rest earlier.
    private var sections: ReportSections { ReportSections(reports) }
    private var questions: [ThreadEntry] { sections.questions }

    var body: some View {
        List {
            if store.hasOwnerThreads {
                if let latest = sections.latest {
                    Section {
                        LinkedText(markdown: OwnerText.stripEnvelope(latest.text))
                    } header: {
                        SectionTitle(latest.at.map { "Latest report · \($0.relative)" } ?? "Latest report")
                    }
                }
                if !questions.isEmpty {
                    Section {
                        ForEach(questions) { question in
                            VStack(alignment: .leading, spacing: 6) {
                                LinkedText(markdown: OwnerText.stripEnvelope(question.text), lineLimit: 4)
                                Button("Answer in Chat", action: openChat).font(.subheadline.weight(.semibold))
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        SectionTitle("Sent to you", count: questions.count)
                    }
                }
            }
            Section {
                if let doing = doingNow {
                    Text(doing).font(.callout)
                } else {
                    // The state is in the header pill; this says what it is working on (UX-031).
                    Text("No current item").foregroundStyle(Color.secondaryText)
                }
            } header: {
                SectionTitle("Doing now")
            }
            if store.hasOwnerThreads, !sections.earlier.isEmpty {
                Section {
                    ForEach(sections.earlier.prefix(10)) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            LinkedText(markdown: OwnerText.stripEnvelope(entry.text), lineLimit: 5)
                            if let at = entry.at { Text(at.relative).font(.caption2).foregroundStyle(Color.secondaryText) }
                        }
                    }
                } header: {
                    SectionTitle("Earlier reports")
                }
            }
            if store.hasOwnerThreads, entries?.isEmpty == true || (entries != nil && reports.isEmpty) {
                EmptyNote(text: "\(bot?.name ?? "This bot") hasn't reported to you yet.", systemImage: "text.quote")
            }
            if !store.hasOwnerThreads {
                Text("Reports come from The Hermes 0.17 on \(store.computerName). Until then, this shows what the bot is doing.")
                    .font(.footnote).foregroundStyle(Color.secondaryText)
            }
            if let failure {
                Text(failure).font(.footnote).foregroundStyle(Color.errorText)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
        .task { await load() }
        .reloadsOnReconnect { await load() }
    }

    /// The bot's current step, else its latest word; never a message already
    /// shown above.
    private var doingNow: String? {
        var line: String?
        if let turn = lens.latest[botId], turn.open, !turn.current.isEmpty {
            line = turn.current
        } else if let activity = store.activity[botId], !activity.text.isEmpty {
            line = activity.text
        } else if let outcome = lens.latest[botId]?.outcome, outcome.kind != "none", !outcome.text.isEmpty {
            line = outcome.text
        }
        guard let line, !sections.shows(line) else { return nil }
        return line
    }

    private func load() async {
        guard store.hasOwnerThreads else { return }
        do {
            entries = try await store.ownerThread(botId: botId)
            failure = nil
        } catch {
            failure = "Couldn’t load the reports. \(error.localizedDescription)"
        }
    }
}

/// A bot's messages to the owner, newest first, split so none repeats.
struct ReportSections {
    let latest: ThreadEntry?
    let questions: [ThreadEntry]
    let earlier: [ThreadEntry]

    init(_ reports: [ThreadEntry]) {
        questions = reports.filter { $0.asks && $0.open }
        let others = reports.filter { !($0.asks && $0.open) }
        latest = others.first
        earlier = Array(others.dropFirst())
    }

    /// Whether `text` repeats a message already on screen (the bot's activity
    /// line is often its last message, maybe cut).
    func shows(_ text: String) -> Bool {
        let line = Self.key(text)
        guard !line.isEmpty else { return false }
        return ([latest].compactMap { $0 } + questions).contains { entry in
            let shown = Self.key(entry.text)
            return shown == line || shown.hasPrefix(line) || line.hasPrefix(shown)
        }
    }

    private static func key(_ text: String) -> String {
        OwnerText.preview(text).trimmingCharacters(in: CharacterSet(charactersIn: "…. ")).lowercased()
    }
}
