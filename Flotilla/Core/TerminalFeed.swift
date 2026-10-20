import Foundation

/// What a bot's terminal is drawn on: SwiftTerm's view on screen, a
/// recording in tests.
@MainActor
protocol TerminalDisplay: AnyObject {
    /// Clear the screen and its scrollback: the replay starts over.
    func reset()
    func write(_ data: String)
}

/// One bot's `term` stream, in order, onto a display.
///
/// `seq` is the resume cursor: an attach after a reconnect asks for what came
/// after the last push drawn. When the daemon's ring still joins up with it
/// (`resumed`), the screen stays and only what was missed is drawn; when it
/// does not, the screen is cleared and the replay draws it again.
@MainActor
final class TerminalFeed: TerminalSink {
    let botId: String
    weak var display: TerminalDisplay?
    /// The newest `seq` drawn, or nil while the screen is empty.
    private(set) var cursor: Int?
    /// Attaches sent and not yet answered. Pushes before the answer belong to
    /// an earlier attachment: the replay after `cursor` carries them again.
    private var pendingAttaches = 0
    /// The connection came back: attach again from `cursor`.
    var onReattach: (() -> Void)?
    /// The attach was answered: `resumed` says the screen was kept.
    var onAttached: ((_ resumed: Bool) -> Void)?
    /// Typing was refused (a linked bot's computer takes none from here).
    var onRefused: ((String) -> Void)?

    init(botId: String) {
        self.botId = botId
    }

    var isAttaching: Bool { pendingAttaches > 0 }

    /// The `attach` request's fields, from the cursor: everything after the
    /// last push drawn, or the whole ring for an empty screen.
    func attachFields() -> JSONDict {
        pendingAttaches += 1
        var fields: JSONDict = ["bot_id": botId]
        if let cursor { fields["after_seq"] = cursor }
        return fields
    }

    /// The attach failed before the daemon answered it.
    func attachFailed() {
        pendingAttaches = max(0, pendingAttaches - 1)
    }

    // MARK: TerminalSink

    func attached(seq: Int, resumed: Bool) {
        pendingAttaches = max(0, pendingAttaches - 1)
        if !resumed {
            // The replay no longer joins up with what is on screen: start clean,
            // and take every push of it whatever its seq.
            display?.reset()
            cursor = nil
        }
        onAttached?(resumed)
    }

    func output(seq: Int, data: String) {
        guard pendingAttaches == 0 else { return }
        // Already drawn: a replay overlapping what came live.
        if let cursor, seq <= cursor { return }
        display?.write(data)
        cursor = seq
    }

    func reattach() { onReattach?() }

    func refused(_ message: String) { onRefused?(message) }
}
