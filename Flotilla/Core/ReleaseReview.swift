import Foundation

/// The owner's ruling on a release from the phone (H-160 AC4, UX-023 screen 2),
/// in the desktop's words (UX-008): Included / Leave out, never "ship".

/// Where a left-out item goes.
struct LeftOut: Equatable {
    enum Verdict: String { case hold, rework }
    let verdict: Verdict
    let note: String
}

enum ReleaseReview {
    /// Every item ships unless left out (desktop `approval`).
    static func approval(_ release: Release, leftOut: [String: LeftOut]) -> [JSONDict] {
        release.items.map { item in
            guard let out = leftOut[item.itemId] else { return ["item_id": item.itemId, "verdict": "ship"] }
            var verdict: JSONDict = ["item_id": item.itemId, "verdict": out.verdict.rawValue]
            if !out.note.isEmpty { verdict["note"] = out.note }
            return verdict
        }
    }

    /// The reason on every item, each where the owner sent it (desktop `rejection`).
    static func rejection(_ release: Release, reason: String, returns: [String: LeftOut.Verdict]) -> [JSONDict] {
        release.items.map { item in
            ["item_id": item.itemId, "verdict": (returns[item.itemId] ?? .rework).rawValue, "note": reason]
        }
    }

    /// "Approve 2 of 3 items", or "Approve 0.17.0" with nothing left out.
    static func approveButton(_ release: Release, leftOut: Int) -> String {
        leftOut > 0 ? "Approve \(release.items.count - leftOut) of \(release.items.count) items" : "Approve \(release.version)"
    }

    /// The Face ID prompt and the confirm title: "Approve 2 of 3 items?".
    static func approveQuestion(_ release: Release, leftOut: Int) -> String {
        approveButton(release, leftOut: leftOut) + "?"
    }

    /// What happens next, under the buttons.
    static func approveBody(_ release: Release, leftOut: Int) -> String {
        let shipping = release.items.count - leftOut
        return leftOut > 0
            ? "DevOps repackages the \(shipping) approved item\(shipping == 1 ? "" : "s") without the rest, and you rule on that new build. The items left out go back as you chose."
            : "DevOps rolls \(release.version) out to each computer, one at a time, starting now."
    }

    /// "1 item left out · DevOps repackages the rest"
    static func leftOutLine(_ count: Int) -> String? {
        count > 0 ? "\(count) item\(count == 1 ? "" : "s") left out · DevOps repackages the rest" : nil
    }

    /// "Approving 2 of 3 items of 0.17.0", while Undo is offered.
    static func approving(_ release: Release, leftOut: Int) -> String {
        leftOut > 0
            ? "Approving \(release.items.count - leftOut) of \(release.items.count) items of \(release.version)"
            : "Approving \(release.version)"
    }

    /// A left-out item's line: "Left out · back to Doing: “note”".
    static func outWords(_ out: LeftOut) -> String {
        switch out.verdict {
        case .hold: "Left out · waits for the next package"
        case .rework: out.note.isEmpty ? "Left out · back to Doing" : "Left out · back to Doing: “\(out.note)”"
        }
    }

    /// With every item back to Ready the package is held, not rejected.
    static func rejectHint(_ returns: [String: LeftOut.Verdict], items: Int) -> String? {
        returns.count == items && returns.values.allSatisfy { $0 == .hold }
            ? "With every item back to Ready, the package is held rather than rejected." : nil
    }

    /// Why this phone can't rule, when it can't.
    static func cannotRule(_ release: Release, canApprove: Bool) -> String? {
        if !canApprove { return "This device can't rule on releases: it doesn't have approve access." }
        guard !release.canRule else { return nil }
        return "You can approve, hold or reject this package only from a device connected directly to \(release.ruleOn ?? "the computer that keeps this board")."
    }

    /// Hold reminders, as on desktop.
    enum Remind: String, CaseIterable, Identifiable {
        case never = "Don't remind me", tomorrow = "Tomorrow", threeDays = "In 3 days", nextWeek = "Next week"
        var id: String { rawValue }

        func date(from now: Date = Date()) -> Date? {
            switch self {
            case .never: nil
            case .tomorrow: Calendar.current.date(byAdding: .day, value: 1, to: now)
            case .threeDays: Calendar.current.date(byAdding: .day, value: 3, to: now)
            case .nextWeek: Calendar.current.date(byAdding: .day, value: 7, to: now)
            }
        }
    }
}

extension AppStore {
    /// `release_rule` (approve grant, on the board's home), as the desktop sends it.
    func ruleRelease(_ release: Release, verdicts: [JSONDict]) async throws -> Release {
        let reply = try await client.request("release_rule", ["release_id": release.id, "verdicts": verdicts,
                                                              "expected_version": release.revision])
        return Release(reply.dict("release") ?? [:])
    }

    func holdRelease(_ release: Release, note: String, remindAt: Date?) async throws -> Release {
        var fields: JSONDict = ["release_id": release.id]
        if !note.isEmpty { fields["note"] = note }
        if let remindAt { fields["remind_at"] = ISO8601DateFormatter().string(from: remindAt) }
        let reply = try await client.request("release_hold", fields)
        return Release(reply.dict("release") ?? [:])
    }
}

/// An approval waiting out its Undo, app-wide (UX-040, CE): the bar and the
/// outcome follow the owner to whatever screen they are on.
@MainActor @Observable
final class RulingQueue {
    struct Pending: Equatable {
        let id: UUID
        let releaseId: String
        /// "Approving 2 of 3 items of 0.17.0"
        let label: String
    }

    struct Outcome: Equatable {
        let id: UUID
        let releaseId: String
        let text: String
        let ok: Bool
        /// The package changed under the owner: reload it before ruling again.
        let changed: Bool
        /// Undone before anything was sent.
        var undone = false

        /// The owner's Leave-out choices are spent: the ruling went, or the
        /// package changed. Undo keeps them, to approve again (H-225).
        var clearsChoices: Bool { (ok && !undone) || changed }
    }

    static let undoWindow: Duration = .seconds(5)

    private(set) var pending: Pending?
    private(set) var outcome: Outcome?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Waits `wait`, unless undone, then sends. `send` returns the ruled package.
    func approve(_ release: Release, leftOut: Int, wait: Duration = undoWindow,
                 send: @escaping () async throws -> Release) {
        task?.cancel()
        let pending = Pending(id: UUID(), releaseId: release.id, label: ReleaseReview.approving(release, leftOut: leftOut))
        self.pending = pending
        outcome = nil
        task = Task {
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, self.pending?.id == pending.id else { return }
            self.pending = nil
            do {
                _ = try await send()
                self.finish(release, RulingWords.approved(release, leftOut: leftOut), ok: true, changed: false)
            } catch {
                let changed = RulingWords.isConflict(error)
                self.finish(release, changed ? RulingWords.changed(release) : RulingWords.notApproved(release, error), ok: false, changed: changed)
            }
        }
    }

    func undo() {
        guard let pending else { return }
        task?.cancel()
        self.pending = nil
        outcome = Outcome(id: UUID(), releaseId: pending.releaseId, text: RulingWords.undone, ok: true, changed: false,
                          undone: true)
    }

    func dismissOutcome() { outcome = nil }

    /// What a reject or hold came to, shown the same way.
    func report(_ release: Release, error: Error) {
        let changed = RulingWords.isConflict(error)
        finish(release, changed ? RulingWords.changed(release) : error.localizedDescription, ok: false, changed: changed)
    }

    private func finish(_ release: Release, _ text: String, ok: Bool, changed: Bool) {
        outcome = Outcome(id: UUID(), releaseId: release.id, text: text, ok: ok, changed: changed)
    }
}

enum RulingWords {
    /// What happens next too (UX): "0.17.0 approved. DevOps rolls it out next."
    static func approved(_ release: Release, leftOut: Int) -> String {
        leftOut > 0
            ? "\(release.items.count - leftOut) of \(release.items.count) items of \(release.version) approved. DevOps repackages them next."
            : "\(release.version) approved. DevOps rolls it out next."
    }

    /// After Undo. A cancelled Face ID keeps "Not approved. Nothing was sent."
    static let undone = "Undone. Nothing was sent."

    static func notApproved(_ release: Release, _ error: Error) -> String {
        "Couldn't approve \(release.version): \(error.localizedDescription)"
    }

    /// CE: a version conflict reloads the package and says so.
    static func changed(_ release: Release) -> String {
        "\(release.version) changed while you were reviewing it. Nothing was sent. Check it again, then rule."
    }

    /// `release_rule` refuses a stale `expected_version` (or frozen hash) as a conflict.
    static func isConflict(_ error: Error) -> Bool {
        if let error = error as? DaemonError, error.code == "conflict" { return true }
        let text = error.localizedDescription.lowercased()
        return text.contains("expected_version") || text.contains("changed since")
    }
}
