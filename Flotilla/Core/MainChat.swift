import Foundation

/// Each bot's thread with the owner (H-128 D6): its messages and notes to the
/// owner, read on the bot's page. The main chat that listed them all was
/// replaced by Commands (0.24.0).

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

extension Array where Element == ThreadEntry {
    /// The bot's newest question still waiting for the owner.
    var openQuestion: ThreadEntry? { last { !$0.fromOwner && $0.asks && $0.open } }
}

extension AppStore {
    func ownerThreads() async throws -> [Flotilla_Home_V1_OwnerThread] {
        let reply = try await client.request("owner_threads")
        return try HomeJSON.decode(Flotilla_Home_V1_OwnerThreads.self, reply["owner_threads"]).threads
    }

    /// Marks the thread read up to `num`, so its unread count clears everywhere.
    func markThreadRead(botId: String, upTo num: Int64) async {
        _ = try? await client.request("owner_thread_read", ["bot_id": botId, "up_to_num": num])
        ownerThreadsVersion += 1
    }
}
