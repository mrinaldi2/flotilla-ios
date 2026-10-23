import Foundation
import Observation

// Usage and budgets (0.24.0, `usage_v1`): each bot's tokens per day, read from
// its transcripts; per project and per bot with its share and an estimated
// cost, and a weekly token budget per project. At 80% Needs you warns; at
// 100% the project's on-demand bots stop waking and the lead keeps running.

/// Tokens of every kind, and what they would cost by the price table.
struct UsageTotals: Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var tokens = 0
    var turns = 0
    /// An estimate from the owner's price table.
    var estCostUsd = 0.0

    init() {}

    init(_ d: JSONDict?) {
        guard let d else { return }
        input = d.int("input")
        output = d.int("output")
        cacheRead = d.int("cache_read")
        cacheWrite = d.int("cache_write")
        tokens = d.int("tokens")
        turns = d.int("turns")
        estCostUsd = (d["est_cost_usd"] as? NSNumber)?.doubleValue ?? 0
    }

    static func + (a: Self, b: Self) -> Self {
        var sum = UsageTotals()
        sum.input = a.input + b.input
        sum.output = a.output + b.output
        sum.cacheRead = a.cacheRead + b.cacheRead
        sum.cacheWrite = a.cacheWrite + b.cacheWrite
        sum.tokens = a.tokens + b.tokens
        sum.turns = a.turns + b.turns
        sum.estCostUsd = a.estCostUsd + b.estCostUsd
        return sum
    }
}

/// A project's weekly token budget, over the last 7 days.
struct ProjectBudget: Equatable {
    var weeklyTokens = 0
    var used = 0
    var since: Date?
    var extendedUntil: Date?
    /// Used up and not extended: its on-demand bots don't wake.
    var reached = false

    init() {}

    init(_ d: JSONDict) {
        weeklyTokens = d.int("weekly_tokens")
        used = d.int("used")
        since = d.date("since")
        extendedUntil = d.date("extended_until")
        reached = d.bool("reached")
    }

    /// 0…, over 1 once past it.
    var fraction: Double { weeklyTokens > 0 ? Double(used) / Double(weeklyTokens) : 0 }
}

struct UsageProject: Identifiable, Equatable {
    let projectId: String
    let name: String
    let totals: UsageTotals
    /// Of the reply's total, 0…1.
    let share: Double
    let budget: ProjectBudget?
    var id: String { projectId }

    init(_ d: JSONDict) {
        projectId = d.str("project_id")
        name = d.str("name")
        totals = UsageTotals(d.dict("totals"))
        share = (d["share"] as? NSNumber)?.doubleValue ?? 0
        budget = d.dict("budget").map(ProjectBudget.init)
    }
}

struct UsageBot: Identifiable, Equatable {
    let botId: String
    let name: String
    let projectId: String
    let daemonId: String
    let totals: UsageTotals
    let share: Double
    var id: String { "\(daemonId)/\(botId)" }

    init(_ d: JSONDict) {
        botId = d.str("bot_id")
        name = d.str("name")
        projectId = d.str("project_id")
        daemonId = d.str("daemon_id")
        totals = UsageTotals(d.dict("totals"))
        share = (d["share"] as? NSNumber)?.doubleValue ?? 0
    }
}

/// today, 7d or 30d.
enum UsageRange: String, CaseIterable, Identifiable {
    case today, week = "7d", month = "30d"

    var id: Self { self }

    var title: String {
        switch self {
        case .today: "Today"
        case .week: "7 days"
        case .month: "30 days"
        }
    }

    /// "This week · 41.2 M tokens".
    var phrase: String {
        switch self {
        case .today: "Today"
        case .week: "This week"
        case .month: "Last 30 days"
        }
    }
}

/// One `usage_get` answer.
struct UsageReport: Equatable {
    var range = UsageRange.today
    var total = UsageTotals()
    var projects: [UsageProject] = []
    var bots: [UsageBot] = []
    var days: [(date: String, totals: UsageTotals)] = []
    var pricesAsOf: Date?

    init() {}

    init(_ reply: JSONDict) {
        range = UsageRange(rawValue: reply.str("range")) ?? .today
        total = UsageTotals(reply.dict("total"))
        projects = reply.list("projects").map(UsageProject.init)
        bots = reply.list("bots").map(UsageBot.init)
        days = reply.list("days").map { ($0.str("date"), UsageTotals($0.dict("totals"))) }
        pricesAsOf = reply.date("prices_as_of")
    }

    static func == (a: Self, b: Self) -> Bool {
        a.range == b.range && a.total == b.total && a.projects == b.projects && a.bots == b.bots
            && a.days.map(\.date) == b.days.map(\.date) && a.days.map(\.totals) == b.days.map(\.totals)
    }

    func bots(in projectId: String) -> [UsageBot] { bots.filter { $0.projectId == projectId } }

    /// The bot that used the most of a project's tokens.
    func top(in projectId: String) -> UsageBot? { bots(in: projectId).max { $0.totals.tokens < $1.totals.tokens } }
}

/// Usage in the glossary's words.
enum UsageWords {
    /// "41.2 M", "980 k", "512".
    static func tokens(_ n: Int) -> String {
        let value = Double(n)
        if value >= 1_000_000 { return "\(trim(value / 1_000_000)) M" }
        if value >= 1_000 { return "\(trim(value / 1_000)) k" }
        return "\(n)"
    }

    private static func trim(_ value: Double) -> String {
        let rounded = value >= 100 ? value.rounded() : (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    /// "≈ $12.40", "≈ $0.03", "< $0.01".
    static func cost(_ usd: Double) -> String {
        if usd <= 0 { return "≈ $0" }
        if usd < 0.01 { return "< $0.01" }
        return "≈ $" + String(format: usd >= 100 ? "%.0f" : "%.2f", usd)
    }

    /// "74%" for 74.5%: rounded down, so a budget reads 100% only once it is used.
    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100 + 1e-9).rounded(.down)))%" }

    /// "This week · 41.2 M tokens · ≈ $12.40".
    static func header(_ report: UsageReport) -> String {
        "\(report.range.phrase) · \(tokens(report.total.tokens)) tokens · \(cost(report.total.estCostUsd))"
    }

    enum BudgetState: Equatable {
        case none, fine, nearly, reached, extended
    }

    static func state(_ budget: ProjectBudget?, now: Date = Date()) -> BudgetState {
        guard let budget, budget.weeklyTokens > 0 else { return .none }
        if budget.reached { return .reached }
        if budget.fraction >= 1, let until = budget.extendedUntil, until > now { return .extended }
        return budget.fraction >= 0.8 ? .nearly : .fine
    }

    /// The pill on a project's card: "74%", "96% · nearly there", "Budget reached", "no budget".
    static func pill(_ budget: ProjectBudget?, now: Date = Date()) -> (text: String, tone: Tone) {
        switch state(budget, now: now) {
        case .none: return ("no budget", .quiet)
        case .fine: return (percent(budget!.fraction), .quiet)
        case .nearly: return ("\(percent(budget!.fraction)) · nearly there", .needsYou)
        case .reached: return ("Budget reached", .failed)
        case .extended: return ("\(percent(budget!.fraction)) · extended today", .needsYou)
        }
    }

    /// "29.8 M of 40 M · most: Phd Game Lead".
    static func line(_ project: UsageProject, top: UsageBot?) -> String {
        var parts: [String] = []
        if let budget = project.budget, budget.weeklyTokens > 0 {
            parts.append("\(tokens(budget.used)) of \(tokens(budget.weeklyTokens)) this week")
        } else {
            parts.append("\(tokens(project.totals.tokens)) tokens")
        }
        parts.append(cost(project.totals.estCostUsd))
        if let top, !top.name.isEmpty { parts.append("most: \(top.name)") }
        return parts.joined(separator: " · ")
    }

    /// A bot's row: "4.1 M tokens · 34% · ≈ $3.10".
    static func botLine(_ bot: UsageBot) -> String {
        "\(tokens(bot.totals.tokens)) tokens · \(percent(bot.share)) · \(cost(bot.totals.estCostUsd))"
    }

    /// "40" for 40 M tokens, from the field's "40" or "40.5"; nil when it isn't a number above 0.
    static func budgetTokens(fromMillions text: String) -> Int? {
        let cleaned = text.trimmed.replacingOccurrences(of: ",", with: ".")
        guard let millions = Double(cleaned), millions > 0, millions < 1_000_000 else { return nil }
        let tokens = Int((millions * 1_000_000).rounded())
        return tokens > 0 ? tokens : nil
    }

    static func millions(_ tokens: Int) -> String { trim(Double(tokens) / 1_000_000) }

    static let estimateNote = "Costs are estimates from the price table on your computer. Your Claude plan’s own limits still apply."
}

/// What Usage asks a computer.
@MainActor
protocol UsageService: AnyObject {
    func usage(range: UsageRange, projectId: String?, botId: String?) async throws -> UsageReport
    /// nil removes it.
    func setProjectBudget(projectId: String, weeklyTokens: Int?) async throws
    func extendBudget(projectId: String) async throws
}

extension AppStore: UsageService {
    var hasUsage: Bool { capabilities.contains("usage_v1") }

    func usage(range: UsageRange, projectId: String?, botId: String?) async throws -> UsageReport {
        var fields: JSONDict = ["range": range.rawValue]
        if let projectId { fields["project_id"] = projectId }
        if let botId { fields["bot_id"] = botId }
        return UsageReport(try await client.request("usage_get", fields))
    }

    func setProjectBudget(projectId: String, weeklyTokens: Int?) async throws {
        _ = try await client.request("set_project_budget", ["project_id": projectId, "weekly_tokens": weeklyTokens ?? NSNull()])
    }

    func extendBudget(projectId: String) async throws {
        _ = try await client.request("budget_extend", ["project_id": projectId])
    }
}

/// The Usage page: one report per computer, for the range picked.
@MainActor @Observable
final class UsageModel {
    struct Source {
        let computerId: String
        let name: String
        let service: UsageService
    }

    var range = UsageRange.week
    private(set) var reports: [(computerId: String, name: String, report: UsageReport)] = []
    private(set) var failures: [String: String] = [:]
    private(set) var loading = false

    @ObservationIgnored private var sources: [Source] = []

    var total: UsageTotals { reports.reduce(UsageTotals()) { $0 + $1.report.total } }

    /// "This week · 41.2 M tokens · ≈ $12.40", over every computer.
    var header: String {
        var all = UsageReport()
        all.range = range
        all.total = total
        return UsageWords.header(all)
    }

    func load(_ sources: [Source]) async {
        self.sources = sources
        loading = true
        defer { loading = false }
        let range = self.range
        var answers: [(String, String, UsageReport)] = []
        var failed: [String: String] = [:]
        for source in sources {
            do {
                answers.append((source.computerId, source.name, try await source.service.usage(range: range, projectId: nil, botId: nil)))
            } catch {
                failed[source.name] = error.localizedDescription
            }
        }
        guard range == self.range else { return }
        reports = answers.map { ($0.0, $0.1, $0.2) }
        failures = failed
    }

    func reload() async { await load(sources) }
}

/// A project's budget editor: the weekly budget in million tokens, Save, No budget.
@MainActor @Observable
final class BudgetModel {
    let projectId: String
    var millions: String
    private(set) var busy = false
    private(set) var failure: String?
    private(set) var saved = false

    @ObservationIgnored private let service: UsageService

    init(projectId: String, budget: ProjectBudget?, service: UsageService) {
        self.projectId = projectId
        self.service = service
        millions = budget.map { $0.weeklyTokens > 0 ? UsageWords.millions($0.weeklyTokens) : "" } ?? ""
    }

    var tokens: Int? { UsageWords.budgetTokens(fromMillions: millions) }
    var canSave: Bool { tokens != nil && !busy }

    func save() async {
        guard let tokens else { return }
        await set(tokens)
    }

    func remove() async { await set(nil) }

    func extend() async {
        await act { try await self.service.extendBudget(projectId: self.projectId) }
    }

    private func set(_ tokens: Int?) async {
        await act { try await self.service.setProjectBudget(projectId: self.projectId, weeklyTokens: tokens) }
    }

    private func act(_ work: @escaping () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        failure = nil
        saved = false
        defer { busy = false }
        do {
            try await work()
            saved = true
        } catch {
            failure = error.localizedDescription
        }
    }
}
