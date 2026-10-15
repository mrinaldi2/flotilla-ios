import Foundation
import SwiftProtobuf

/// Card ids are links everywhere (H-204, UX-035): "H-293" in any text opens
/// that card, and a long-press previews it.

enum CardLinker {
    /// `flotilla://item/H-293`, inside the app and from outside it.
    static func url(_ id: String) -> URL { URL(string: "\(scheme)://item/\(id)")! }

    static let scheme = "flotilla"
    /// Also read: `hermes://item/…` (the app's own links, and the desktop's,
    /// before the rename) and `thehermes://item/…` (links from outside, then).
    static let schemes = [scheme, "hermes", "thehermes"]

    static func id(from url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), schemes.contains(scheme),
              url.host?.lowercased() == "item" else { return nil }
        let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return id.isEmpty ? nil : id
    }

    /// `PREFIX-n`, n of 1–5 digits, on word boundaries; an id followed by
    /// `-letter` is part of a name (`H-189-project-clicks`).
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_\-/.#])([A-Z][A-Z0-9]{0,9})-([0-9]{1,5})(?![0-9A-Za-z_])(?!-[A-Za-z])"#)

    /// Fenced code, inline code, links, autolinks and URLs: never rewritten
    /// (an inline code span that is exactly an id is handled apart).
    private static let protected = try! NSRegularExpression(
        pattern: #"(?s)(```.*?(?:```|$)|~~~.*?(?:~~~|$)|`[^`\n]*`|!?\[[^\]\n]*\]\([^)\n]*\)|<[^>\n]+>|https?://\S+)"#)

    /// The ids in `text` this computer knows, in order, each once.
    static func ids(in text: String, prefixes: Set<String>) -> [String] {
        var seen: [String] = []
        for piece in segments(text, prefixes: prefixes) {
            if case .id(let id, _) = piece, !seen.contains(id) { seen.append(id) }
        }
        return seen
    }

    /// Markdown with each known id as a link: `[H-293](flotilla://item/H-293)`.
    static func linked(_ markdown: String, prefixes: Set<String>) -> String {
        guard !prefixes.isEmpty else { return markdown }
        return segments(markdown, prefixes: prefixes).map { piece in
            switch piece {
            case .text(let text): text
            case .id(let id, let shown): "[\(shown)](\(url(id).absoluteString))"
            }
        }.joined()
    }

    private enum Segment {
        case text(String)
        /// `shown` keeps inline-code marks when the whole span was the id.
        case id(String, shown: String)
    }

    private static func segments(_ text: String, prefixes: Set<String>) -> [Segment] {
        guard !prefixes.isEmpty else { return [.text(text)] }
        let ns = text as NSString
        var out: [Segment] = []
        var cursor = 0
        func scan(_ range: NSRange) {
            var at = range.location
            for match in pattern.matches(in: text, range: range) {
                let prefix = ns.substring(with: match.range(at: 1))
                guard prefixes.contains(prefix) else { continue }
                if match.range.location > at {
                    out.append(.text(ns.substring(with: NSRange(location: at, length: match.range.location - at))))
                }
                let id = ns.substring(with: match.range)
                out.append(.id(id, shown: id))
                at = match.range.location + match.range.length
            }
            if at < range.location + range.length {
                out.append(.text(ns.substring(with: NSRange(location: at, length: range.location + range.length - at))))
            }
        }
        for region in protected.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if region.range.location > cursor { scan(NSRange(location: cursor, length: region.range.location - cursor)) }
            let raw = ns.substring(with: region.range)
            // Inline code is linked only when the whole span is the id.
            let inner = raw.count > 2 && raw.hasPrefix("`") && !raw.hasPrefix("```") ? String(raw.dropFirst().dropLast()) : nil
            if let inner, isId(inner, prefixes: prefixes) {
                out.append(.id(inner, shown: raw))
            } else {
                out.append(.text(raw))
            }
            cursor = region.range.location + region.range.length
        }
        if cursor < ns.length { scan(NSRange(location: cursor, length: ns.length - cursor)) }
        return out
    }

    static func isId(_ text: String, prefixes: Set<String>) -> Bool {
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let match = pattern.firstMatch(in: text, range: range), match.range == range else { return false }
        return prefixes.contains((text as NSString).substring(with: match.range(at: 1)))
    }

    /// "H" of "H-293".
    static func prefix(of id: String) -> String? {
        id.split(separator: "-").first.map(String.init)
    }
}

/// What a long-press shows for one card (UX-035 §3, §6).
struct CardPreview: Equatable {
    enum State: Equatable {
        case found
        /// The prefix is known, but no such card.
        case missing
        /// Kept on a computer that isn't connected; nil when its name isn't known.
        case offline(computer: String?, lastSeen: Date?)
        /// The service can't look cards up.
        case oldService(computer: String)
    }

    let id: String
    var state: State
    var type: String?
    var priority: String?
    var title: String?
    var column: String?
    var assignee: String?
    var blocked = false
    var release: String?
    var project: String?
    /// Set when the card belongs to another project than the one on screen.
    var otherProject: String?

    /// "H-293 · Bug · P0": priority only for P0/P1.
    var heading: String {
        var parts = [id]
        if let type { parts.append(type) }
        if let priority, priority == "P0" || priority == "P1" { parts.append(priority) }
        return parts.joined(separator: " · ")
    }

    /// "Doing · Desktop Dev"
    var placeLine: String? {
        guard state == .found else { return nil }
        return [column, assignee ?? "Unassigned"].compactMap { $0 }.joined(separator: " · ")
    }

    /// "⛔ Blocked · in 0.17.3"
    var flagsLine: String? {
        let parts = [blocked ? "⛔ Blocked" : nil, release.map { "in \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What to say instead of a card (§6 and §8); nil when the card was found.
    var notice: String? {
        let board = project.map { "\($0)'s board" } ?? "the board"
        switch state {
        case .found:
            return nil
        case .missing:
            return "\(id) isn't on \(board). It may have been deleted or mistyped."
        case .offline(let computer, let lastSeen):
            let cached = title.map { "\nLast seen as: \($0)" } ?? ""
            // A name we don't know: say so plainly (UX-037), never "its computer".
            guard let computer else { return "\(id) is on \(board), kept on another computer, which is offline.\(cached)" }
            let seen = lastSeen.map { " · last seen \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
            return "\(id) is on \(board), kept on \(computer). \(computer) is offline\(seen).\(cached)"
        case .oldService(let computer):
            return "Update the Flotilla service on \(computer) to see cards from here."
        }
    }

    /// A link from outside whose prefix no board here uses, or that waited too
    /// long for the projects (UX-044).
    static func unseen(_ id: String, device: String = "iPhone") -> String {
        "\(id) isn't on any board this \(device) can see. It may be mistyped, or kept on a computer this \(device) isn't linked to."
    }

    /// "H-293: <title>" for VoiceOver; "H-293, card" before the title is known.
    var accessibilityName: String { title.map { "\(id): \($0)" } ?? "\(id), card" }

    /// The card screen's facts, from the item itself (UX-037 follow-up).
    static func of(_ item: Hermes_Board_V1_Item, botName: (String) -> String?) -> CardPreview {
        var preview = CardPreview(id: item.id, state: .found)
        preview.title = item.title
        preview.type = words(item.type)
        preview.priority = words(item.priority)
        preview.column = Release.PlanItem.column(item.columnKey)
        preview.assignee = item.hasAssignee ? (botName(item.assignee) ?? "A bot") : nil
        preview.blocked = item.hasBlocked
        return preview
    }

    /// "Bug · P0", without the id: priority only for P0/P1.
    var kindLine: String? {
        let parts = [type, (priority == "P0" || priority == "P1") ? priority : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func words(_ type: Hermes_Board_V1_ItemType) -> String? {
        switch type {
        case .epic: "Epic"
        case .feature: "Feature"
        case .bug: "Bug"
        case .spike: "Spike"
        case .chore: "Chore"
        default: nil
        }
    }

    static func words(_ priority: Hermes_Board_V1_Priority) -> String? {
        switch priority {
        case .p0: "P0"
        case .p1: "P1"
        case .p2: "P2"
        case .p3: "P3"
        default: nil
        }
    }
}

/// Which projects' ids this phone knows, and the cards behind them, across
/// every computer (UX-035 §9).
@MainActor @Observable
final class CardDirectory {
    struct Home: Equatable {
        let computerId: String
        let projectId: String
        let projectName: String
    }

    /// "H" → the projects using it (two only when projects share a prefix).
    private(set) var homes: [String: [Home]] = [:]
    var prefixes: Set<String> { Set(homes.keys) }
    /// Every connected computer's projects were read when `homes` was learned, so
    /// an id whose prefix isn't there is unknown, not early (H-216).
    private(set) var settled = false

    enum Resolution: Equatable {
        case found(Home)
        /// No project uses its prefix.
        case unknown
        /// The projects are still loading: ask again when they have.
        case waiting
    }

    @ObservationIgnored private var snapshots: [String: (BoardSnapshot, Date)] = [:]
    @ObservationIgnored private var previews: [String: (CardPreview, Date)] = [:]
    /// Titles seen before, for the offline copy.
    @ObservationIgnored private var lastTitles: [String: String] = [:]
    private static let ttl: TimeInterval = 60

    /// Learns each project's prefix: from the projects list when the service
    /// sends it (`item_prefix`), else from its board's settings.
    func refresh(_ computers: [Computer]) async {
        var found: [String: [Home]] = [:]
        let connected = computers.filter { $0.store.status == .connected }
        let complete = !connected.isEmpty && connected.allSatisfy { $0.store.projectsLoaded }
        for computer in connected {
            let store = computer.store
            for project in store.projects where project.deletedAt == nil {
                var prefix = project.itemPrefix
                var others: [String] = []
                if prefix == nil, store.speaksProto, let snapshot = try? await snapshot(computer, projectId: project.id) {
                    prefix = snapshot.settings.key.isEmpty ? nil : snapshot.settings.key
                    others = snapshot.boards.map(\.key)
                }
                guard let prefix else { continue }
                let home = Home(computerId: computer.id, projectId: project.id, projectName: project.name)
                for key in Set([prefix] + others) where !key.isEmpty { found[key, default: []].append(home) }
            }
        }
        homes = found
        settled = complete
    }

    /// A project's other boards' prefixes (0.19), learned when its board is
    /// read, so their card ids link and open there too.
    func learn(prefixes: [String], home: Home) {
        for prefix in prefixes where !prefix.isEmpty {
            if homes[prefix]?.contains(home) == true { continue }
            homes[prefix, default: []].append(home)
        }
    }

    /// Where a link from outside goes: its project, nowhere, or not yet.
    func resolve(_ id: String) -> Resolution {
        if let home = home(for: id) { return .found(home) }
        return settled ? .unknown : .waiting
    }

    /// The project an id belongs to: the one on screen, else the bot's, else
    /// the first (UX-035 §1).
    func home(for id: String, preferring projectIds: [String] = []) -> Home? {
        guard let prefix = CardLinker.prefix(of: id), let options = homes[prefix] else { return nil }
        for wanted in projectIds { if let home = options.first(where: { $0.projectId == wanted }) { return home } }
        return options.first
    }

    #if DEBUG
    func setForTests(_ homes: [String: [Home]], settled: Bool = true) {
        self.homes = homes
        self.settled = settled
    }
    #endif

    func cached(_ id: String) -> CardPreview? {
        guard let (preview, at) = previews[id], Date().timeIntervalSince(at) < Self.ttl else { return nil }
        return preview
    }

    /// The preview for one id, cached for 60 s.
    func preview(_ id: String, fleet: Fleet, preferring projectIds: [String] = []) async -> CardPreview {
        if let cached = cached(id) { return cached }
        let preview = await look(id, fleet: fleet, preferring: projectIds)
        previews[id] = (preview, Date())
        if let title = preview.title { lastTitles[id] = title }
        return preview
    }

    private func look(_ id: String, fleet: Fleet, preferring projectIds: [String]) async -> CardPreview {
        guard let home = home(for: id, preferring: projectIds) else { return CardPreview(id: id, state: .missing) }
        var base = CardPreview(id: id, state: .found, project: home.projectName)
        if let wanted = projectIds.first, wanted != home.projectId { base.otherProject = home.projectName }
        guard let computer = fleet.computer(id: home.computerId), computer.store.status == .connected else {
            base.state = .offline(computer: fleet.computer(id: home.computerId)?.name, lastSeen: nil)
            base.title = lastTitles[id]
            return base
        }
        let store = computer.store
        if store.capabilities.contains("item_cards"), let card = try? await store.itemCards([id]).first {
            return card.preview(base, botName: { store.bot($0)?.name })
        }
        guard store.speaksProto else {
            base.state = .oldService(computer: computer.name)
            return base
        }
        if let snapshot = try? await snapshot(computer, projectId: home.projectId),
           let card = snapshot.cards.first(where: { $0.id == id }) {
            let column = snapshot.columns.first { $0.key == card.columnKey }?.name
            return Self.fill(base, card: card, column: column, botName: { store.bot($0)?.name })
        }
        do {
            let detail = try await store.item(id)
            let item = detail.item
            base.title = item.title
            base.type = CardPreview.words(item.type)
            base.priority = CardPreview.words(item.priority)
            base.column = Release.PlanItem.column(item.columnKey)
            base.assignee = item.hasAssignee ? (store.bot(item.assignee)?.name ?? "A bot") : nil
            base.blocked = item.hasBlocked
            return base
        } catch let error as DaemonError where error.code == "not_found" || error.code == "unknown_item" {
            base.state = .missing
            return base
        } catch {
            base.state = .missing
            return base
        }
    }

    nonisolated static func fill(_ base: CardPreview, card: Hermes_Board_V1_ItemCard, column: String?,
                     botName: (String) -> String?) -> CardPreview {
        var preview = base
        preview.title = card.title
        preview.type = CardPreview.words(card.type)
        preview.priority = CardPreview.words(card.priority)
        preview.column = column ?? Release.PlanItem.column(card.columnKey)
        preview.assignee = card.hasAssignee ? (botName(card.assignee) ?? "A bot") : nil
        preview.blocked = card.blocked
        return preview
    }

    private func snapshot(_ computer: Computer, projectId: String) async throws -> BoardSnapshot {
        let key = "\(computer.id)/\(projectId)"
        if let (snapshot, at) = snapshots[key], Date().timeIntervalSince(at) < Self.ttl { return snapshot }
        let snapshot = try await computer.store.board(projectId: projectId)
        snapshots[key] = (snapshot, Date())
        return snapshot
    }
}

/// One answer of `item_cards_get` (H-203). Decoded loosely: the service's
/// final shape may add fields.
struct ItemCardAnswer {
    let id: String
    let projectName: String?
    let computer: String?
    let card: Hermes_Board_V1_ItemCard?
    let columnName: String?
    let release: String?
    let missing: Bool
    let unreachable: (computer: String?, lastSeen: Date?)?

    init(_ d: JSONDict) {
        id = d.str("id")
        projectName = d.optStr("project_name")
        computer = d.optStr("computer")
        card = d.dict("card").flatMap { try? HomeJSON.decode(Hermes_Board_V1_ItemCard.self, $0) }
        columnName = d.optStr("column_name")
        release = d.optStr("release")
        missing = d.bool("missing")
        unreachable = d.dict("unreachable").map { ($0.optStr("computer"), $0.date("last_seen")) }
    }

    func preview(_ base: CardPreview, botName: (String) -> String?) -> CardPreview {
        var preview = base
        if let projectName { preview.project = projectName }
        if missing { preview.state = .missing; return preview }
        if let unreachable { preview.state = .offline(computer: unreachable.computer, lastSeen: unreachable.lastSeen); return preview }
        guard let card else { preview.state = .missing; return preview }
        preview = CardDirectory.fill(preview, card: card, column: columnName, botName: botName)
        preview.release = release
        return preview
    }
}

extension AppStore {
    /// Batch lookup (capability `item_cards`, H-203).
    func itemCards(_ ids: [String]) async throws -> [ItemCardAnswer] {
        let reply = try await client.request("item_cards_get", ["ids": ids])
        return reply.list("cards").map(ItemCardAnswer.init)
    }
}
