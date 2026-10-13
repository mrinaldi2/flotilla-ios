import Foundation

// A lead's board-structure proposal (K4, `owner_confirms`), which Needs you
// shows on its decision. A 0.19 home since K5 sends the open proposals in
// `BoardSnapshot.proposals`, each with its decision and the request it
// makes. An older home words it only in the decision: "Board change proposed
// for <board>: <summary>", its body ending "Proposal <id>.", so the phone
// falls back to reading those words.

typealias LeadProposal = Hermes_Board_V1_BoardProposal

/// A proposal as the decision screen shows it: what it changes, on which
/// board, and the board's columns as they are now.
struct ProposalCard: Equatable {
    let id: String
    /// The board it changes; for a new board, its name.
    let boardName: String
    let summary: String
    /// The request it makes; from the decision's words, only an added or
    /// removed column is known.
    let change: LeadProposal.OneOf_Change?
    /// The board's columns now, in board order; empty for a new board.
    var columns: [BoardColumnRow] = []

    static let titlePrefix = "Board change proposed for "

    /// Read from a decision's words (a home before K5).
    init?(title: String, body: String) {
        guard title.hasPrefix(Self.titlePrefix), let id = Self.proposalId(body) else { return nil }
        let rest = title.dropFirst(Self.titlePrefix.count)
        guard let colon = rest.range(of: ": ") else { return nil }
        self.id = id
        boardName = String(rest[..<colon.lowerBound])
        summary = String(rest[colon.upperBound...])
        change = Self.change(fromSummary: summary)
    }

    init?(_ decision: Decision) { self.init(title: decision.title, body: decision.body) }

    /// From the snapshot (K5): the proposal and the board it changes.
    init(_ proposal: LeadProposal, in snapshot: BoardSnapshot) {
        id = proposal.id
        summary = proposal.summary
        change = proposal.change
        let board = snapshot.boards.first { $0.id == proposal.boardID }
        if case .boardCreate(let create)? = proposal.change {
            boardName = create.name
        } else {
            boardName = board?.name ?? ""
        }
        columns = proposal.boardID.isEmpty ? [] : snapshot.columns.filter { $0.boardID == proposal.boardID }.sorted { $0.ord < $1.ord }
    }

    /// "… Proposal 1b2c-33.": the id a decision's body ends with.
    static func proposalId(_ body: String) -> String? {
        guard let match = body.range(of: #"Proposal ([A-Za-z0-9_-]+)\.\s*$"#, options: .regularExpression) else { return nil }
        let token = body[match].dropFirst("Proposal ".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(token.dropLast())
    }

    /// Whether a decision may be a proposal's, so its board is worth reading:
    /// worded as one, or a question whose body ends with a proposal's id.
    static func mayBe(_ decision: Decision) -> Bool {
        decision.state == "open" && (decision.title.hasPrefix(titlePrefix) || (decision.kind == "question" && proposalId(decision.body) != nil))
    }

    /// The decision's open proposal in the snapshot; then, when the home
    /// sends none for it (before K5), the decision's own words, with the
    /// columns of the board they name.
    static func find(decision: Decision, in snapshot: BoardSnapshot?) -> ProposalCard? {
        if let snapshot, let found = snapshot.proposals.first(where: { $0.decisionID == decision.id && $0.state == "open" }) {
            return ProposalCard(found, in: snapshot)
        }
        guard var worded = ProposalCard(decision) else { return nil }
        if let snapshot {
            let state = BoardState(snapshot: snapshot)
            // The board it names, else the one a board change on a single board is about.
            if let board = state.boards.first(where: { $0.name == worded.boardName }) {
                worded.columns = snapshot.columns.filter { $0.boardID == board.id }.sorted { $0.ord < $1.ord }
            } else {
                worded.columns = state.allColumns
            }
        }
        return worded
    }

    /// "add column “QA” …" and "remove column review", the two the words tell.
    private static func change(fromSummary summary: String) -> LeadProposal.OneOf_Change? {
        let add = "add column “"
        if summary.hasPrefix(add), let end = summary.dropFirst(add.count).firstIndex(of: "”") {
            var column = Hermes_Board_V1_ColumnAdd()
            column.name = String(summary[summary.index(summary.startIndex, offsetBy: add.count)..<end])
            return .columnAdd(column)
        }
        if summary.hasPrefix("remove column ") {
            var column = Hermes_Board_V1_ColumnRemove()
            column.key = String(summary.dropFirst("remove column ".count))
            return .columnRemove(column)
        }
        return nil
    }

    var diff: ProposalDiff { ProposalDiff(change, columns: columns) }
}

/// A proposal's change before and after, as the desktop draws it: the
/// board's visible columns, each changed one marked with a glyph, and what
/// else it changes in words.
struct ProposalDiff: Equatable {
    struct Column: Equatable {
        enum Mark: Equatable { case added, removed, changed }
        let key: String
        let name: String
        var mark: Mark?

        /// "+ QA", "− Review", "~ Doing", "To do".
        var chip: String {
            switch mark {
            case .added?: "+ \(name)"
            case .removed?: "− \(name)"
            case .changed?: "~ \(name)"
            case nil: name
            }
        }
    }

    var before: [Column]
    var after: [Column]
    /// Rules added or dropped, and anything else, one line each.
    var notes: [String]

    /// Whether there is a strip worth drawing.
    var showsColumns: Bool { before != after }

    init(_ change: LeadProposal.OneOf_Change?, columns: [BoardColumnRow]) {
        let before = columns.filter(\.visible).map { Column(key: $0.key, name: $0.name) }
        let name = { (key: String) in columns.first { $0.key == key }?.name ?? key }
        self.before = before
        after = before
        notes = []
        switch change {
        case .columnAdd(let add)?:
            after = Self.placed(before, Column(key: "+\(add.name)", name: add.name, mark: .added), after: add.hasAfter ? add.after : nil)
            notes = add.rules.map { "+ adds: \(RuleWords.rule($0))" }
            if !add.movers.isEmpty { notes.append("Moved in by: \(RuleWords.movers(add.movers))") }
            if add.hasWipLimit { notes.append("WIP limit \(add.wipLimit)") }
        case .columnUpdate(let update)?:
            let old = columns.first { $0.key == update.key }
            let current = before.first { $0.key == update.key } ?? Column(key: update.key, name: old?.name ?? update.key)
            let next = Column(key: current.key, name: update.hasName ? update.name : current.name, mark: .changed)
            let marked = before.map { $0.key == update.key ? next : $0 }
            var moved = update.hasAfter ? Self.placed(marked, next, after: update.after) : marked
            if update.hasVisible && !update.visible { moved.removeAll { $0.key == update.key } }
            after = moved
            if update.setPolicy, let old {
                notes += Self.listDiff(old.rules, update.rules, RuleWords.rule)
                notes += Self.listDiff(old.movers, update.movers) { "mover: \(RuleWords.movers([$0]))" }
                notes += Self.listDiff(old.allowedFrom, update.allowedFrom) { "from \(name($0))" }
            }
            if update.hasWipLimit { notes.append("WIP limit \(update.wipLimit)") }
            if update.clearWipLimit_p { notes.append("No WIP limit") }
            if update.hasVisible { notes.append(update.visible ? "Shown" : "Hidden") }
        case .columnRemove(let remove)?:
            after = before.map { $0.key == remove.key ? Column(key: $0.key, name: $0.name, mark: .removed) : $0 }
            if remove.hasMoveItemsTo { notes.append("Its items move to \(name(remove.moveItemsTo))") }
        case .automationSet(let set)?:
            let to = set.hasColumnKey ? set.columnKey : ""
            notes = [to.isEmpty ? "When \(RuleWords.fact(set.fact)): items stay where they are"
                                : "When \(RuleWords.fact(set.fact)) → move to \(name(to))"]
        case .boardCreate(let create)?:
            let preset = BoardPreset.named(create.preset)
            self.before = []
            after = (preset?.columns ?? []).map { Column(key: $0, name: $0, mark: .added) }
            notes = ["A new board, \(create.name), from the \(preset?.title ?? create.preset) preset"]
        case .boardUpdate(let update)?:
            if update.hasName { notes.append("Renamed to \(update.name)") }
            if update.hasDescription_p { notes.append("New description") }
            if update.hasLabelGroups {
                let groups = update.labelGroups.values.map { "\($0.name): \($0.values.joined(separator: ", "))" }
                notes.append(groups.isEmpty ? "No label groups" : "Label groups: \(groups.joined(separator: "; "))")
            }
        case nil:
            break
        }
    }

    /// `column` after `after` ("" first; nil or unknown, last).
    private static func placed(_ columns: [Column], _ column: Column, after: String?) -> [Column] {
        var rest = columns.filter { $0.key != column.key }
        if after == "" { return [column] + rest }
        if let after, let at = rest.firstIndex(where: { $0.key == after }) {
            rest.insert(column, at: at + 1)
        } else {
            rest.append(column)
        }
        return rest
    }

    private static func listDiff(_ before: [String], _ after: [String], _ words: (String) -> String) -> [String] {
        after.filter { !before.contains($0) }.map { "+ adds: \(words($0))" }
            + before.filter { !after.contains($0) }.map { "− drops: \(words($0))" }
    }
}

/// The rule library, movers and facts in the owner's words, as the desktop
/// says them (`settings/rules.ts`); an unknown token is shown as it is.
enum RuleWords {
    private static let rules: [String: String] = [
        "assignee_set": "Has an assignee", "fields_filled": "Template sections filled",
        "ac_present": "Has acceptance criteria", "ac_all_checked": "All criteria checked",
        "size_at_most": "Size at most", "blockers_done": "Blocking items are done",
        "not_blocked": "Not flagged blocked", "link": "Has a link of kind",
        "independent": "Moved by someone other than the author", "reason": "The move gives a reason",
        "predicate": "Module check",
    ]
    private static let movers: [String: String] = [
        "any_member": "Any member", "assignee": "The assignee", "lead": "The lead", "owner": "You",
        "system": "Automations only",
    ]
    private static let facts: [String: String] = [
        "pr.opened": "PR opened", "pr.merged": "PR merged", "pr.closed": "PR closed without merging",
        "pr.changes_requested": "Owner asked for changes on the PR",
        "release.submitted": "Submitted in a release package", "release.withdrawn": "Taken out of a release package",
        "release.approved": "Release approved to ship", "release.held": "Held by the owner's release verdict",
        "release.rework": "Sent back by the owner's release verdict", "release.deployed": "Deployed",
        "release.deploy_failed": "Deploy failed", "release.left_out_reverted": "Left out of a release and reverted",
    ]

    /// "size_at_most:M" → ("size_at_most", "M").
    private static func split(_ token: String) -> (head: String, arg: String?) {
        guard let colon = token.firstIndex(of: ":") else { return (token.trimmed, nil) }
        return (String(token[..<colon]).trimmed, String(token[token.index(after: colon)...]).trimmed)
    }

    /// "Size at most M", "Template sections filled: Problem, Scope".
    static func rule(_ token: String) -> String {
        let (head, arg) = split(token)
        guard let word = rules[head] else { return token }
        guard let arg, !arg.isEmpty else { return word }
        return head == "fields_filled" ? "\(word): \(arg.split(separator: ";").joined(separator: ", "))" : "\(word) \(arg)"
    }

    /// "The lead, The assignee"; none set, any member.
    static func movers(_ tokens: [String]) -> String {
        guard !tokens.isEmpty else { return "Any member" }
        return tokens.map { token in
            let (head, arg) = split(token)
            if head == "roles" { return "Roles \((arg ?? "").split(separator: ",").joined(separator: ", "))" }
            return movers[head] ?? token
        }.joined(separator: ", ")
    }

    static func fact(_ name: String) -> String { facts[name] ?? name }
}

/// The presets a new board starts from (`kanban/presets.rs`), for a proposed
/// new board's "after" strip; their hidden Cancelled column left out.
struct BoardPreset {
    let name: String
    let title: String
    let columns: [String]

    static let all = [
        BoardPreset(name: "simple", title: "Simple", columns: ["To do", "Doing", "Done"]),
        BoardPreset(name: "software", title: "Software", columns: ["Inbox", "Ready", "Doing", "Review", "Done"]),
        BoardPreset(name: "release_gated", title: "Release-gated",
                    columns: ["Inbox", "Ready", "Doing", "Review", "Verify", "Awaiting owner", "Deploying", "Done"]),
    ]

    static func named(_ name: String) -> BoardPreset? { all.first { $0.name == name } }
}
