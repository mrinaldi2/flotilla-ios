import SwiftTerm
import SwiftUI
import UIKit

/// SwiftTerm's view without its own keyboard. Two keyboard owners on one
/// screen (this and the compose field) left the compose field hidden under
/// the keyboard, so all typing goes through the field and the key row.
final class PassiveTerminalView: TerminalView {
    override var canBecomeFirstResponder: Bool { false }
}

/// Bridges one bot's pty stream to a SwiftTerm view: attach with a replay
/// cursor, feed `term` pushes, send keystrokes and size changes back.
@MainActor
final class TerminalController: NSObject, TerminalSink, @preconcurrency TerminalViewDelegate {
    let botId: String
    private let store: AppStore
    private(set) var view: PassiveTerminalView?
    private var lastSeq: Int?
    private var attachedOnce = false
    private var lastSentSize: [Int] = []
    private var resizeTask: Task<Void, Never>?
    /// Why attaching failed (a linked bot's machine is offline), or nil once attached.
    var onFailure: ((String?) -> Void)?

    init(botId: String, store: AppStore) {
        self.botId = botId
        self.store = store
    }

    func makeView() -> PassiveTerminalView {
        let terminal = PassiveTerminalView(frame: .zero)
        terminal.font = UIFont.monospacedSystemFont(ofSize: Self.fontSize, weight: .regular)
        terminal.nativeBackgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
        terminal.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        terminal.terminalDelegate = self
        view = terminal
        store.register(self, for: botId)
        attach()
        return terminal
    }

    static var fontSize: CGFloat {
        let saved = UserDefaults.standard.double(forKey: "terminalFontSize")
        return saved == 0 ? 11 : saved
    }

    func close() {
        resizeTask?.cancel()
        store.unregister(self, for: botId)
    }

    // MARK: Stream

    private func attach() {
        var fields: JSONDict = ["bot_id": botId]
        if let lastSeq { fields["after_seq"] = lastSeq }
        Task {
            do {
                _ = try await store.client.request("attach", fields)
                onFailure?(nil)
            } catch let error as DaemonError where error.code == "unavailable" {
                let machine = store.bot(botId)?.peerName ?? "Its computer"
                onFailure?("\(machine) is offline. The terminal shows here again when it is back.")
            } catch let error as DaemonError where error.code != "not_connected" {
                onFailure?(error.message)
            } catch {}
        }
    }

    func reattach() { attach() }

    func attached(seq: Int, resumed: Bool) {
        // The replay no longer joins up with what is on screen: start clean.
        if !resumed { view?.feed(text: "\u{1b}c") }
        attachedOnce = true
        sendSize(force: true)
    }

    func output(seq: Int, data: String) {
        view?.feed(text: data)
        lastSeq = seq
    }

    // MARK: Input

    func type(_ data: String) {
        guard store.canControl else { return }
        store.client.send("input", ["bot_id": botId, "data": data])
    }

    private func sendSize(force: Bool) {
        guard store.canControl, attachedOnce, let terminal = view?.getTerminal(),
              terminal.cols > 1, terminal.rows > 1 else { return }
        let size = [terminal.cols, terminal.rows]
        guard force || size != lastSentSize else { return }
        lastSentSize = size
        var fields: JSONDict = ["bot_id": botId, "cols": terminal.cols, "rows": terminal.rows]
        if force { fields["force"] = true }
        store.client.send("resize", fields)
    }

    // MARK: TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // The keyboard sliding in and out fires a burst of layouts; each
        // resize makes the runtime repaint, so only the settled size is sent.
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.sendSize(force: false)
        }
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        type(String(decoding: data, as: UTF8.self))
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme ?? "") else { return }
        UIApplication.shared.open(url)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        UIPasteboard.general.string = String(decoding: content, as: UTF8.self)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

private struct TerminalHost: UIViewRepresentable {
    let controller: TerminalController

    func makeUIView(context: Context) -> PassiveTerminalView { controller.makeView() }
    func updateUIView(_ view: PassiveTerminalView, context: Context) {}
}

/// The bot's live Claude Code terminal, with phone-sized controls under it.
struct TerminalScreen: View {
    @Environment(AppStore.self) private var store
    let botId: String
    @State private var controller: TerminalController?
    @State private var failure: String?
    @State private var draft = ""
    /// Height of the controls with a one-line compose field.
    @State private var barHeight: CGFloat = 0
    @FocusState private var composing: Bool

    private static let keys: [(label: String, data: String)] = [
        ("esc", "\u{1b}"), ("⏎", "\r"), ("↑", "\u{1b}[A"), ("↓", "\u{1b}[B"),
        ("1", "1"), ("2", "2"), ("3", "3"), ("⇥", "\t"), ("⇧⇥", "\u{1b}[Z"),
        ("←", "\u{1b}[D"), ("→", "\u{1b}[C"), ("^C", "\u{03}"),
    ]

    var body: some View {
        // The controls float over the terminal's bottom edge rather than
        // stacking under it: a compose field growing by a line would
        // otherwise resize the pty, and every resize makes the bot repaint.
        ZStack(alignment: .bottom) {
            Group {
                if let controller {
                    TerminalHost(controller: controller)
                } else {
                    Color.clear
                }
            }
            .padding(.bottom, barHeight)
            .overlay {
                if let failure {
                    ContentUnavailableView("Terminal unavailable", systemImage: "terminal", description: Text(failure))
                        .environment(\.colorScheme, .dark)
                        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
                }
            }
            Group {
                if store.canControl { controls } else { readOnlyNote }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                barHeight = barHeight == 0 ? height : min(barHeight, height)
            }
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
        .onAppear {
            if controller == nil {
                let made = TerminalController(botId: botId, store: store)
                made.onFailure = { failure = $0 }
                controller = made
            }
        }
        .onDisappear {
            controller?.close()
            controller = nil
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.keys, id: \.label) { key in
                        Button(key.label) { controller?.type(key.data) }
                            .accessibilityLabel(accessibilityName(key.label))
                    }
                }
                .buttonStyle(KeyButtonStyle())
                .padding(.horizontal, 10)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message the bot's terminal", text: $draft, prompt: .placeholder("Message the bot's terminal"), axis: .vertical)
                    .lineLimit(1...5)
                    .focused($composing)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .foregroundStyle(.white)
                Button {
                    let text = draft
                    draft = ""
                    Task { await store.submitToTerminal(botId, text: text) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send to terminal")
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 8)
        .background(Color(white: 0.10))
        .environment(\.colorScheme, .dark)
    }

    private var readOnlyNote: some View {
        Text("This device can watch but not type: it needs control access.")
            .font(.footnote)
            .foregroundStyle(Color.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(Color(white: 0.10))
    }

    private func accessibilityName(_ label: String) -> String {
        switch label {
        case "esc": "Escape"
        case "⇧⇥": "Shift Tab"
        case "⇥": "Tab"
        case "←": "Left"
        case "→": "Right"
        case "↑": "Up"
        case "↓": "Down"
        case "⏎": "Return"
        case "^C": "Control C"
        default: label
        }
    }
}

private struct KeyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .frame(minWidth: 40, minHeight: 34)
            .padding(.horizontal, 4)
            .background(Color(white: configuration.isPressed ? 0.32 : 0.20),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
