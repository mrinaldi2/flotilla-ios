import XCTest
@testable import Flotilla

/// A computer that counts usage: answers what the test set, records budget changes.
@MainActor
final class FakeUsage: UsageService {
    var report = UsageReport()
    var error: Error?
    private(set) var ranges: [UsageRange] = []
    private(set) var budgets: [Int?] = []
    private(set) var extended = 0

    func usage(range: UsageRange, projectId: String?, botId: String?) async throws -> UsageReport {
        ranges.append(range)
        if let error { throw error }
        return report
    }

    func setProjectBudget(projectId: String, weeklyTokens: Int?) async throws {
        if let error { throw error }
        budgets.append(weeklyTokens)
    }

    func extendBudget(projectId: String) async throws {
        if let error { throw error }
        extended += 1
    }
}

/// 0.24 step 6 on the phone, usage and budgets: `usage_get` decodes, the
/// words match PhoneUsage, the budget's states, the budget editor, the
/// Needs-you rows' words, and the project card's usage line.
@MainActor
final class UsageTests: XCTestCase {
    static let reply: JSONDict = [
        "type": "usage", "range": "7d",
        "total": ["input": 1_000_000, "output": 200_000, "cache_read": 40_000_000, "cache_write": 0, "tokens": 41_200_000,
                  "turns": 312, "est_cost_usd": 12.4],
        "projects": [
            ["project_id": "phd", "name": "PhD", "share": 0.72,
             "totals": ["tokens": 29_800_000, "turns": 200, "est_cost_usd": 9.1],
             "budget": ["weekly_tokens": 40_000_000, "used": 29_800_000, "since": "2026-10-16T00:00:00Z", "reached": false]],
            ["project_id": "books", "name": "Books", "share": 0.23,
             "totals": ["tokens": 9_600_000, "est_cost_usd": 2.9],
             "budget": ["weekly_tokens": 10_000_000, "used": 9_600_000, "since": "2026-10-16T00:00:00Z", "reached": false]],
            ["project_id": "flotilla", "name": "Flotilla", "share": 0.05, "totals": ["tokens": 1_800_000, "est_cost_usd": 0.4]],
        ],
        "bots": [
            ["bot_id": "lead", "name": "Phd Game Lead", "project_id": "phd", "daemon_id": "d-mac", "share": 0.5,
             "totals": ["tokens": 20_600_000, "est_cost_usd": 6.2]],
            ["bot_id": "unity", "name": "Unity Dev", "project_id": "phd", "daemon_id": "d-mac", "share": 0.22,
             "totals": ["tokens": 9_200_000, "est_cost_usd": 2.9]],
        ],
        "days": [["date": "2026-10-21", "totals": ["tokens": 5]], ["date": "2026-10-22", "totals": ["tokens": 7]]],
        "prices_as_of": "2026-10-20T09:00:00Z",
    ]

    func testTheReplyDecodes() {
        let report = UsageReport(Self.reply)
        XCTAssertEqual(report.range, .week)
        XCTAssertEqual(report.total.tokens, 41_200_000)
        XCTAssertEqual(report.total.estCostUsd, 12.4, accuracy: 0.001)
        XCTAssertEqual(report.projects.map(\.name), ["PhD", "Books", "Flotilla"])
        XCTAssertEqual(report.projects[0].budget?.weeklyTokens, 40_000_000)
        XCTAssertNil(report.projects[2].budget)
        XCTAssertEqual(report.top(in: "phd")?.name, "Phd Game Lead")
        XCTAssertEqual(report.bots(in: "phd").count, 2)
        XCTAssertEqual(report.days.map(\.date), ["2026-10-21", "2026-10-22"])
        XCTAssertNotNil(report.pricesAsOf)
    }

    func testTheWordsMatchPhoneUsage() {
        let report = UsageReport(Self.reply)
        XCTAssertEqual(UsageWords.header(report), "This week · 41.2 M tokens · ≈ $12.40")
        XCTAssertEqual(UsageWords.tokens(29_800_000), "29.8 M")
        XCTAssertEqual(UsageWords.tokens(40_000_000), "40 M")
        XCTAssertEqual(UsageWords.tokens(980_000), "980 k")
        XCTAssertEqual(UsageWords.tokens(512), "512")
        XCTAssertEqual(UsageWords.cost(0.004), "< $0.01")
        XCTAssertEqual(UsageWords.cost(0), "≈ $0")
        XCTAssertEqual(UsageWords.pill(report.projects[0].budget).text, "74%")
        XCTAssertEqual(UsageWords.pill(report.projects[1].budget).text, "96% · nearly there")
        XCTAssertEqual(UsageWords.pill(report.projects[1].budget).tone, .needsYou)
        XCTAssertEqual(UsageWords.pill(nil).text, "no budget")
        XCTAssertEqual(UsageWords.line(report.projects[0], top: report.top(in: "phd")),
                       "29.8 M of 40 M this week · ≈ $9.10 · most: Phd Game Lead")
        XCTAssertEqual(UsageWords.line(report.projects[2], top: nil), "1.8 M tokens · ≈ $0.40")
        XCTAssertEqual(UsageWords.botLine(report.bots[0]), "20.6 M tokens · 50% · ≈ $6.20")
    }

    func testTheBudgetsStates() {
        var budget = ProjectBudget()
        XCTAssertEqual(UsageWords.state(budget), .none, "no weekly tokens is no budget")
        budget.weeklyTokens = 100
        budget.used = 50
        XCTAssertEqual(UsageWords.state(budget), .fine)
        budget.used = 80
        XCTAssertEqual(UsageWords.state(budget), .nearly, "the warning starts at 80%")
        budget.used = 104
        budget.reached = true
        XCTAssertEqual(UsageWords.state(budget), .reached)
        XCTAssertEqual(UsageWords.pill(budget).text, "Budget reached")
        budget.reached = false
        budget.extendedUntil = Date().addingTimeInterval(3600)
        XCTAssertEqual(UsageWords.state(budget), .extended)
        XCTAssertEqual(UsageWords.pill(budget).text, "104% · extended today")
    }

    func testTheBudgetFieldIsMillionsOfTokens() {
        XCTAssertEqual(UsageWords.budgetTokens(fromMillions: "40"), 40_000_000)
        XCTAssertEqual(UsageWords.budgetTokens(fromMillions: " 2,5 "), 2_500_000)
        XCTAssertNil(UsageWords.budgetTokens(fromMillions: "0"))
        XCTAssertNil(UsageWords.budgetTokens(fromMillions: "-3"))
        XCTAssertNil(UsageWords.budgetTokens(fromMillions: "lots"))
        XCTAssertEqual(UsageWords.millions(40_000_000), "40")
        XCTAssertEqual(UsageWords.millions(2_500_000), "2.5")
    }

    func testTheBudgetEditor() async {
        let fake = FakeUsage()
        var current = ProjectBudget()
        current.weeklyTokens = 40_000_000
        let model = BudgetModel(projectId: "phd", budget: current, service: fake)
        XCTAssertEqual(model.millions, "40")
        model.millions = "50"
        XCTAssertTrue(model.canSave)
        await model.save()
        XCTAssertEqual(fake.budgets, [50_000_000])
        XCTAssertTrue(model.saved)
        model.millions = "nope"
        XCTAssertFalse(model.canSave)
        await model.save()
        XCTAssertEqual(fake.budgets, [50_000_000], "an unreadable number never removes the budget")
        await model.remove()
        XCTAssertEqual(fake.budgets, [50_000_000, nil], "No budget sends null")
        await model.extend()
        XCTAssertEqual(fake.extended, 1)
        fake.error = DaemonError(code: "forbidden", message: "Only the owner's device")
        await model.extend()
        XCTAssertEqual(model.failure, "Only the owner's device")
        XCTAssertFalse(model.saved)
    }

    func testTheUsagePageAddsComputersUp() async {
        let mac = FakeUsage()
        mac.report = UsageReport(Self.reply)
        let pc = FakeUsage()
        pc.error = DaemonError(code: "unavailable", message: "Offline")
        let model = UsageModel()
        await model.load([.init(computerId: "mac", name: "mac", service: mac), .init(computerId: "pc", name: "pc", service: pc)])
        XCTAssertEqual(mac.ranges, [.week], "the page opens on this week, as the design")
        XCTAssertEqual(model.reports.count, 1)
        XCTAssertEqual(model.failures["pc"], "Offline")
        XCTAssertEqual(model.header, "This week · 41.2 M tokens · ≈ $12.40")
    }

    func testBudgetAndRoleRowsInNeedsYou() {
        var reached = HomeAttentionRow()
        reached.kind = .budgetReached
        reached.title = "PhD used its weekly budget: its on-demand bots are held"
        XCTAssertEqual(reached.kindWord, "Budget reached")
        XCTAssertEqual(reached.tone, .failed)
        var warning = HomeAttentionRow()
        warning.kind = .budgetWarning
        XCTAssertEqual(warning.kindWord, "Budget")
        XCTAssertEqual(AskAction.label(warning, opens: .usage(computerId: "mac", projectId: "phd")), "Raise budget")
        var role = HomeAttentionRow()
        role.kind = .roleUnheld
        role.role = "architect"
        XCTAssertEqual(role.kindWord, "Role nobody holds")
        XCTAssertEqual(RoleWords.role(token: "architect"), .architect)
        XCTAssertEqual(RoleWords.role(token: "developer"), .dev)
        XCTAssertEqual(RoleWords.role(token: "reviewer_arch"), .reviewerArch)
        XCTAssertNil(RoleWords.role(token: "astronaut"))
        XCTAssertTrue(RoleWords.unheld("architect", on: "mac").contains("Create a bot with the Architect role"))
        var summary = Flotilla_Home_V1_AttentionSummary()
        summary.count = 2
        summary.byKind = ["budget_reached": 1, "role_unheld": 1]
        XCTAssertEqual(AttentionWords.summary(summary), "1 budget reached · 1 role nobody holds")
    }

    func testTheCapabilityGatesUsage() {
        let store = AppStore(defaults: ComputerDefaults(id: "usage-test"))
        XCTAssertFalse(store.hasUsage)
        store.capabilities = ["usage_v1"]
        XCTAssertTrue(store.hasUsage)
    }
}
