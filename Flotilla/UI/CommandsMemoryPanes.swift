import SwiftUI

/// One command: what it is for, the command line, how it ended; its whole
/// command and output on a tap.
struct CommandRow: View {
    let command: BotCommand
    @State private var open = false

    private var tone: Tone {
        switch command.status {
        case "running": .working
        case "done": .ready
        case "failed": .failed
        default: .quiet
        }
    }

    private var detail: String {
        let state = switch command.status {
        case "running": "Running"
        case "done": "Done"
        case "failed": "Failed"
        case "stopped": "Stopped"
        default: command.status.capitalized
        }
        var parts = [state]
        if let outcome = command.outcome, outcome.lowercased() != command.status { parts.append(outcome) }
        parts.append(command.when(TaskTime.text))
        if command.background { parts.append("in the background") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func firstLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A tap gesture, not a Button: beside the Copy button, a List hands
            // a plain button's taps to the row's other buttons.
            // With no description, the command itself is the title: once is enough.
            ItemRow(title: command.description ?? firstLine(command.unwrapped),
                    subtitle: command.description == nil ? nil : command.unwrapped, detail: detail, monoSubtitle: true) {
                IconTile(systemImage: command.status == "running" ? "play.fill" : "terminal", tone: tone)
            } trailing: {
                CopyButton(text: command.command, label: "Copy the command", compact: true)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy) { open.toggle() } }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(open ? "Hides the output" : "Shows the whole command and its output")
            .contextMenu { CopyMenuItem(text: command.command) }
            if open {
                CopyableBlock(title: "Command", text: command.command)
                if let output = command.copyableOutput {
                    CopyableBlock(title: "Output", text: output)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Output").font(.caption2.weight(.semibold)).foregroundStyle(Color.secondaryText)
                        Text("No output yet.").font(.caption).foregroundStyle(Color.secondaryText)
                    }
                }
            }
        }
    }
}

/// A command or its output, in full, under a small heading with its own Copy.
private struct CopyableBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption2.weight(.semibold)).foregroundStyle(Color.secondaryText)
                Spacer()
                CopyButton(text: text, label: "Copy the \(title.lowercased())")
            }
            // Wrapped, so nothing is cut off at the screen's edge.
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contextMenu { CopyMenuItem(text: text) }
        }
    }
}

/// Puts the exact text on the clipboard and says so for a moment.
private struct CopyButton: View {
    let text: String
    let label: String
    /// Just the symbol, with a full-size tap target: for the end of a row.
    var compact = false
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.snappy) { copied = true }
        } label: {
            if compact {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(copied ? Color.green : Color.accentColor)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            } else {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(copied ? Color.successText : Color.accentColor)
            }
        }
        // Its own tap target in a List row, not the row's.
        .buttonStyle(.borderless)
        .accessibilityLabel(copied ? "Copied" : label)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.snappy) { copied = false }
        }
    }
}

/// Long-press to copy.
private struct CopyMenuItem: View {
    let text: String

    var body: some View {
        Button {
            UIPasteboard.general.string = text
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
    }
}

/// What the bot keeps in FACTS.md: the durable facts it carries between
/// sessions. Read-only; the bot owns the file. Reread after its turns change,
/// since that is when it writes.
struct MemoryPane: View {
    @Environment(AppStore.self) private var store
    let botId: String
    @State private var memory = Memory.loading

    static let file = "FACTS.md"

    enum Memory: Equatable {
        case loading
        case loaded(text: String, truncated: Bool)
        /// The bot has not written any yet.
        case missing
        case failed(String)
    }

    private var name: String { store.bot(botId)?.name ?? "This bot" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(Self.file, systemImage: "brain").font(.caption.monospaced()).foregroundStyle(Color.secondaryText)
                    Spacer()
                    Button("Refresh") { Task { await load() } }
                        .font(.caption)
                        .disabled(store.status != .connected)
                }
                switch memory {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity)
                case .missing:
                    Text("\(name) has not written any memory yet.").foregroundStyle(Color.secondaryText)
                case .failed(let error):
                    Text(error).font(.footnote).foregroundStyle(Color.errorText)
                case .loaded(let text, let truncated):
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("\(name)'s memory is empty.").foregroundStyle(Color.secondaryText)
                    } else {
                        MarkdownText(text).textSelection(.enabled)
                    }
                    if truncated {
                        Text("Only the start of the file is shown.").font(.caption).foregroundStyle(Color.secondaryText)
                    }
                }
            }
            .padding()
        }
        .refreshable { await load() }
        .task(id: store.status) { await load() }
        .task(id: store.chatRevision[botId]) {
            guard memory != .loading else { return }
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private func load() async {
        guard store.status == .connected else { return }
        do {
            let file = try await store.readFile(botId: botId, path: Self.file)
            memory = .loaded(text: file.text ?? "", truncated: file.truncated)
        } catch {
            // "File not found" means no memory yet, not a failure.
            let message = error.localizedDescription
            memory = message.localizedCaseInsensitiveContains("not found") ? .missing : .failed(message)
        }
    }
}
