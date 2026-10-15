import SwiftUI
import UIKit

// H-230 (UX-043 iOS part): install an approved iOS release on this device.

extension InstallWords {
    /// The device's own type, as the copy names it.
    @MainActor static var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
}

/// On a release: under the status, above the items (UX-043 §3, §4).
struct InstallSection: View {
    let info: ReleaseInstallInfo
    @State private var unreachable = false
    @State private var checking = false

    private var device: String { InstallWords.device }
    private var installed: (version: String, build: String) { (AppInfo.version, AppInfo.build) }

    var body: some View {
        let state = InstallState.of(info, installed: installed)
        if state != .hidden {
            Section { content(info, state) }
        }
    }

    @ViewBuilder private func content(_ info: ReleaseInstallInfo, _ state: InstallState) -> some View {
        switch state {
        case .hidden:
            EmptyView()
        case .notPublished:
            Text(InstallWords.notPublished).foregroundStyle(Color.secondaryText)
        case .siteOff(let computer):
            installButton(info, forTesting: info.forTesting).disabled(true)
            Text(InstallWords.siteOff(computer: computer)).font(.footnote).foregroundStyle(Color.secondaryText)
            footnotes
        case .ready(let forTesting):
            if unreachable {
                Text(InstallWords.unreachable(device: device)).foregroundStyle(Color.errorText)
                Button(InstallWords.tryAgain) { Task { await install(info) } }.disabled(checking)
            } else {
                installButton(info, forTesting: forTesting)
            }
            footnotes
        case .sameVersion:
            Text(InstallWords.sameVersion(device: device, version: info.version, build: info.build))
            Button(InstallWords.reinstall) { Task { await install(info) } }
                .font(.footnote).disabled(checking)
                .accessibilityHint(InstallWords.hint(info.version))
            if unreachable { Text(InstallWords.unreachable(device: device)).font(.footnote).foregroundStyle(Color.errorText) }
        case .newerInstalled(let version):
            Text(InstallWords.newer(device: device, version: version))
            Button(InstallWords.anyway(info.version)) { Task { await install(info) } }
                .font(.footnote).disabled(checking)
                .accessibilityHint(InstallWords.hint(info.version))
            if unreachable { Text(InstallWords.unreachable(device: device)).font(.footnote).foregroundStyle(Color.errorText) }
        }
    }

    private func installButton(_ info: ReleaseInstallInfo, forTesting: Bool) -> some View {
        Button { Task { await install(info) } } label: {
            Label(InstallWords.button(device: device, forTesting: forTesting), systemImage: "arrow.down.app")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(checking)
        .accessibilityHint(InstallWords.hint(info.version))
    }

    @ViewBuilder private var footnotes: some View {
        Text(InstallWords.opensSafari).font(.footnote).foregroundStyle(Color.secondaryText)
        Text(InstallWords.profile).font(.footnote).foregroundStyle(Color.secondaryText)
    }

    private func install(_ info: ReleaseInstallInfo) async {
        checking = true
        let outcome = await InstallAction.install(info) { UIApplication.shared.open($0) }
        unreachable = outcome == .unreachable
        checking = false
    }
}

/// "The Hermes 0.6.1 is ready to install" · Install · Not now, on Needs you and
/// Releases when this device has a waiting offer (UX-043 §3).
struct InstallOfferBanner: View {
    let store: AppStore
    @State private var unreachable = false

    var body: some View {
        if let offer = store.installOffer {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label(InstallWords.banner(offer.version), systemImage: "arrow.down.app.fill")
                        .font(.subheadline.weight(.semibold))
                    if unreachable {
                        Text(InstallWords.unreachable(device: InstallWords.device))
                            .font(.footnote).foregroundStyle(Color.errorText)
                    }
                    HStack {
                        Button(unreachable ? InstallWords.tryAgain : InstallWords.install) {
                            Task {
                                let outcome = await InstallAction.install(offer) { UIApplication.shared.open($0) }
                                unreachable = outcome == .unreachable
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint(InstallWords.hint(offer.version))
                        Button(InstallWords.notNow) { Task { await store.dismissInstallOffer() } }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

/// "Updated to The Hermes 0.6.1.", once, at the first launch of a new version:
/// shown once the app is active, and marked seen only after it was on screen.
struct UpdatedToast: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var text: String?

    var body: some View {
        Group {
            if let text {
                Label(text, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        // Counted in short main-actor steps: a launch that keeps the main
                        // thread busy doesn't use up the time before anything is drawn.
                        let steps = Int(UpdateNotice.visible / .milliseconds(100))
                        for _ in 0..<steps {
                            try? await Task.sleep(for: .milliseconds(100))
                            if Task.isCancelled { return }
                        }
                        UpdateNotice.markShown()
                        self.text = nil
                    }
            }
        }
        .animation(.snappy, value: text)
        .task(id: scenePhase) {
            guard scenePhase == .active, text == nil, let notice = UpdateNotice.pending() else { return }
            text = notice
        }
    }
}
