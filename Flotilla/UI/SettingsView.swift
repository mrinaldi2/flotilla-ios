import SwiftUI
import UserNotifications

/// The app's own settings, and the computers. Everything that belongs to one
/// computer (its addresses, token, screen sharing, daemon and Lens) is on
/// its page under Computers.
struct SettingsView: View {
    /// The Settings tab (UX-024), rather than a sheet with Done.
    var inTab = false
    @AppStorage("terminalFontSize") private var fontSize = 11.0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var notifications: UNAuthorizationStatus?
    @State private var showing: Sheet?

    private enum Sheet: Identifiable {
        case computers, files
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            Form {
                if inTab {
                    Section {
                        Button { showing = .computers } label: {
                            Label("Computers", systemImage: "desktopcomputer")
                        }
                        Button { showing = .files } label: {
                            Label("Files", systemImage: "doc.on.doc")
                        }
                    } footer: {
                        Text("Computers, their screens and tokens. Each project's artifacts move into the project in the next build.")
                            .foregroundStyle(Color.secondaryText)
                    }
                }

                Section {
                    Stepper("Font size \(Int(fontSize)) pt", value: $fontSize, in: 8...18, step: 1)
                } header: {
                    SectionTitle("Terminal")
                } footer: {
                    Text("Opening a bot's terminal resizes it to fit this screen. The terminal is shared, so Hermes on the computer shows that size too until it resizes it again.").foregroundStyle(Color.secondaryText)
                }

                Section {
                    LabeledContent("Notifications", value: notificationsLabel)
                    if notifications == .notDetermined {
                        Button("Turn on notifications") {
                            UserDefaults.standard.set(true, forKey: NotificationExplainer.shownKey)
                            Task {
                                _ = try? await UNUserNotificationCenter.current()
                                    .requestAuthorization(options: [.alert, .sound, .badge])
                                await refreshNotifications()
                            }
                        }
                    } else {
                        Button("Change in iOS Settings") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                        }
                    }
                } header: {
                    SectionTitle("Notifications")
                } footer: {
                    Text("While The Hermes is open or recently used, it tells you when a bot needs a decision, asks for permission or is waiting for you.").foregroundStyle(Color.secondaryText)
                }

                Section {
                    LabeledContent("Version", value: AppInfo.label)
                        .textSelection(.enabled)
                    if let commit = AppInfo.commit {
                        LabeledContent("Commit", value: commit)
                            .textSelection(.enabled)
                    }
                    Link("Source code", destination: AppInfo.sourceURL)
                    Link("Licenses", destination: AppInfo.noticesURL)
                } header: {
                    SectionTitle("About")
                } footer: {
                    Text("The Hermes is open source under the MIT License. Based on Gravity by P. Mikołajczuk.").foregroundStyle(Color.secondaryText)
                }
            }
            .navigationTitle("Settings")
            .task { await refreshNotifications() }
            // Coming back from iOS Settings: show what was chosen there.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await refreshNotifications() } }
            }
            .toolbar {
                if !inTab {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
            .sheet(item: $showing) { sheet in
                switch sheet {
                case .computers: ComputersView()
                case .files: ReportsView()
                }
            }
        }
    }

    private var notificationsLabel: String {
        switch notifications {
        case .authorized, .provisional, .ephemeral: "On"
        case .denied: "Off"
        case .notDetermined: "Not set up"
        default: ""
        }
    }

    private func refreshNotifications() async {
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
