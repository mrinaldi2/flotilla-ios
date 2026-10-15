import SwiftUI

/// The selected computer's screen sign-in and its file browser's status.
struct MacSettingsSection: View {
    @Environment(Fleet.self) private var fleet
    @Environment(Computer.self) private var computer
    @Environment(LensStore.self) private var lens
    @Environment(ScreenSession.self) private var screen
    @AppStorage("screenFastColours") private var fastColours = false
    @State private var host = ""
    @State private var port = "5900"
    @State private var username = ""
    @State private var password = ""
    @State private var hasPassword = false
    @State private var filesStatus = "Checking…"

    private var isMac: Bool { computer.kind == .mac }

    var body: some View {
        Section {
            TextField("Address (empty: same as the Hermes service)", text: $host, prompt: .placeholder("Address (empty: same as the Hermes service)"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("Port", text: $port, prompt: .placeholder("Port")).keyboardType(.numberPad)
            if isMac {
                TextField("Mac user name", text: $username, prompt: .placeholder("Mac user name"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
            }
            let passwordTitle = hasPassword ? "Password (saved)" : (isMac ? "Mac password" : "VNC password")
            SecureField(passwordTitle, text: $password, prompt: .placeholder(passwordTitle))
                .textContentType(.password)
            Button("Save") { save() }
                .disabled((isMac && username.isEmpty) || (password.isEmpty && !hasPassword))
            Toggle("Fast colours", isOn: $fastColours)
                .onChange(of: fastColours) { _, _ in screen.disconnect() }
            if let stats = screen.stats { LabeledContent("Last connection", value: describe(stats)) }
        } header: {
            Text("\(computer.name): screen").foregroundStyle(Color.secondaryText)
        } footer: {
            if isMac {
                Text("Turn on Screen Sharing on the Mac: System Settings → General → Sharing → Screen Sharing, and allow your user. Sign in here with that Mac account. The password stays in this iPhone's Keychain and only goes to the Mac. Fast colours sends 16-bit colour: about a third less data, with slight banding on gradients.")
                    .foregroundStyle(Color.secondaryText)
            } else {
                Text("Install TightVNC Server on the Windows computer and set its primary password (8 characters at most) in TightVNC Service Configuration. Allow port 5900 only from Tailscale in Windows Firewall. The password stays in this iPhone's Keychain. Fast colours sends 16-bit colour: about a third less data, with slight banding on gradients.")
                    .foregroundStyle(Color.secondaryText)
            }
        }
        .onAppear(perform: loadSettings)

        Section {
            LabeledContent("File browser", value: filesStatus)
        } footer: {
            Text(isMac
                 ? "To browse the Mac's files, run on the Mac: companion/install.sh --with-files. Needs a device with control access."
                 : "To browse this computer's files, run on it: companion\\install.ps1 -WithFiles. Needs a device with control access.")
                .foregroundStyle(Color.secondaryText)
        }
        .task(id: computer.id) { await checkFiles() }
    }

    private func describe(_ stats: RFBClient.Stats) -> String {
        let names: [Int32: String] = [0: "Raw", 1: "CopyRect", 5: "Hextile", 16: "ZRLE"]
        var parts = [String(format: "sign-in %.1f s", stats.signIn)]
        if let first = stats.firstPicture { parts.append(String(format: "picture %.1f s", first)) }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(stats.bytes), countStyle: .binary))
        let used = stats.encodings.compactMap { names[$0] }.sorted()
        if !used.isEmpty { parts.append(used.joined(separator: "+")) }
        return parts.joined(separator: " · ")
    }

    private func loadSettings() {
        let record = computer.record
        host = record.screenHost
        port = String(record.screenPort)
        username = record.screenUser
        hasPassword = computer.screenSettings.password != nil
    }

    private func save() {
        var record = computer.record
        record.screenHost = host.trimmingCharacters(in: .whitespaces)
        record.screenPort = Int(port) ?? 5900
        record.screenUser = isMac ? username.trimmingCharacters(in: .whitespaces) : ""
        fleet.update(computer, record)
        if !password.isEmpty {
            computer.setScreenPassword(password)
            password = ""
            hasPassword = true
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func checkFiles() async {
        do {
            let root = try await lens.folder("", hidden: false)
            filesStatus = "On: " + root.roots.joined(separator: ", ")
        } catch {
            filesStatus = "Off"
        }
    }
}
