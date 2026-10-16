import Foundation

/// The main chat (UX-024, H-128 D6): one thread per bot holding the owner's
/// messages and the bot's notes to the owner, on every computer.

/// One bot's thread as the list shows it, merged across computers.
struct ThreadCard: Identifiable, Equatable {
    /// The computer to read and write the thread on.
    let computerId: String
    let botId: String
    let botName: String
    let projectId: String
    var last: String
    var lastFromOwner: Bool
    let at: Date?
    let unread: Int
    let openQuestion: Bool
    /// The bot's own computer and id, which a stand-in on another computer shares.
    let origin: String

    var id: String { origin }

    init(_ thread: Hermes_Home_V1_OwnerThread, computerId: String) {
        self.computerId = computerId
        botId = thread.bot.botID
        botName = thread.bot.name
        projectId = thread.projectID
        last = OwnerText.preview(thread.last.text)
        lastFromOwner = thread.last.fromOwner
        at = thread.last.hasAt ? thread.last.at.date : nil
        unread = Int(thread.unread)
        openQuestion = thread.openQuestion
        origin = thread.bot.daemonID.isEmpty ? "\(computerId)/\(thread.bot.botID)" : "\(thread.bot.daemonID)/\(thread.bot.botID)"
    }
}

/// What a thread message says, as people read it (QA-004): no Markdown marks,
/// and no bus envelope ("[decision 37bce901-… from USER · settled · re "…"]").
enum OwnerText {
    private static let envelopeKinds: Set<String> = ["decision", "msg", "task", "note", "reply", "done", "release"]

    /// The text without a leading bus envelope. When the daemon cut the text
    /// inside the envelope, what it is about ("Ruling on “Ship 0.17?”").
    static func stripEnvelope(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[") else { return text }
        let words = trimmed.dropFirst().split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard words.count >= 2, envelopeKinds.contains(String(words[0])),
              words[1].allSatisfy({ $0.isHexDigit || $0 == "-" || $0 == "…" }) else { return text }
        let close = trimmed.firstIndex(of: "]")
        let header = close.map { String(trimmed[..<$0]) } ?? trimmed
        let body = close.map { String(trimmed[trimmed.index(after: $0)...]) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !body.isEmpty { return body }
        let about = header.range(of: "re \"").map { range -> String in
            let rest = header[range.upperBound...]
            return String(rest.prefix { $0 != "\"" })
        }
        let kind = String(words[0])
        guard let about, !about.isEmpty else { return kind == "decision" ? "A ruling" : kind.capitalizedFirst }
        return kind == "decision" ? "Ruling on “\(about)”" : "\(kind.capitalizedFirst): \(about)"
    }

    /// Inline Markdown rendered (bold, italics, code, links); the envelope stripped.
    static func rich(_ text: String) -> AttributedString {
        let clean = stripEnvelope(text)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: clean, options: options)) ?? AttributedString(clean)
    }

    /// One line of plain text, for a thread row.
    static func preview(_ text: String) -> String {
        String(rich(text).characters)
            .split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

extension ThreadCard {
    /// With an open question, the row previews that question, not the newest
    /// message (UX-031).
    mutating func preview(question: ThreadEntry?) {
        guard openQuestion, let question else { return }
        last = OwnerText.preview(question.text)
        lastFromOwner = false
    }
}

extension Array where Element == ThreadEntry {
    /// The bot's newest question still waiting for the owner.
    var openQuestion: ThreadEntry? { last { !$0.fromOwner && $0.asks && $0.open } }
}

enum ThreadWords {
    /// "Asks you · 2m ago" above a bot's question in its thread.
    static func asks(_ at: Date?) -> String { at.map { "Asks you · \($0.relative)" } ?? "Asks you" }
}

enum ThreadMerge {
    /// One card per bot with a conversation (UX-031: ✎ reaches the rest). A
    /// linked bot's thread is listed by every computer that shows it; the one
    /// read on the bot's own computer wins (BotRef). Newest first.
    static func merge(_ lists: [(computerId: String, daemonId: String?, threads: [Hermes_Home_V1_OwnerThread])]) -> [ThreadCard] {
        var byOrigin: [String: (card: ThreadCard, own: Bool)] = [:]
        for list in lists {
            for thread in list.threads where thread.hasLast && (thread.last.num > 0 || !thread.last.text.isEmpty) {
                let card = ThreadCard(thread, computerId: list.computerId)
                let own = list.daemonId != nil && list.daemonId == thread.bot.daemonID
                if let kept = byOrigin[card.origin], kept.own || !own { continue }
                byOrigin[card.origin] = (card, own)
            }
        }
        return byOrigin.values.map(\.card).sorted { a, b in
            if a.at != b.at { return (a.at ?? .distantPast) > (b.at ?? .distantPast) }
            return a.botName.localizedCaseInsensitiveCompare(b.botName) == .orderedAscending
        }
    }
}

extension AppStore {
    func ownerThreads() async throws -> [Hermes_Home_V1_OwnerThread] {
        let reply = try await client.request("owner_threads")
        return try HomeJSON.decode(Hermes_Home_V1_OwnerThreads.self, reply["owner_threads"]).threads
    }

    /// Marks the thread read up to `num`, so its unread count clears everywhere.
    func markThreadRead(botId: String, upTo num: Int64) async {
        _ = try? await client.request("owner_thread_read", ["bot_id": botId, "up_to_num": num])
        ownerThreadsVersion += 1
    }
}
