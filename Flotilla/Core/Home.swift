import Foundation
import Observation
import SwiftProtobuf

// The projects home (H-128 rev 2): every project on every computer, ranked
// by how much it needs the owner, from `hermes.home.v1`. Each computer
// answers for its projects and its linked peers; the phone merges the
// computers it talks to and keeps the last answer on disk, so the home
// shows at once and refreshes behind it.

typealias HomeOverview = Hermes_Home_V1_ProjectsOverview
typealias HomeRow = Hermes_Home_V1_ProjectRow
typealias HomeAttentionRow = Hermes_Home_V1_AttentionRow
typealias HomeAttentionKind = Hermes_Home_V1_AttentionKind

/// Proto3 JSON as the daemon sends it on the JSON WS: the proto field names,
/// enum names, RFC 3339 times. Unknown fields from a newer daemon are kept out.
enum HomeJSON {
    static let options: JSONDecodingOptions = {
        var options = JSONDecodingOptions()
        options.ignoreUnknownFields = true
        return options
    }()

    static func decode<M: SwiftProtobuf.Message>(_ type: M.Type, _ value: Any?) throws -> M {
        guard let value, JSONSerialization.isValidJSONObject(value) else {
            throw DaemonError(code: "decode", message: "The Hermes service sent an unreadable \(M.protoMessageName).")
        }
        return try M(jsonUTF8Data: JSONSerialization.data(withJSONObject: value), options: options)
    }
}

extension AppStore {
    /// The daemon serves the projects home (`projects_overview`, `attention_rows`).
    var hasHome: Bool { capabilities.contains("projects_overview") }
    var canPin: Bool { capabilities.contains("project_pin") && canControl }

    func projectsOverview() async throws -> HomeOverview {
        let reply = try await client.request("projects_overview")
        return try HomeJSON.decode(HomeOverview.self, reply["overview"])
    }

    func attentionRows(projectId: String) async throws -> [HomeAttentionRow] {
        let reply = try await client.request("attention_rows", ["project_id": projectId])
        return try HomeJSON.decode(Hermes_Home_V1_AttentionRows.self, reply["attention_rows"]).rows
    }

    func pinProject(_ projectId: String, pinned: Bool) async throws {
        _ = try await client.request("project_pin", ["project_id": projectId, "pinned": pinned])
    }

    /// For a daemon without `projects_overview` (R2.1): a basic row per
    /// project, built from what the phone already has, ranked by its count.
    func legacyRows() -> [HomeRow] {
        projects.map { project in
            let bots = bots(in: project)
            let ids = Set(bots.map(\.id))
            let decisions = self.decisions.filter { $0.projectId == project.id && $0.state == "open" }.count
            let prompts = permissions.filter { ids.contains($0.botId) }.count
            let waiting = approvals.keys.filter(ids.contains).count
            var row = HomeRow()
            row.projectID = project.id
            row.name = project.name
            var member = Hermes_Home_V1_Member()
            member.daemonID = daemonId ?? ""
            member.projectID = project.id
            member.computerName = computerName
            row.members = daemonId == nil ? [] : [member]
            row.bots = UInt32(bots.count)
            row.botsWorking = UInt32(bots.filter { $0.state == .working || $0.state == .starting }.count)
            row.botsWaiting = UInt32(bots.filter(\.state.needsOwner).count)
            row.attention.count = UInt32(decisions + prompts + waiting)
            row.attention.score = UInt32(decisions + prompts + waiting)
            if decisions > 0 { row.attention.byKind["decision"] = UInt32(decisions) }
            if prompts > 0 { row.attention.byKind["permission_prompt"] = UInt32(prompts) }
            if waiting > 0 { row.attention.byKind["bot_waiting"] = UInt32(waiting) }
            row.legacy = true
            return row
        }
    }

    /// The Needs-you rows an older daemon can give: its open decisions, waiting
    /// permission prompts and bots waiting on their own terminal's approval
    /// (`approval_pending`, listed on 0.4.x Home; QA-004), for one project.
    func legacyAttention(projectId: String) -> [HomeAttentionRow] {
        let daemon = daemonId ?? ""
        let ids = Set(bots.filter { $0.projectId == projectId }.map(\.id))
        var rows: [HomeAttentionRow] = []
        for decision in decisions where decision.projectId == projectId && decision.state == "open" {
            var row = HomeAttentionRow()
            row.id = "decision:\(daemon):\(decision.id)"
            row.kind = .decision
            row.daemonID = daemon
            row.projectID = projectId
            row.title = decision.title
            row.decisionID = decision.id
            row.priority = decision.priority
            row.weight = decision.urgent ? 3 : 1
            if let created = decision.createdAt { row.createdAt = Google_Protobuf_Timestamp(date: created) }
            rows.append(row)
        }
        for request in permissions where ids.contains(request.botId) {
            var row = HomeAttentionRow()
            row.id = "permission_prompt:\(daemon):\(request.id)"
            row.kind = .permissionPrompt
            row.daemonID = daemon
            row.projectID = projectId
            row.title = "\(bot(request.botId)?.name ?? "A bot") wants to run \(request.toolName)"
            row.requestID = request.id
            row.weight = 3
            if let created = request.createdAt { row.createdAt = Google_Protobuf_Timestamp(date: created) }
            rows.append(row)
        }
        for (botId, line) in approvals where ids.contains(botId) {
            var row = HomeAttentionRow()
            row.id = "bot_waiting:\(daemon):\(botId)"
            row.kind = .botWaiting
            row.daemonID = daemon
            row.projectID = projectId
            // "Backend Dev wants to run Bash", never the engine's detail.
            let name = bot(botId)?.name ?? "A bot"
            row.title = line.hasPrefix("Wants") ? "\(name) w\(line.dropFirst())" : "\(name) needs approval"
            var ref = Hermes_Home_V1_BotRef()
            ref.daemonID = daemon
            ref.botID = botId
            ref.name = name
            row.bot = ref
            row.weight = 2
            rows.append(row)
        }
        return rows.sorted { ($0.weight, $1.createdAt.date) > ($1.weight, $0.createdAt.date) }
    }
}

/// One project on the home: the best row among the computers that answered
/// for it, and the computer that answered.
struct HomeCard: Identifiable {
    let row: HomeRow
    let computerId: String
    /// Names of the computers this row has no fresh answer from.
    let staleNames: [String]
    /// The oldest `as_of` among them, for "imac away · as of 10:42".
    let staleSince: Date?
    /// "#1, #2…" across every computer, after the merge; nil when nothing
    /// needs you here. (`row.rank` is one computer's own order.)
    var rank: Int?
    var id: String { "\(computerId):\(row.projectID)" }
}

enum HomeMerge {
    /// One row per project across the phone's computers (H-128 §2.3): rows
    /// whose members overlap are the same project; the one with the fewest
    /// stale sources wins, ties going to the board's home, then a full row
    /// over an older daemon's. A merged row is pinned if any was.
    static func merge(_ inputs: [(computerId: String, daemonId: String?, row: HomeRow)]) -> [(computerId: String, row: HomeRow)] {
        var groups: [(keys: Set<String>, items: [(computerId: String, daemonId: String?, row: HomeRow)])] = []
        for input in inputs {
            var keys = Set(input.row.members.map { "\($0.daemonID)/\($0.projectID)" })
            if keys.isEmpty { keys = ["\(input.computerId)/\(input.row.projectID)"] }
            if let index = groups.firstIndex(where: { !$0.keys.isDisjoint(with: keys) }) {
                groups[index].keys.formUnion(keys)
                groups[index].items.append(input)
            } else {
                groups.append((keys, [input]))
            }
        }
        return groups.map { group in
            let best = group.items.min { a, b in
                let ka = (a.row.staleSources.count, a.daemonId == a.row.boardHome ? 0 : 1, a.row.legacy ? 1 : 0)
                let kb = (b.row.staleSources.count, b.daemonId == b.row.boardHome ? 0 : 1, b.row.legacy ? 1 : 0)
                return ka < kb
            }!
            var row = best.row
            row.pinned = group.items.contains { $0.row.pinned }
            return (best.computerId, row)
        }
    }

    /// The server's order (R2.1): pinned first, then score, the oldest thing
    /// waiting, the latest activity, the name.
    static func ranked(_ rows: [(computerId: String, row: HomeRow)]) -> [(computerId: String, row: HomeRow)] {
        rows.sorted { a, b in
            if a.row.pinned != b.row.pinned { return a.row.pinned }
            if a.row.attention.score != b.row.attention.score { return a.row.attention.score > b.row.attention.score }
            let ao = a.row.attention.hasOldestAt ? a.row.attention.oldestAt.date : .distantFuture
            let bo = b.row.attention.hasOldestAt ? b.row.attention.oldestAt.date : .distantFuture
            if ao != bo { return ao < bo }
            let al = a.row.hasLastActivityAt ? a.row.lastActivityAt.date : .distantPast
            let bl = b.row.hasLastActivityAt ? b.row.lastActivityAt.date : .distantPast
            if al != bl { return al > bl }
            return a.row.name.localizedStandardCompare(b.row.name) == .orderedAscending
        }
    }
}

/// The projects home and Needs you across every computer, cache-first.
@MainActor
@Observable
final class HomeFeed {
    /// Each computer's last overview, by computer id.
    private(set) var overviews: [String: HomeOverview] = [:]
    /// Needs-you rows by card id.
    private(set) var attention: [String: [HomeAttentionRow]] = [:]
    private(set) var failures: [String: String] = [:]
    /// A card id the Needs you tab should show: set by "See all in Needs you".
    var needsFocus: String?
    @ObservationIgnored private var lastFetch: [String: Date] = [:]
    @ObservationIgnored private var pending: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let cacheDirectory: URL?

    /// The shortest wait between two fetches from one computer.
    static let minimumInterval: TimeInterval = 2

    init(cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("home", isDirectory: true)) {
        self.cacheDirectory = cacheDirectory
    }

    // MARK: Cards

    func cards(_ computers: [Computer]) -> [HomeCard] {
        var inputs: [(computerId: String, daemonId: String?, row: HomeRow)] = []
        var sources: [String: [Hermes_Home_V1_Source]] = [:]
        for computer in computers {
            if let overview = overviews[computer.id] {
                sources[computer.id] = overview.sources
                inputs += overview.rows.map { (computer.id, computer.store.daemonId, $0) }
            } else if computer.store.status == .connected, !computer.store.hasHome {
                inputs += computer.store.legacyRows().map { (computer.id, computer.store.daemonId, $0) }
            }
        }
        var next = 1
        return HomeMerge.ranked(HomeMerge.merge(inputs)).map { item in
            let stale = (sources[item.computerId] ?? []).filter { item.row.staleSources.contains($0.daemonID) }
            let since = stale.compactMap { $0.hasAsOf ? $0.asOf.date : nil }.min()
            var card = HomeCard(row: item.row, computerId: item.computerId, staleNames: stale.map(\.name), staleSince: since)
            if item.row.attention.count > 0 {
                card.rank = next
                next += 1
            }
            return card
        }
    }

    /// Bots' questions waiting for you, across projects: the Chat badge (UX-029).
    func questions(_ computers: [Computer]) -> Int {
        cards(computers).reduce(0) { $0 + Int($1.row.attention.byKind["owner_question"] ?? 0) }
    }

    /// Everything waiting, across projects: the app badge.
    func total(_ computers: [Computer]) -> Int {
        cards(computers).reduce(0) { $0 + Int($1.row.attention.count) }
    }

    // MARK: Fetching

    /// Shows the last overview each computer gave, before any network.
    func loadCache(_ computers: [Computer]) {
        guard let cacheDirectory else { return }
        for computer in computers where overviews[computer.id] == nil {
            let file = cacheDirectory.appendingPathComponent("\(computer.id).pb")
            if let data = try? Data(contentsOf: file), let overview = try? HomeOverview(serializedBytes: data) {
                overviews[computer.id] = overview
            }
        }
    }

    #if DEBUG
    /// Screenshots without a 0.17 daemon: `-homeFixture <path to overview.json>`
    /// stands in for the first computer's answer.
    func loadFixture(_ computers: [Computer]) {
        guard let path = UserDefaults.standard.string(forKey: "homeFixture"), let first = computers.first,
              let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data),
              let overview = try? HomeJSON.decode(HomeOverview.self, json) else { return }
        overviews[first.id] = overview
        fixtureComputer = first.id
    }

    @ObservationIgnored private var fixtureComputer: String?
    #endif

    func refreshAll(_ computers: [Computer], force: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            for computer in computers { group.addTask { await self.refresh(computer, force: force) } }
        }
    }

    /// One computer's overview, unless it was fetched a moment ago.
    func refresh(_ computer: Computer, force: Bool = false) async {
        let store = computer.store
        #if DEBUG
        if fixtureComputer == computer.id { return }
        #endif
        guard store.status == .connected else { return }
        guard store.hasHome else {
            // An older daemon: its cards come from the store; drop a stale cache.
            overviews[computer.id] = nil
            return
        }
        if !force, let last = lastFetch[computer.id], Date().timeIntervalSince(last) < Self.minimumInterval { return }
        lastFetch[computer.id] = Date()
        do {
            let overview = try await store.projectsOverview()
            overviews[computer.id] = overview
            failures[computer.id] = nil
            save(overview, for: computer.id)
        } catch {
            failures[computer.id] = error.localizedDescription
        }
    }

    /// A push said rows changed: refetch soon, once for a burst.
    func changed(_ computer: Computer) {
        guard pending[computer.id] == nil else { return }
        pending[computer.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.minimumInterval))
            guard let self else { return }
            self.pending[computer.id] = nil
            await self.refresh(computer, force: true)
        }
    }

    func forget(_ computerId: String) {
        overviews[computerId] = nil
        if let cacheDirectory { try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent("\(computerId).pb")) }
    }

    /// The Needs-you rows for one card, from the computer that answered for it.
    func loadAttention(_ card: HomeCard, on computer: Computer) async {
        let store = computer.store
        if card.row.legacy || !store.hasHome {
            attention[card.id] = store.legacyAttention(projectId: card.row.projectID)
            return
        }
        guard card.row.attention.count > 0 else {
            attention[card.id] = []
            return
        }
        if let rows = try? await store.attentionRows(projectId: card.row.projectID) {
            attention[card.id] = rows
        }
    }

    private func save(_ overview: HomeOverview, for computerId: String) {
        guard let cacheDirectory, let data: Data = try? overview.serializedData() else { return }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cacheDirectory.appendingPathComponent("\(computerId).pb"), options: .atomic)
    }
}

/// How the home says what is waiting, most pressing first: "1 release to
/// test · 2 decisions · 1 Run card".
enum AttentionWords {
    private static let order: [(String, String, String)] = [
        ("release_awaiting", "release to test", "releases to test"),
        ("owner_action", "Run card", "Run cards"),
        ("decision", "decision", "decisions"),
        ("permission_prompt", "permission request", "permission requests"),
        ("p0_item", "P0 item", "P0 items"),
        ("owner_question", "question", "questions"),
        ("relayed_rulings", "ruling to confirm", "rulings to confirm"),
        ("bot_waiting", "bot waiting", "bots waiting"),
        ("off_board", "bot off the board", "bots off the board"),
        ("serving_off", "computer not serving", "computers not serving"),
    ]

    static func summary(_ attention: Hermes_Home_V1_AttentionSummary, limit: Int = 3) -> String {
        guard attention.count > 0 else { return "Nothing needs you" }
        let parts = order.compactMap { key, one, many -> String? in
            guard let n = attention.byKind[key], n > 0 else { return nil }
            return "\(n) \(n == 1 ? one : many)"
        }
        return parts.isEmpty ? "\(attention.count) need\(attention.count == 1 ? "s" : "") you" : parts.prefix(limit).joined(separator: " · ")
    }
}

extension AppStore {
    /// `attention_dismiss` (approve grant): a stale question leaves Needs you.
    /// Only the computer that holds the question can dismiss it (the row's daemon).
    func dismissAttention(_ rowId: String) async throws {
        _ = try await client.request("attention_dismiss", ["id": rowId])
    }
}

/// Which Needs-you rows the owner may dismiss (H-210): a bot's question, here
/// or on a card. Everything else clears when it is dealt with.
enum Dismissal {
    static func allowed(_ row: HomeAttentionRow) -> Bool { row.kind == .ownerQuestion }

    /// The computer to send it to: the one whose daemon id the row carries.
    static func daemonId(of row: HomeAttentionRow) -> String {
        if !row.daemonID.isEmpty { return row.daemonID }
        let parts = row.id.split(separator: ":", maxSplits: 2)
        return parts.count == 3 ? String(parts[1]) : ""
    }
}
