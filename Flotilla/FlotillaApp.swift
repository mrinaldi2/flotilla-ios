import SwiftUI
import UserNotifications

@main
struct FlotillaApp: App {
    @State private var fleet = Fleet()
    /// A pairing link the system opened the app with: the Camera, a message.
    @State private var incoming: IncomingPairing?

    init() {
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
    }
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if let computer = fleet.selected {
                    RootView()
                        .environment(computer)
                        .environment(computer.store)
                        .environment(computer.lens)
                        .environment(computer.screen)
                        .sheet(item: $incoming) { ConnectView(adding: true, initialLink: $0.link) }
                } else {
                    ConnectView(initialLink: incoming?.link)
                }
            }
            .environment(fleet)
            .onOpenURL { url in
                if let link = IncomingURL.pairing(url) { incoming = IncomingPairing(link: link) }
                if let id = CardLinker.id(from: url) { fleet.openCard = id }
            }
            .onChange(of: scenePhase) { _, phase in fleet.setBackground(phase != .active) }
        }
    }
}

/// A pairing link that arrived from outside the app, shown once.
struct IncomingPairing: Identifiable {
    let id = UUID()
    let link: PairingLink
}
