import SwiftUI
import UserNotifications

/// Says why notifications are worth having before iOS asks, once, after the
/// first computer is paired rather than on first launch.
struct NotificationExplainer: View {
    @Environment(\.dismiss) private var dismiss

    static let shownKey = "notificationExplainerShown"

    /// True when iOS has not asked yet and the explainer has not been shown.
    static func shouldExplain() async -> Bool {
        #if DEBUG
        // Settings screenshots (-openSettings YES) show the row as not set up;
        // -noNotificationPrompt YES keeps the system prompt off other screenshots.
        if UserDefaults.standard.bool(forKey: "openSettings") || UserDefaults.standard.bool(forKey: "noNotificationPrompt") {
            return false
        }
        // Demo and UI-test launches (-gravHost …) keep asking directly, as
        // before, unless -notificationExplainer YES asks for the explainer.
        if UserDefaults.standard.string(forKey: "gravHost") != nil,
           !UserDefaults.standard.bool(forKey: "notificationExplainer") {
            Notifier.requestPermission()
            return false
        }
        #endif
        guard !UserDefaults.standard.bool(forKey: shownKey) else { return false }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .notDetermined
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("Get told when a bot needs you")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Text("While The Hermes is open or recently used, it lets you know when a bot needs a decision, asks for permission or is waiting for you. Tap a notification to go straight there.")
                .font(.callout)
                .foregroundStyle(Color.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                finish()
                Notifier.requestPermission()
            } label: {
                Text("Turn on notifications")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            Button("Not now") { finish() }
                .frame(minHeight: 44)
        }
        .padding(24)
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.shownKey)
        dismiss()
    }
}
