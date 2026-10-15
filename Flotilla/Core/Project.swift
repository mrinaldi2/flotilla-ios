import Foundation

// One project, UX-024: its Overview (`dashboard_get`), Board (typed
// `board_get` in binary frames, ADR-001), Team, Releases and Meetings, and a
// bot's reports (`owner_thread_get`). Board, releases and meetings live on
// the board's home; bots and their threads on each bot's own computer
// (H-128 R2.1 routing).

typealias BoardSnapshot = Hermes_Board_V1_BoardSnapshot
typealias BoardCard = Hermes_Board_V1_ItemCard
typealias BoardItemDetail = Hermes_Board_V1_ItemDetail

/// What the project's Overview shows (`dashboard_get`).
struct Dashboard {
    struct Column: Identifiable {
        let key: String
        let name: String
        let category: String
        let count: Int
        let wipLimit: Int?
        var id: String { key }
        var full: Bool { wipLimit.map { count >= $0 } ?? false }
    }

    struct Member: Identifiable {
        let bot: Bot
        let doing: [(id: String, title: String)]
        let openTasks: Int
        var id: String { bot.id }
    }

    struct Meeting: Identifiable {
        let id: String
        let name: String
        let type: String
        let nextAt: Date?
        let collecting: Bool
        let lastSummary: String?
        let lastHeldAt: Date?
    }

    struct Action: Identifiable {
        let id: String
        let text: String
        let owner: String
        let dueAt: Date?
        let overdue: Bool
        let meetingName: String?
    }

    let columns: [Column]
    let blocked: Int
    let stale: Int
    let doneThisWeek: Int?
    let reworkThisWeek: Int?
    /// The computer holding the board, when this one mirrors it.
    let home: String?
    let releases: [Release]
    let team: [Member]
    let meetings: [Meeting]
    let actions: [Action]
    let hasBoard: Bool

    init(_ d: JSONDict) {
        let board = d.dict("board")
        hasBoard = board != nil
        columns = (board?.list("columns") ?? []).map {
            Column(key: $0.str("key"), name: $0.str("name"), category: $0.str("category"),
                   count: $0.int("count"), wipLimit: $0.optInt("wip_limit"))
        }
        blocked = board?.int("blocked") ?? 0
        stale = board?.int("stale") ?? 0
        doneThisWeek = board?.optInt("done_this_week")
        reworkThisWeek = board?.optInt("rework_this_week")
        home = d.optStr("home")
        releases = d.list("releases").map(Release.init)
        team = d.list("team").compactMap { row in
            guard let bot = row.dict("bot").map(Bot.init) else { return nil }
            return Member(bot: bot, doing: row.list("items").map { ($0.str("id"), $0.str("title")) }, openTasks: row.int("open_tasks"))
        }
        meetings = d.list("meetings").map { row in
            let series = row.dict("series")
            let collecting = row.dict("collecting")
            let held = row.dict("last_held")
            return Meeting(id: series?.str("id") ?? collecting?.str("id") ?? UUID().uuidString,
                           name: series?.str("name") ?? collecting?.str("name") ?? "Meeting",
                           type: series?.str("type") ?? collecting?.str("type") ?? "adhoc",
                           nextAt: row.date("next_at"), collecting: collecting != nil,
                           lastSummary: held?.optStr("summary"), lastHeldAt: held?.date("closed_at"))
        }
        actions = d.list("action_items").map {
            Action(id: $0.str("id"), text: $0.str("text"), owner: $0.str("owner"), dueAt: $0.date("due_at"),
                   overdue: $0.bool("overdue"), meetingName: $0.optStr("meeting_name"))
        }
    }

    /// "Doing 3 · Review 2/3 · Verify 3/3 full": the in-progress columns.
    var strip: [Column] { columns.filter { !["inbox", "ready", "done", "cancelled"].contains($0.category) } }
}

/// A release package as the review lists it (B7).
struct Release: Identifiable {
    struct Item: Identifiable {
        let itemId: String
        let verdict: String
        let note: String?
        var id: String { itemId }
    }

    struct Test: Identifiable {
        let machine: String
        let result: String
        var id: String { machine }
    }

    /// An item's live board state (`plan[]`, H-137): where it is, not the owner's ruling.
    struct PlanItem {
        let itemId: String
        let title: String
        let columnKey: String
        let columnName: String
        let ready: Bool
        let blocked: Bool
        let acChecked: Int
        let acTotal: Int
        let assignee: String?

        init(_ d: JSONDict) {
            itemId = d.str("item_id")
            title = d.str("title")
            columnKey = d.str("column_key")
            columnName = d.optStr("column_name") ?? PlanItem.column(d.str("column_key"))
            ready = d.bool("ready")
            blocked = d.bool("blocked")
            acChecked = d.int("ac_checked")
            acTotal = d.int("ac_total")
            assignee = d.optStr("assignee")
        }

        /// Column names when the board gives none (UX-025 §2, as desktop).
        static func column(_ key: String) -> String {
            let names = ["inbox": "Inbox", "ready": "Ready", "doing": "Doing", "review": "Review", "verify": "Verify",
                         "approval": "Awaiting owner", "deploying": "Deploying", "done": "Done", "cancelled": "Cancelled"]
            return names[key] ?? key.capitalizedFirst
        }
    }

    /// What one item's row says (H-200): its live state before the package is
    /// submitted, the owner's ruling after. Never the raw verdict "pending".
    struct ItemState: Equatable {
        let title: String
        /// "Done · Team Lead · ☑ 3/3 AC · ⛔ Blocked"
        let meta: String?
        /// "✓ Included", "○ Still in progress"; nil when there is nothing to say yet.
        let pill: String?
        let tone: Tone?
    }

    let id: String
    let name: String
    let version: String
    let status: String
    let items: [Item]
    let tests: [Test]
    let itemsReady: Int
    let itemsTotal: Int
    let canRule: Bool
    let ruleOn: String?
    let changelog: String?
    let createdAt: Date?
    /// The package's version number, sent back with a ruling (`expected_version`).
    let revision: Int
    let createdBy: String?
    let plan: [PlanItem]
    /// What only the owner can give it (H-248), in UX-048's order; nil from a
    /// service without `owner_blockers`.
    let ownerBlockers: [OwnerBlocker]?
    /// The release's own card.
    let workItemId: String?
    /// The computers it must reach before it counts as deployed.
    let deploysTo: [String]
    /// The computers a deploy finished on.
    let deployedOn: [String]
    /// The platforms its how-to-test names, e.g. desktop-mac.
    let platforms: [String]
    let builds: [String]
    let testsPassed: [String]
    let testsRequired: [String]

    init(_ d: JSONDict) {
        id = d.str("id")
        name = d.str("name")
        version = d.optStr("display_version") ?? d.str("name")
        status = d.str("status")
        items = d.list("items").map { Item(itemId: $0.str("item_id"), verdict: $0.str("verdict"), note: $0.optStr("owner_note")) }
        tests = d.list("tests").map { Test(machine: $0.str("machine"), result: $0.str("result")) }
        let readiness = d.dict("readiness")
        itemsReady = readiness?.int("items_ready") ?? 0
        itemsTotal = readiness?.int("items_total") ?? items.count
        canRule = d.bool("can_rule")
        ruleOn = d.optStr("rule_on")
        changelog = d.optStr("changelog")
        createdAt = d.date("created_at")
        revision = d.int("version")
        createdBy = d.optStr("created_by")
        plan = d.list("plan").map(PlanItem.init)
        ownerBlockers = OwnerBlocker.list(d)
        workItemId = d.optStr("work_item_id").flatMap { $0.isEmpty ? nil : $0 }
        deploysTo = (d["deploys_to"] as? [String]) ?? []
        deployedOn = d.list("deployments").filter { $0.str("action") != "rollback" && $0.str("result") == "ok" }.map { $0.str("machine") }
        var seen = Set<String>()
        platforms = d.list("how_to_test").map { $0.str("platform") }.filter { !$0.isEmpty && seen.insert($0).inserted }
        builds = (readiness?["builds"] as? [String]) ?? []
        testsPassed = (readiness?["tests_passed"] as? [String]) ?? []
        testsRequired = (readiness?["tests_required"] as? [String]) ?? []
    }

    /// Not yet submitted: the rows show each item's live state (desktop ReleaseProgress).
    var showsProgress: Bool { ["planned", "assembling", "built"].contains(status) && !plan.isEmpty }

    /// "1 of 3 items ready · Built for Mac and Windows · Tested on 0 of 2 computers"
    var readinessLine: String {
        let platforms = ["desktop-mac": "Mac", "desktop-win": "Windows", "desktop-linux": "Linux", "ios": "iPhone"]
        let built = builds.isEmpty
            ? "Not built yet"
            : "Built for " + ListFormatter.localizedString(byJoining: builds.map { platforms[$0] ?? $0 })
        let required = testsRequired.count
        let tested = required == 0
            ? "No computer to test on yet"
            : "Tested on \(testsPassed.count) of \(required) computer\(required == 1 ? "" : "s")"
        return "\(itemsReady) of \(itemsTotal) items ready · \(built) · \(tested)"
    }

    /// The row for one item, in the desktop's words. `botName` names an assignee.
    func state(of item: Item, botName: (String) -> String?) -> ItemState {
        let planned = plan.first { $0.itemId == item.itemId }
        let title = planned.map { $0.title.isEmpty ? item.itemId : "\(item.itemId) · \($0.title)" } ?? item.itemId
        var meta: String?
        if let planned {
            var parts = [planned.columnName, planned.assignee.map { botName($0) ?? "A bot" } ?? "Unassigned"]
            if planned.acTotal > 0 { parts.append("☑ \(planned.acChecked)/\(planned.acTotal) AC") }
            if planned.blocked { parts.append("⛔ Blocked") }
            meta = parts.joined(separator: " · ")
        }
        if showsProgress, let planned {
            return ItemState(title: title, meta: meta,
                             pill: planned.ready ? "✓ Ready for the release" : "○ Still in progress",
                             tone: planned.ready ? .ready : .quiet)
        }
        switch item.verdict {
        case "ship":
            return ItemState(title: title, meta: meta, pill: "✓ Included", tone: .ready)
        case "hold":
            return ItemState(title: title, meta: meta, pill: "⤼ Left out · waits for the next package", tone: .quiet)
        case "rework":
            // The owner's reason, quoted, under the item.
            let reason = item.note.map { "“\($0)”" }
            let line = [meta, reason].compactMap { $0 }.joined(separator: " · ")
            return ItemState(title: title, meta: line.isEmpty ? nil : line, pill: "⤼ Left out · back to Doing", tone: .quiet)
        default:
            // Not ruled yet. While the package waits for the owner every item
            // ships unless left out, as desktop says (UX-036); otherwise nothing.
            let waiting = status == "awaiting_owner"
            return ItemState(title: title, meta: meta, pill: waiting ? "✓ Included" : nil, tone: waiting ? .ready : nil)
        }
    }

    /// The glossary's words for its state, and a tone (§5).
    var statusWords: (String, Tone) {
        var brief = Hermes_Home_V1_ReleaseBrief()
        brief.version = version
        brief.state = status
        return ReleaseStatusWords.pill(brief)
    }
}

/// One message in a bot's owner thread: what it reported or asked.
struct ThreadEntry: Identifiable {
    let id: String
    let fromOwner: Bool
    let text: String
    let at: Date?
    let asks: Bool
    let open: Bool
    /// Its place in the thread, for `owner_thread_read`.
    var num: Int64 = 0
}

extension AppStore {
    /// The daemon takes typed requests in binary frames (`hello_ok.encodings`).
    var speaksProto: Bool { encodings.contains("proto") }
    var hasOwnerThreads: Bool { capabilities.contains("owner_threads") }

    func dashboard(projectId: String) async throws -> Dashboard {
        let reply = try await client.request("dashboard_get", ["project_id": projectId])
        return Dashboard(reply.dict("dashboard") ?? [:])
    }

    func board(projectId: String) async throws -> BoardSnapshot {
        var get = Hermes_Board_V1_BoardGet()
        get.projectID = projectId
        var request = Hermes_Board_V1_BoardRequest()
        request.request = .boardGet(get)
        let envelope = try await client.request(.boardRequest(request), name: "board_get")
        guard case .boardResponse(let response)? = envelope.body, case .board(let board)? = response.response else {
            throw DaemonError(code: "decode", message: "The Hermes service did not return the board.")
        }
        return board
    }

    func item(_ id: String) async throws -> BoardItemDetail {
        var get = Hermes_Board_V1_ItemGet()
        get.id = id
        var request = Hermes_Board_V1_BoardRequest()
        request.request = .itemGet(get)
        let envelope = try await client.request(.boardRequest(request), name: "item_get")
        guard case .boardResponse(let response)? = envelope.body, case .item(let item)? = response.response else {
            throw DaemonError(code: "decode", message: "The Hermes service did not return \(id).")
        }
        return item
    }

    /// A card comment from the owner (U4: control grant, on the board's home).
    func releases(projectId: String) async throws -> [Release] {
        let reply = try await client.request("list_releases", ["project_id": projectId])
        return reply.list("releases").map(Release.init)
    }

    func release(_ id: String) async throws -> Release {
        #if DEBUG
        if let stub = InstallStubs.reply(InstallStubs.releaseKey)?.dict("release"), stub.str("id") == id { return Release(stub) }
        #endif
        let reply = try await client.request("get_release", ["release_id": id])
        return Release(reply.dict("release") ?? [:])
    }

    func ownerThread(botId: String) async throws -> [ThreadEntry] {
        let reply = try await client.request("owner_thread_get", ["bot_id": botId, "limit": 30])
        let page = try HomeJSON.decode(Hermes_Home_V1_OwnerThreadPage.self, reply["owner_thread"])
        return page.messages.map {
            ThreadEntry(id: $0.id.isEmpty ? String($0.num) : $0.id, fromOwner: $0.fromOwner, text: $0.text,
                        at: $0.hasAt ? $0.at.date : nil, asks: $0.asks, open: $0.open, num: $0.num)
        }
    }
}
