import SwiftUI
import UIKit

/// A computer's screen, live: pinch to zoom, drag to pan, tap to click.
struct ScreenView: View {
    @Environment(Computer.self) private var computer
    @Environment(LensStore.self) private var lens
    @Environment(ScreenSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var canvas = CanvasController()
    @State private var sendItem: SendItem?
    @State private var showingKeyboard = false
    @State private var dictation = Dictation()
    /// The dictation panel is open: listening, or showing what was heard.
    @State private var dictating = false

    private var settings: ScreenSettings { computer.screenSettings }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(white: 0.08)
                if session.image != nil {
                    ScreenCanvas(session: session, controller: canvas)
                } else {
                    placeholder
                }
                if session.image != nil, session.phase != .idle, !isLive {
                    // An earlier picture is on screen while the connection comes back.
                    VStack {
                        Spacer()
                        Label(waitingText, systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .environment(\.colorScheme, .dark)
                            .padding(.bottom, 12)
                    }
                }
            }
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    displayPicker
                    clipboardBanner
                }
            }
            if case .live = session.phase {
                if dictating {
                    DictationPanel(dictation: dictation, target: computer.name) { text, submit in
                        session.type(text)
                        if submit { session.press(Keysym.returnKey) }
                        dictating = false
                    } cancel: {
                        dictation.cancel()
                        dictating = false
                    }
                }
                KeyRow(session: session, canvas: canvas, kind: computer.kind, keyboard: $showingKeyboard) {
                    dictating = true
                    dictation.clearError()
                    Task { await dictation.start() }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { statusBadge }
        }
        .onAppear { session.show(settings) }
        .onDisappear {
            session.hide()
            dictation.cancel()
            dictating = false
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { session.show(settings) } else { session.hide() }
        }
        .task(id: session.phase) {
            guard case .live = session.phase else { return }
            if let layout = try? await lens.displays() { session.setLayout(layout) }
        }
        .sheet(item: $sendItem) { SendToBotSheet(text: $0.text) }
        .animation(.snappy, value: session.macClipboard)
    }

    @ViewBuilder private var placeholder: some View {
        switch session.phase {
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't show the screen", systemImage: "display.trianglebadge.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { session.connect(settings) }.buttonStyle(.borderedProminent)
            }
            .environment(\.colorScheme, .dark)
        default:
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text(waitingText)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private var isLive: Bool {
        if case .live = session.phase { return true }
        return false
    }

    private var waitingText: String {
        switch session.phase {
        case .signingIn: "Signing in…"
        case .live: "Waiting for the first picture…"
        default: "Connecting to \(computer.name)…"
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch session.phase {
        case .live:
            Button { canvas.fit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .accessibilityLabel("Fit the screen")
        case .failed:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        default:
            ProgressView()
        }
    }

    /// One display at a time, filling the phone.
    @ViewBuilder private var displayPicker: some View {
        let names = session.displayNames
        if names.count > 1 {
            let current = session.focusRect.flatMap { session.displays.firstIndex(of: $0) } ?? 0
            Picker("Display", selection: Binding(get: { current }, set: { session.focus = $0 })) {
                ForEach(Array(names.enumerated()), id: \.offset) { index, name in Text(name).tag(index) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)
            .padding(6)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
            .padding(.top, 8)
        }
    }

    @ViewBuilder private var clipboardBanner: some View {
        if let text = session.macClipboard {
            VStack(alignment: .leading, spacing: 8) {
                Label("\(computer.name) copied", systemImage: "doc.on.clipboard").font(.caption.weight(.semibold))
                Text(text).font(.footnote.monospaced()).lineLimit(3)
                HStack {
                    Button("Copy") {
                        UIPasteboard.general.string = text
                        session.macClipboard = nil
                    }
                    Button("Send to bot") {
                        sendItem = SendItem(text: text)
                        session.macClipboard = nil
                    }
                    Spacer()
                    Button { session.macClipboard = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Dismiss")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(10)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: Canvas

/// Lets SwiftUI buttons reach into the UIKit canvas.
@MainActor
final class CanvasController {
    weak var view: ScreenCanvasView?
    func fit() { view?.fit(animated: true) }
    func toggleKeyboard() -> Bool { view?.toggleKeyboard() ?? false }
}

private struct ScreenCanvas: UIViewRepresentable {
    let session: ScreenSession
    let controller: CanvasController

    func makeUIView(context: Context) -> ScreenCanvasView {
        let view = ScreenCanvasView(session: session)
        controller.view = view
        return view
    }

    func updateUIView(_ view: ScreenCanvasView, context: Context) {
        view.show(session.image, tap: session.lastTap, origin: session.focusRect?.origin ?? .zero)
    }
}

final class ScreenCanvasView: UIView, UIScrollViewDelegate {
    private let session: ScreenSession
    private let scroll = UIScrollView()
    private let screen = UIImageView()
    private let marker = CAShapeLayer()
    private let keys = KeyCaptureView()
    private var shownSize = CGSize.zero
    /// Where the part on screen starts within the Mac's whole picture.
    private var offset = CGPoint.zero

    init(session: ScreenSession) {
        self.session = session
        super.init(frame: .zero)
        scroll.delegate = self
        scroll.maximumZoomScale = 4
        scroll.bouncesZoom = true
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        addSubview(scroll)
        screen.isUserInteractionEnabled = true
        screen.layer.magnificationFilter = .trilinear
        scroll.addSubview(screen)

        marker.fillColor = UIColor.systemBlue.withAlphaComponent(0.25).cgColor
        marker.strokeColor = UIColor.systemBlue.cgColor
        marker.lineWidth = 2
        marker.opacity = 0
        screen.layer.addSublayer(marker)

        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: self, action: #selector(tapped))
        single.require(toFail: double)
        let long = UILongPressGestureRecognizer(target: self, action: #selector(pressed))
        let twoFinger = UITapGestureRecognizer(target: self, action: #selector(rightTapped))
        twoFinger.numberOfTouchesRequired = 2
        [double, single, long, twoFinger].forEach(screen.addGestureRecognizer)

        keys.session = session
        addSubview(keys)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard scroll.frame.size != bounds.size else { return }
        // Fully zoomed out stays fully zoomed out; a chosen zoom survives the
        // keyboard or a rotation.
        let wasFitted = scroll.zoomScale <= scroll.minimumZoomScale + 0.001
        scroll.frame = bounds
        if wasFitted {
            fit(animated: false)
        } else {
            updateMinimum()
            center()
        }
    }

    private func updateMinimum() {
        guard shownSize.width > 0, bounds.width > 0 else { return }
        scroll.minimumZoomScale = min(bounds.width / shownSize.width, bounds.height / shownSize.height)
    }

    /// `image` is the part of the Mac's picture that starts at `origin`.
    func show(_ image: CGImage?, tap: CGPoint?, origin: CGPoint) {
        guard let image else { return }
        let switched = origin != offset
        offset = origin
        screen.image = UIImage(cgImage: image)
        let size = CGSize(width: image.width, height: image.height)
        if size != shownSize || switched {
            // The frame must be set at zoom 1: setting it on a zoomed view
            // stretches it, which is what broke zooming after a switch.
            scroll.zoomScale = 1
            shownSize = size
            screen.frame = CGRect(origin: .zero, size: size)
            scroll.contentSize = size
            fit(animated: false)
        }
        if let tap { flash(at: CGPoint(x: tap.x - offset.x, y: tap.y - offset.y)) }
    }

    func fit(animated: Bool) {
        guard shownSize.width > 0, bounds.width > 0 else { return }
        updateMinimum()
        scroll.setZoomScale(scroll.minimumZoomScale, animated: animated)
        center()
    }

    func toggleKeyboard() -> Bool {
        if keys.isFirstResponder { keys.resignFirstResponder(); return false }
        keys.becomeFirstResponder()
        return true
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { screen }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

    /// Keeps the screen centred when it is smaller than the view.
    private func center() {
        let content = scroll.contentSize
        let x = max(0, (scroll.bounds.width - content.width) / 2)
        let y = max(0, (scroll.bounds.height - content.height) / 2)
        scroll.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    private var lastFlash: CGPoint?

    private func flash(at point: CGPoint) {
        guard point != lastFlash else { return }
        lastFlash = point
        let radius = 14 / max(scroll.zoomScale, 0.1)
        marker.lineWidth = 2 / max(scroll.zoomScale, 0.1)
        marker.path = UIBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                  width: radius * 2, height: radius * 2)).cgPath
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.6
        marker.add(fade, forKey: "flash")
    }

    // MARK: Gestures

    /// A touch on the phone, as a point on the Mac's whole picture.
    private func mac(_ gesture: UIGestureRecognizer) -> CGPoint {
        let point = gesture.location(in: screen)
        return CGPoint(x: point.x + offset.x, y: point.y + offset.y)
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        session.click(at: mac(gesture))
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        session.click(at: mac(gesture), count: 2)
    }

    @objc private func rightTapped(_ gesture: UITapGestureRecognizer) {
        session.click(at: mac(gesture), button: 4)
    }

    @objc private func pressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        session.click(at: mac(gesture), button: 4)
    }
}

/// An invisible text target: whatever the iOS keyboard types goes to the Mac.
final class KeyCaptureView: UIView, UIKeyInput {
    weak var session: ScreenSession?

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable

    func insertText(_ text: String) {
        MainActor.assumeIsolated { session?.type(text) }
    }

    func deleteBackward() {
        MainActor.assumeIsolated { session?.press(Keysym.backspace) }
    }
}

// MARK: Keys

private struct KeyRow: View {
    let session: ScreenSession
    let canvas: CanvasController
    let kind: ComputerKind
    @Binding var keyboard: Bool
    /// Talk, and what you said is typed on the computer.
    let dictate: () -> Void
    @State private var pasteText = ""

    /// On Windows, `command` (Super) is the Windows key and `option` is Alt.
    private var modifiers: [(String, ScreenSession.Modifiers, String)] {
        switch kind {
        case .mac:
            [("⌘", .command, "Command"), ("⌥", .option, "Option"), ("⌃", .control, "Control"), ("⇧", .shift, "Shift")]
        case .windows:
            [("Ctrl", .control, "Control"), ("⊞", .command, "Windows key"), ("Alt", .option, "Alt"), ("⇧", .shift, "Shift")]
        }
    }
    private let keys: [(String, UInt32, String)] = [
        ("esc", Keysym.escape, "Escape"), ("⇥", Keysym.tab, "Tab"), ("⏎", Keysym.returnKey, "Return"),
        ("←", Keysym.left, "Left"), ("↑", Keysym.up, "Up"), ("↓", Keysym.down, "Down"), ("→", Keysym.right, "Right"),
        ("⌫", Keysym.backspace, "Delete"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button { keyboard = canvas.toggleKeyboard() } label: {
                    Image(systemName: keyboard ? "keyboard.chevron.compact.down" : "keyboard")
                }
                .accessibilityLabel(keyboard ? "Hide keyboard" : "Show keyboard")
                Button(action: dictate) { Image(systemName: "mic") }
                    .accessibilityLabel("Dictate text to type")
                ForEach(modifiers, id: \.0) { label, modifier, name in
                    Button(label) { session.toggle(modifier) }
                        .background(session.modifiers.contains(modifier) ? Color.accentColor : .clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityLabel(name)
                        .accessibilityAddTraits(session.modifiers.contains(modifier) ? .isSelected : [])
                }
                ForEach(keys, id: \.0) { label, keysym, name in
                    Button(label) { session.press(keysym) }.accessibilityLabel(name)
                }
                Button { session.scroll(lines: -3) } label: { Image(systemName: "chevron.up.2") }
                    .accessibilityLabel("Scroll up")
                Button { session.scroll(lines: 3) } label: { Image(systemName: "chevron.down.2") }
                    .accessibilityLabel("Scroll down")
                Menu {
                    shortcuts
                    Divider()
                    Button("Send this phone's clipboard to the \(kind.label)") {
                        if let text = UIPasteboard.general.string { session.pasteToMac(text) }
                    }
                } label: {
                    Image(systemName: "command")
                }
                .accessibilityLabel("Shortcuts")
            }
            .buttonStyle(ScreenKeyStyle())
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color(white: 0.12))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var shortcuts: some View {
        switch kind {
        case .mac:
            Button("Copy  ⌘C") { session.shortcut(0x63, .command) }
            Button("Paste  ⌘V") { session.shortcut(0x76, .command) }
            Button("Copy path (Finder)  ⌥⌘C") { session.shortcut(0x63, [.command, .option]) }
            Button("Spotlight  ⌘Space") { session.shortcut(0x20, .command) }
            Button("Switch app  ⌘Tab") { session.shortcut(Keysym.tab, .command) }
            Button("Close window  ⌘W") { session.shortcut(0x77, .command) }
            Button("Go to folder (Finder)  ⇧⌘G") { session.shortcut(0x67, [.command, .shift]) }
        case .windows:
            Button("Copy  Ctrl+C") { session.shortcut(0x63, .control) }
            Button("Paste  Ctrl+V") { session.shortcut(0x76, .control) }
            Button("Copy as path (Explorer)  Ctrl+Shift+C") { session.shortcut(0x63, [.control, .shift]) }
            Button("Start menu  ⊞") { session.shortcut(Keysym.command, []) }
            Button("Search  ⊞S") { session.shortcut(0x73, .command) }
            Button("Switch app  Alt+Tab") { session.shortcut(Keysym.tab, .option) }
            Button("Close window  Alt+F4") { session.shortcut(Keysym.f4, .option) }
            Button("File Explorer  ⊞E") { session.shortcut(0x65, .command) }
            Button("Address bar (Explorer)  Ctrl+L") { session.shortcut(0x6C, .control) }
            Button("Task Manager  Ctrl+Shift+Esc") { session.shortcut(Keysym.escape, [.control, .shift]) }
        }
    }
}

/// What dictation heard, before it is typed on the computer.
private struct DictationPanel: View {
    let dictation: Dictation
    let target: String
    let type: (String, Bool) -> Void
    let cancel: () -> Void

    private var heard: String { dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if dictation.isListening {
                    Image(systemName: "waveform").symbolEffect(.variableColor.iterative, isActive: true).foregroundStyle(.red)
                    Text("Listening…").font(.caption.weight(.semibold))
                } else if case .failed(let reason) = dictation.phase {
                    Text(reason).font(.caption).foregroundStyle(Color.warningText)
                } else {
                    Text("Type this on \(target)?").font(.caption.weight(.semibold))
                }
                Spacer()
                if dictation.isListening {
                    Button("Stop") { dictation.stop() }.font(.caption.weight(.semibold))
                }
            }
            Text(heard.isEmpty ? "Say what to type." : heard)
                .font(.body)
                .foregroundStyle(heard.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("Cancel", role: .cancel, action: cancel)
                Spacer()
                Button("Type") { type(dictation.stop(), false) }
                    .disabled(heard.isEmpty)
                Button("Type + ⏎") { type(dictation.stop(), true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(heard.isEmpty)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(.regularMaterial)
        .environment(\.colorScheme, .dark)
    }
}

private struct ScreenKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.white)
            .frame(minWidth: 40, minHeight: 36)
            .padding(.horizontal, 2)
            .background(Color(white: configuration.isPressed ? 0.34 : 0.22),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
