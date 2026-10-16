import SwiftUI

extension Color {
    init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}

/// `icon:<name>` shows Gravity's own icon art (bundled from the MIT-licensed
/// desktop app), `color:#rrggbb` a swatch with the initial, empty a colour
/// derived from the name.
struct AvatarView: View {
    let avatar: String
    let name: String
    var size: CGFloat = 40

    /// The twenty icons a bot can name, in the desktop's order.
    static let icons = ["orbit", "ember", "moss", "nova", "tide", "quartz", "volt", "dusk", "copper", "frost",
                        "halo", "glitch", "slate", "bloom", "echo", "pixel", "rune", "cloud", "comet", "mint"]

    private static let iconColors: [String: String] = [
        "orbit": "#6C8CFF", "ember": "#FF6B4A", "moss": "#5FA56B", "nova": "#C77DFF",
        "tide": "#2FA4C7", "quartz": "#D98CB3", "volt": "#E5C100", "dusk": "#7A6BD1",
        "copper": "#C9773F", "frost": "#7FC8E8", "halo": "#F2B84B", "glitch": "#FF4FA3",
        "slate": "#6B7A8F", "bloom": "#F078A8", "echo": "#4FB8A8", "pixel": "#58C45A",
        "rune": "#9A7BD8", "cloud": "#8FA9C9", "comet": "#4C9BF0", "mint": "#3FC9A0",
    ]

    private var color: Color {
        if avatar.hasPrefix("color:"), let color = Color(hex: String(avatar.dropFirst(6))) { return color }
        if avatar.hasPrefix("icon:"), let hex = Self.iconColors[String(avatar.dropFirst(5))],
           let color = Color(hex: hex) { return color }
        let palette = Self.iconColors.values.sorted()
        let index = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 9973 } % palette.count
        return Color(hex: palette[index]) ?? .gray
    }

    private var iconImage: UIImage? {
        guard avatar.hasPrefix("icon:") else { return nil }
        return UIImage(named: "avatar-\(avatar.dropFirst(5))")
    }

    var body: some View {
        if let iconImage {
            Image(uiImage: iconImage)
                .resizable()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
                .accessibilityHidden(true)
        } else {
            swatch
        }
    }

    private var swatch: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(name.prefix(1).uppercased())
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

extension BotState {
    var color: Color { tone.color }
}

struct StateBadge: View {
    let state: BotState

    var body: some View {
        StatusLabel(text: state.label, tone: state.tone, busy: state == .working)
    }
}

/// Marks a temporary worker wherever bots are listed.
struct WorkerTag: View {
    var body: some View {
        Pill(text: "Worker", tone: .worker).accessibilityLabel("Worker: temporary, removed when its task closes")
    }
}

/// Thin bar under the navigation bar while the daemon is unreachable for
/// more than a moment.
struct ConnectionBanner: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if store.connectionTrouble, store.status != .connected {
            HStack(spacing: 8) {
                if store.status == .connecting { ProgressView().controlSize(.small) }
                Text(store.status.label).font(.footnote.weight(.medium))
                Spacer()
                if case .disconnected = store.status {
                    Button("Try again") { store.client.reconnectNow() }.font(.footnote.weight(.semibold))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }
}

extension Date {
    var relative: String {
        if abs(timeIntervalSinceNow) < 60 { return "now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}

/// Runs a throwing action and surfaces its failure as an alert.
struct ErrorAlert: ViewModifier {
    /// "Couldn't <do the thing>."
    let title: String
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.alert(title, isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }
}

extension View {
    func errorAlert(_ title: String, _ message: Binding<String?>) -> some View { modifier(ErrorAlert(title: title, message: message)) }
}

/// How much a list loads at first, and how much each "Show more" adds: enough
/// to see what is new without pulling a bot's whole history over a slow link.
enum Page {
    static let size = 20
    /// Chat turns carry every step of the turn, so a page holds fewer.
    static let turns = 15
}

/// Runs `action` again whenever the computer reconnects (H-217), so a screen
/// that failed to load while the link was down catches up without a pull.
private struct ReloadOnReconnect: ViewModifier {
    @Environment(AppStore.self) private var store
    let action: () async -> Void
    @State private var seen: Int?

    func body(content: Content) -> some View {
        content.task(id: store.reconnects) {
            if let seen, seen != store.reconnects { await action() }
            seen = store.reconnects
        }
    }
}

extension View {
    func reloadsOnReconnect(_ action: @escaping () async -> Void) -> some View {
        modifier(ReloadOnReconnect(action: action))
    }
}
