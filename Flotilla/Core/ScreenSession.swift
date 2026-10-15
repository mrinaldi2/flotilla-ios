import CoreGraphics
import Foundation
import Observation
import UIKit

/// Where a computer's screen is and who signs in. The password is in the Keychain.
struct ScreenSettings {
    var host: String
    var port: Int
    /// Empty for a plain VNC password (Windows servers).
    var username: String
    var passwordAccount: String

    var password: String? {
        #if DEBUG
        // Simulator runs against demo/fake_screen.py: -screenPassword demo (-screen2Password for the second computer)
        let debugKey = passwordAccount.hasSuffix(".debug2") ? "screen2Password" : "screenPassword"
        if let password = UserDefaults.standard.string(forKey: debugKey) { return password }
        #endif
        return Keychain.load(account: passwordAccount)
    }
}

/// X11 keysyms VNC servers understand. On Windows, `command` (Super) is the Windows key.
enum Keysym {
    static let backspace: UInt32 = 0xFF08, tab: UInt32 = 0xFF09, returnKey: UInt32 = 0xFF0D
    static let escape: UInt32 = 0xFF1B, delete: UInt32 = 0xFFFF
    static let left: UInt32 = 0xFF51, up: UInt32 = 0xFF52, right: UInt32 = 0xFF53, down: UInt32 = 0xFF54
    static let pageUp: UInt32 = 0xFF55, pageDown: UInt32 = 0xFF56, f4: UInt32 = 0xFFC1
    static let shift: UInt32 = 0xFFE1, control: UInt32 = 0xFFE3, option: UInt32 = 0xFFE9, command: UInt32 = 0xFFEB

    static func of(_ scalar: Unicode.Scalar) -> UInt32 {
        switch scalar {
        case "\n", "\r": returnKey
        case "\t": tab
        default: scalar.value < 0x100 ? scalar.value : 0x0100_0000 | scalar.value
        }
    }
}

/// One live look at a computer's screen.
@MainActor
@Observable
final class ScreenSession {
    enum Phase: Equatable {
        case idle, connecting, signingIn
        case live(String)
        case failed(String)
    }

    struct Modifiers: OptionSet, Hashable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1)
        static let option = Modifiers(rawValue: 2)
        static let control = Modifiers(rawValue: 4)
        static let shift = Modifiers(rawValue: 8)
    }

    var phase: Phase = .idle
    /// The picture of the display in view (or the whole screen).
    var image: CGImage?
    /// Size of the Mac's whole picture, all displays together.
    var screenSize: CGSize {
        didSet { UserDefaults.standard.set([screenSize.width, screenSize.height], forKey: defaults.key("screenSize")) }
    }
    var stats: RFBClient.Stats?
    /// Latched modifiers, applied to the next key and then released.
    var modifiers: Modifiers = []
    /// Text the Mac put on its clipboard, until dismissed.
    var macClipboard: String?
    /// Where the last tap landed, in screen pixels.
    var lastTap: CGPoint?
    /// How macOS arranges the displays, from Gravity Lens. Remembered, so the
    /// very first request after launching asks for one display only.
    var layout: [MacDisplay] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(layout), forKey: defaults.key("screenLayout")) }
    }
    /// Which display fills the phone.
    var focus: Int? {
        didSet {
            UserDefaults.standard.set(focus, forKey: defaults.key("screenFocus"))
            regionChanged()
        }
    }
    @ObservationIgnored private let defaults: ComputerDefaults

    init(defaults: ComputerDefaults) {
        self.defaults = defaults
        let saved = UserDefaults.standard
        let pair = saved.array(forKey: defaults.key("screenSize")) as? [Double] ?? []
        screenSize = pair.count == 2 ? CGSize(width: pair[0], height: pair[1]) : .zero
        layout = saved.data(forKey: defaults.key("screenLayout"))
            .flatMap { try? JSONDecoder().decode([MacDisplay].self, from: $0) } ?? []
        focus = saved.object(forKey: defaults.key("screenFocus")) as? Int
    }
    /// The last picture of each region, shown at once when switching or reconnecting.
    @ObservationIgnored private var remembered: [CGRect: CGImage] = [:]
    @ObservationIgnored private var paused = true

    @ObservationIgnored private var client: RFBClient?
    @ObservationIgnored private var pointer = CGPoint.zero

    var size: CGSize { screenSize }

    /// Each display's rectangle within the shared picture, left to right.
    /// Screen Sharing sends every display as one image covering their
    /// combined bounds.
    var displays: [CGRect] {
        guard size.width > 0 else { return [] }
        if layout.count > 1 {
            let union = layout.map(\.frame).reduce(CGRect.null) { $0.union($1) }
            let scale = size.width / union.width
            return layout.map { display in
                CGRect(x: (display.x - union.minX) * scale, y: (display.y - union.minY) * scale,
                       width: display.width * scale, height: display.height * scale).integral
            }
        }
        // Without Gravity Lens: a picture far wider than any one screen is
        // most likely two side by side.
        if layout.isEmpty, size.width / size.height > 2.5 {
            let half = (size.width / 2).rounded()
            return [CGRect(x: 0, y: 0, width: half, height: size.height),
                    CGRect(x: half, y: 0, width: size.width - half, height: size.height)]
        }
        return []
    }

    /// Short names for the display switch: Left and Right, or numbers.
    var displayNames: [String] {
        let rects = displays
        guard rects.count > 1 else { return [] }
        if rects.count == 2 {
            let (a, b) = (rects[0], rects[1])
            if abs(a.midY - b.midY) < abs(a.midX - b.midX) {
                return a.midX < b.midX ? ["Left", "Right"] : ["Right", "Left"]
            }
            return a.midY < b.midY ? ["Top", "Bottom"] : ["Bottom", "Top"]
        }
        return rects.indices.map { String($0 + 1) }
    }

    /// The part of the Mac's picture on the phone: one display, or all of it
    /// when there is only one.
    var focusRect: CGRect? {
        let rects = displays
        guard rects.count > 1 else { return nil }
        let index = focus.flatMap { rects.indices.contains($0) ? $0 : nil } ?? mainIndex
        return rects[index]
    }

    private var mainIndex: Int { layout.firstIndex(where: \.main) ?? 0 }

    func setLayout(_ layout: [MacDisplay]) {
        guard layout != self.layout else { return }
        self.layout = layout
        regionChanged()
    }

    /// Tells the client which part to keep current, and shows what we already have of it.
    private func regionChanged() {
        let region = focusRect
        if let known = remembered[region ?? .null] { image = known } else if region != nil { image = nil }
        client?.setRegion(region)
    }

    // MARK: Being looked at

    /// The screen view appeared: resume a live connection, or connect.
    func show(_ settings: ScreenSettings) {
        paused = false
        switch phase {
        case .live:
            client?.setPaused(false)
        case .connecting, .signingIn:
            break
        case .idle, .failed:
            connect(settings)
        }
    }

    /// The screen view went away or the app left the foreground. The Mac
    /// stops sending, but the connection stays signed in for next time.
    func hide() {
        paused = true
        client?.setPaused(true)
    }

    func connect(_ settings: ScreenSettings) {
        disconnect()
        guard let password = settings.password, !password.isEmpty else {
            phase = .failed("Add the screen's sign-in in Settings → Screen.")
            return
        }
        let client = RFBClient(host: settings.host, port: settings.port,
                               credentials: .init(username: settings.username, password: password),
                               fastColours: UserDefaults.standard.bool(forKey: "screenFastColours"))
        client.onState = { [weak self] state in self?.stateChanged(state) }
        client.onImage = { [weak self] image in self?.received(image) }
        client.onStats = { [weak self] stats in self?.stats = stats }
        // Known from an earlier connection: ask for just that display from the start.
        client.setRegion(focusRect)
        client.onClipboard = { [weak self] text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { self?.macClipboard = trimmed }
        }
        self.client = client
        client.start()
    }

    func disconnect() {
        client?.stop()
        client = nil
        if case .failed = phase { return }
        phase = .idle
    }

    private func received(_ image: CGImage) {
        // A picture for a region we have since switched away from is dropped.
        let region = focusRect
        let expected = region.map { (Int($0.width), Int($0.height)) } ?? (Int(screenSize.width), Int(screenSize.height))
        guard (image.width, image.height) == expected else { return }
        self.image = image
        remembered[region ?? .null] = image
    }

    private func stateChanged(_ state: RFBClient.State) {
        switch state {
        case .connecting: phase = .connecting
        case .signingIn: phase = .signingIn
        case .connected(let name, let width, let height):
            screenSize = CGSize(width: width, height: height)
            phase = .live(name)
            client?.setRegion(focusRect)
            client?.setPaused(paused)
        case .failed(let message):
            // Dropped while nobody was looking (the app was in the background):
            // reconnect quietly next time instead of showing an error.
            phase = paused ? .idle : .failed(message)
            client = nil
        case .closed:
            if case .live = phase { phase = .idle }
        }
    }

    // MARK: Pointer

    private func at(_ point: CGPoint) -> (Int, Int) {
        let x = Int(max(0, min(point.x, size.width - 1)))
        let y = Int(max(0, min(point.y, size.height - 1)))
        pointer = CGPoint(x: x, y: y)
        return (x, y)
    }

    func move(to point: CGPoint) {
        let (x, y) = at(point)
        client?.pointer(x: x, y: y, buttons: 0)
    }

    func click(at point: CGPoint, button: UInt8 = 1, count: Int = 1) {
        let (x, y) = at(point)
        lastTap = pointer
        withModifiers {
            client?.pointer(x: x, y: y, buttons: 0)
            for _ in 0..<count {
                client?.pointer(x: x, y: y, buttons: button)
                client?.pointer(x: x, y: y, buttons: 0)
            }
        }
    }

    func drag(from start: CGPoint, to end: CGPoint, ended: Bool) {
        let (sx, sy) = at(start)
        let (ex, ey) = at(end)
        client?.pointer(x: sx, y: sy, buttons: 1)
        client?.pointer(x: ex, y: ey, buttons: ended ? 0 : 1)
    }

    /// Positive lines scroll the content down (wheel towards you).
    func scroll(lines: Int) {
        let (x, y) = (Int(pointer.x), Int(pointer.y))
        let button: UInt8 = lines > 0 ? 16 : 8
        for _ in 0..<abs(lines) {
            client?.pointer(x: x, y: y, buttons: button)
            client?.pointer(x: x, y: y, buttons: 0)
        }
    }

    // MARK: Keyboard

    func type(_ text: String) {
        for scalar in text.unicodeScalars { press(Keysym.of(scalar)) }
    }

    func press(_ keysym: UInt32) {
        withModifiers {
            client?.key(keysym, down: true)
            client?.key(keysym, down: false)
        }
    }

    func toggle(_ modifier: Modifiers) {
        if modifiers.contains(modifier) { modifiers.remove(modifier) } else { modifiers.insert(modifier) }
    }

    /// A shortcut such as ⌘C, whatever is latched.
    func shortcut(_ keysym: UInt32, _ held: Modifiers) {
        let saved = modifiers
        modifiers = held
        press(keysym)
        modifiers = saved
    }

    private func withModifiers(_ body: () -> Void) {
        let keys: [(Modifiers, UInt32)] = [(.command, Keysym.command), (.option, Keysym.option),
                                           (.control, Keysym.control), (.shift, Keysym.shift)]
        let held = keys.filter { modifiers.contains($0.0) }.map(\.1)
        for key in held { client?.key(key, down: true) }
        body()
        for key in held.reversed() { client?.key(key, down: false) }
        modifiers = []
    }

    // MARK: Clipboard

    func pasteToMac(_ text: String) {
        client?.sendClipboard(text)
    }
}
