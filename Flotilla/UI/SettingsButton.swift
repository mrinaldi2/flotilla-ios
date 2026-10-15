import SwiftUI

/// Opens Settings as a sheet: it is visited rarely, so it has no tab.
struct SettingsButton: View {
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: { Image(systemName: "gearshape") }
            .accessibilityLabel("Settings")
            .sheet(isPresented: $showing) { SettingsView() }
            #if DEBUG
            // Screenshots of the demo: -openSettings YES opens it.
            .onAppear { if UserDefaults.standard.bool(forKey: "openSettings") { showing = true } }
            #endif
    }
}
