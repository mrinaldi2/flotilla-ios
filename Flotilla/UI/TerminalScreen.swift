import SwiftTerm
import SwiftUI
import UIKit

/// The desktop's terminal colours (xterm.js theme in TerminalPane.tsx).
enum TerminalTheme {
    static let background = UIColor(red: 0x10 / 255, green: 0x11 / 255, blue: 0x16 / 255, alpha: 1)
    static let foreground = UIColor(red: 0xd8 / 255, green: 0xda / 255, blue: 0xe2 / 255, alpha: 1)
    static let cursor = UIColor(red: 0x7a / 255, green: 0xa2 / 255, blue: 0xf7 / 255, alpha: 1)
    static let selection = UIColor(red: 0x33 / 255, green: 0x40 / 255, blue: 0x5e / 255, alpha: 1)
    /// Lines kept above the screen, as on the desktop.
    static let scrollback = 8000
}

/// SwiftTerm's view, typed into directly when this device may type.
final class BotTerminalView: TerminalView, TerminalDisplay {
    /// Off without the control grant, or once the bot's computer refused typing.
    var typingAllowed = false {
        didSet { if !typingAllowed, isFirstResponder { _ = resignFirstResponder() } }
    }
    var onFocusChange: ((Bool) -> Void)?

    override var canBecomeFirstResponder: Bool { typingAllowed }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    /// A steady cursor whatever the runtime asks for: a blink is an animation
    /// that never ends, on a phone's battery.
    override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        let steady: CursorStyle = switch newStyle {
        case .blinkBlock: .steadyBlock
        case .blinkUnderline: .steadyUnderline
        case .blinkBar: .steadyBar
        default: newStyle
        }
        super.cursorStyleChanged(source: source, newStyle: steady)
    }

    // MARK: TerminalDisplay

    func reset() { feed(text: "\u{1b}c") }
    func write(_ data: String) { feed(text: data) }

    // MARK: Accessibility

    /// The rows on screen, so VoiceOver (and the UI tests) can read them.
    override var accessibilityValue: String? {
        get {
            let terminal = getTerminal()
            return (0..<terminal.rows)
                .compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
        }
        set {}
    }
}

/// The keys a terminal needs that the iPhone keyboard lacks, above it.
final class TerminalKeys: UIInputView {
    private weak var terminal: BotTerminalView?
    private var controlButton: UIButton?
    private var repeatTimer: Timer?

    private enum Key {
        case text(String)
        case arrow(Character)
        case control
    }

    private static let keys: [(label: String, name: String, id: String, key: Key)] = [
        ("esc", "Escape", "esc", .text("\u{1b}")),
        ("ctrl", "Control", "ctrl", .control),
        ("⇥", "Tab", "tab", .text("\t")),
        ("⇧⇥", "Shift Tab", "shift-tab", .text("\u{1b}[Z")),
        ("←", "Left", "left", .arrow("D")),
        ("↓", "Down", "down", .arrow("B")),
        ("↑", "Up", "up", .arrow("A")),
        ("→", "Right", "right", .arrow("C")),
        ("^C", "Control C", "ctrl-c", .text("\u{03}")),
        ("|", "Pipe", "pipe", .text("|")),
        ("/", "Slash", "slash", .text("/")),
        ("-", "Dash", "dash", .text("-")),
        ("~", "Tilde", "tilde", .text("~")),
    ]

    init(terminal: BotTerminalView) {
        self.terminal = terminal
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 46), inputViewStyle: .keyboard)
        autoresizingMask = .flexibleWidth
        overrideUserInterfaceStyle = .dark
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(controlWasReset),
                                               name: .terminalViewControlModifierReset, object: terminal)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 46) }

    private func build() {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        for (index, entry) in Self.keys.enumerated() {
            let button = makeButton(entry.label)
            button.tag = index
            button.accessibilityLabel = entry.name
            button.accessibilityIdentifier = "terminal-key-\(entry.id)"
            switch entry.key {
            case .control:
                button.changesSelectionAsPrimaryAction = true
                button.addTarget(self, action: #selector(toggleControl), for: .primaryActionTriggered)
                controlButton = button
            case .arrow:
                // Held, an arrow repeats the way a hardware key does.
                button.addTarget(self, action: #selector(arrowDown), for: .touchDown)
                button.addTarget(self, action: #selector(arrowUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
            case .text:
                button.addTarget(self, action: #selector(tapped), for: .touchUpInside)
            }
            row.addArrangedSubview(button)
        }

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false

        let hide = makeButton(nil, symbol: "keyboard.chevron.compact.down")
        hide.accessibilityLabel = "Hide keyboard"
        hide.accessibilityIdentifier = "terminal-key-hide"
        hide.addTarget(self, action: #selector(hideKeyboard), for: .touchUpInside)

        let bar = UIStackView(arrangedSubviews: [scroll, hide])
        bar.spacing = 6
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 6),
            bar.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    private func makeButton(_ title: String?, symbol: String? = nil) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = UIColor(white: 0.24, alpha: 1)
        config.baseForegroundColor = .white
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        if let symbol { config.image = UIImage(systemName: symbol) }
        if let title {
            var text = AttributedString(title)
            text.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .medium)
            config.attributedTitle = text
        }
        let button = UIButton(configuration: config)
        button.configurationUpdateHandler = { button in
            guard var config = button.configuration else { return }
            config.baseBackgroundColor = button.isSelected ? TerminalTheme.cursor
                : UIColor(white: button.isHighlighted ? 0.36 : 0.24, alpha: 1)
            button.configuration = config
        }
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        return button
    }

    private func send(_ key: Key) {
        guard let terminal else { return }
        UIDevice.current.playInputClick()
        switch key {
        case .text(let data):
            terminal.send(txt: data)
        case .arrow(let letter):
            // Full-screen programs ask for application cursor keys.
            let prefix = terminal.getTerminal().applicationCursor ? "\u{1b}O" : "\u{1b}["
            terminal.send(txt: prefix + String(letter))
        case .control:
            break
        }
    }

    @objc private func tapped(_ sender: UIButton) { send(Self.keys[sender.tag].key) }

    @objc private func toggleControl(_ sender: UIButton) {
        // The next key typed goes as its control character, then this lets go.
        terminal?.controlModifier = sender.isSelected
    }

    @objc private func controlWasReset() { controlButton?.isSelected = false }

    @objc private func arrowDown(_ sender: UIButton) {
        let key = Self.keys[sender.tag].key
        send(key)
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                    MainActor.assumeIsolated { self?.send(key) }
                }
            }
        }
    }

    @objc private func arrowUp(_ sender: UIButton) {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    @objc private func hideKeyboard() { _ = terminal?.resignFirstResponder() }
}

extension TerminalKeys: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

/// Bridges one bot's pty stream to a SwiftTerm view: attach with a replay
/// cursor, feed `term` pushes in order, send keystrokes and size changes back.
@MainActor
final class TerminalController: NSObject, @preconcurrency TerminalViewDelegate {
    let botId: String
    let feed: TerminalFeed
    private let store: AppStore
    private(set) var view: BotTerminalView?
    private var attachedOnce = false
    private var lastSentSize: [Int] = []
    private var resizeTask: Task<Void, Never>?
    /// Why attaching failed (a linked bot's machine is offline), or nil once attached.
    var onFailure: ((String?) -> Void)?
    /// The bot's computer refused typing from here, in its words.
    var onRefused: ((String) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    init(botId: String, store: AppStore) {
        self.botId = botId
        self.store = store
        feed = TerminalFeed(botId: botId)
        super.init()
        feed.onReattach = { [weak self] in self?.attach() }
        feed.onAttached = { [weak self] resumed in
            self?.attachedOnce = true
            // A replay from scratch rebuilds only what the ring still holds:
            // a forced resize makes the runtime repaint the rest.
            self?.sendSize(force: !resumed)
        }
        feed.onRefused = { [weak self] message in self?.onRefused?(message) }
    }

    func makeView(typingAllowed: Bool) -> BotTerminalView {
        let terminal = BotTerminalView(frame: .zero)
        terminal.font = UIFont.monospacedSystemFont(ofSize: Self.fontSize, weight: .regular)
        terminal.getTerminal().changeHistorySize(TerminalTheme.scrollback)
        terminal.getTerminal().setCursorStyle(.steadyBlock)
        terminal.nativeBackgroundColor = TerminalTheme.background
        terminal.nativeForegroundColor = TerminalTheme.foreground
        terminal.caretColor = TerminalTheme.cursor
        terminal.selectedTextBackgroundColor = TerminalTheme.selection
        terminal.keyboardAppearance = .dark
        // Dragging scrolls back through the output rather than reporting the
        // mouse to the runtime.
        terminal.allowMouseReporting = false
        terminal.typingAllowed = typingAllowed
        terminal.inputAccessoryView = TerminalKeys(terminal: terminal)
        terminal.isAccessibilityElement = true
        terminal.accessibilityLabel = "Terminal"
        terminal.accessibilityIdentifier = "bot-terminal"
        terminal.onFocusChange = { [weak self] in self?.onFocusChange?($0) }
        terminal.terminalDelegate = self
        view = terminal
        feed.display = terminal
        store.register(feed, for: botId)
        attach()
        return terminal
    }

    static var fontSize: CGFloat {
        let saved = UserDefaults.standard.double(forKey: "terminalFontSize")
        return saved == 0 ? 11 : saved
    }

    func focus() { _ = view?.becomeFirstResponder() }

    func close() {
        resizeTask?.cancel()
        _ = view?.resignFirstResponder()
        store.unregister(feed, for: botId)
    }

    // MARK: Stream

    private func attach() {
        let fields = feed.attachFields()
        Task {
            do {
                _ = try await store.client.request("attach", fields)
                onFailure?(nil)
            } catch let error as DaemonError where error.code == "unavailable" {
                feed.attachFailed()
                let machine = store.bot(botId)?.peerName ?? "Its computer"
                onFailure?("\(machine) is offline. The terminal shows here again when it is back.")
            } catch let error as DaemonError where error.code != "not_connected" {
                feed.attachFailed()
                onFailure?(error.message)
            } catch {
                feed.attachFailed()
            }
        }
    }

    // MARK: Size

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
        // The keyboard sliding in and out, or a rotation, fires a burst of
        // layouts; each resize makes the runtime repaint, so only the settled
        // size is sent.
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.sendSize(force: false)
        }
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard view?.typingAllowed == true else { return }
        store.typeIntoTerminal(botId, data: String(decoding: data, as: UTF8.self))
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
    let typingAllowed: Bool

    func makeUIView(context: Context) -> BotTerminalView { controller.makeView(typingAllowed: typingAllowed) }
    func updateUIView(_ view: BotTerminalView, context: Context) { view.typingAllowed = typingAllowed }
}

/// The bot's live terminal: typed into directly, with the terminal's keys
/// above the keyboard. An asleep bot has none, so it offers Wake now instead.
struct TerminalScreen: View {
    @Environment(AppStore.self) private var store
    let botId: String

    var body: some View {
        if let bot = store.bot(botId), store.hasTeamOnDemand, bot.state.isAsleep {
            TerminalAsleep(bot: bot)
        } else {
            LiveTerminal(botId: botId)
        }
    }
}

private struct TerminalAsleep: View {
    let bot: Bot

    var body: some View {
        ContentUnavailableView {
            Label(bot.state == .queued ? "Waiting for a slot" : "Asleep", systemImage: "moon.zzz")
        } description: {
            Text("\(bot.name) has no terminal while it sleeps. It shows here as soon as the bot is up.")
        } actions: {
            BotRestBanner(bot: bot)
        }
        .accessibilityIdentifier("terminal-asleep")
    }
}

private struct LiveTerminal: View {
    @Environment(AppStore.self) private var store
    let botId: String
    @State private var controller: TerminalController?
    @State private var failure: String?
    @State private var refusal: String?
    @State private var typing = false

    private var typingAllowed: Bool { store.canControl && refusal == nil }

    private var note: String? {
        if !store.canControl { return "This device can watch but not type: it needs control access." }
        return refusal
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                if let controller {
                    TerminalHost(controller: controller, typingAllowed: typingAllowed)
                } else {
                    Color(TerminalTheme.background)
                }
                if typingAllowed, !typing, failure == nil, controller != nil {
                    Button { controller?.focus() } label: {
                        Image(systemName: "keyboard")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(Color(white: 0.24), in: Circle())
                    }
                    .padding(14)
                    .accessibilityLabel("Type into the terminal")
                    .accessibilityIdentifier("terminal-type")
                }
            }
            .overlay {
                if let failure {
                    ContentUnavailableView("Terminal unavailable", systemImage: "terminal", description: Text(failure))
                        .environment(\.colorScheme, .dark)
                        .background(Color(TerminalTheme.background))
                }
            }
            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(Color.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(Color(white: 0.10))
                    .accessibilityIdentifier("terminal-note")
            }
        }
        .background(Color(TerminalTheme.background))
        .onAppear {
            if controller == nil {
                let made = TerminalController(botId: botId, store: store)
                made.onFailure = { failure = $0 }
                made.onRefused = { refusal = $0 }
                made.onFocusChange = { typing = $0 }
                controller = made
            }
        }
        .onDisappear {
            controller?.close()
            controller = nil
        }
    }
}
