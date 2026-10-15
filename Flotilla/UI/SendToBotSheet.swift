import SwiftUI

/// Sends a piece of text (a path, something the Mac copied) to a bot, either
/// as a bus message or typed straight into its terminal.
struct SendToBotSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var botId: String
    @State private var route = Route.terminal
    @State private var busy = false
    @State private var error: String?

    enum Route: String, CaseIterable {
        case terminal = "Type in terminal"
        case message = "Bus message"
    }

    init(text: String) {
        _text = State(initialValue: text)
        _botId = State(initialValue: UserDefaults.standard.string(forKey: "lastSendBot") ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Bot", selection: $botId) {
                        Text("Choose…").tag("")
                        ForEach(store.sortedProjects) { project in
                            Section(project.name) {
                                ForEach(store.bots(in: project)) { bot in
                                    Text(bot.temporary ? "\(bot.name) · worker" : bot.name).tag(bot.id)
                                }
                            }
                        }
                    }
                    Picker("How", selection: $route) {
                        ForEach(Route.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(route == .terminal
                         ? "Typed into the bot's Claude Code prompt and submitted, as if you typed it at \(store.computerName)."
                         : "Delivered to the bot's inbox; it reads it between steps.")
                    .foregroundStyle(Color.secondaryText)
                }
                Section("Text") {
                    TextField("Message", text: $text, prompt: .placeholder("Message"), axis: .vertical)
                        .lineLimit(3...10)
                        .font(.callout.monospaced())
                }
            }
            .navigationTitle("Send to a bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button("Send", action: send)
                            .disabled(botId.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .errorAlert("Couldn’t send it.", $error)
            .onAppear { if store.bot(botId) == nil { botId = "" } }
        }
        .presentationDetents([.medium, .large])
    }

    private func send() {
        busy = true
        UserDefaults.standard.set(botId, forKey: "lastSendBot")
        Task {
            do {
                switch route {
                case .terminal: await store.submitToTerminal(botId, text: text)
                case .message: try await store.sendMessage(botId: botId, body: text)
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }
}

/// A string that opens the sheet when set.
struct SendItem: Identifiable {
    let id = UUID()
    let text: String
}
