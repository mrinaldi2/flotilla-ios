import SwiftUI

/// A bot's tool waiting on the owner: what it wants to run, when it is denied
/// if you don't answer, its input on demand, and the three answers.
struct PermissionCard: View {
    @Environment(AppStore.self) private var store
    let request: PermissionRequest
    /// Tapping the bot's name opens it; nil where its screen is already open.
    var openBot: ((String) -> Void)?
    @State private var showInput = false
    @State private var reason = ""
    @State private var busy: PermissionRequest.Answer?
    @State private var failure: String?

    private var bot: Bot? { store.bot(request.botId) }
    private var name: String { bot?.name ?? "A bot" }
    private var canAnswer: Bool { store.canControl && store.status == .connected && busy == nil }

    var body: some View {
        if request.isTerminal {
            TerminalCommandCard(request: request)
        } else {
            botCard
        }
    }

    private var botCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                if let openBot {
                    Button { openBot(request.botId) } label: {
                        Text(name).font(.subheadline.weight(.semibold)).underline()
                    }
                    .buttonStyle(.borderless)
                    .tint(.primary)
                } else {
                    Text(name).font(.subheadline.weight(.semibold))
                }
                Text("wants to run").font(.subheadline).foregroundStyle(Color.secondaryText)
                Spacer(minLength: 0)
            }
            Text(request.summary)
                .font(.callout.monospaced())
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let expires = request.expiresAt {
                Text("Denied at \(expires.formatted(date: .omitted, time: .shortened)) if unanswered")
                    .font(.caption)
                    .foregroundStyle(Color.secondaryText)
            }
            if !request.input.isEmpty {
                DisclosureGroup(isExpanded: $showInput) {
                    Text(request.input)
                        .font(.system(size: 11, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } label: {
                    Text("Input").font(.caption.weight(.semibold))
                }
                .tint(.secondary)
            }
            TextField("Reason, sent with Deny (optional)", text: $reason, prompt: .placeholder("Reason, sent with Deny (optional)"), axis: .vertical)
                .font(.footnote)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .disabled(!store.canControl)
            HStack(spacing: 8) {
                answerButton(.allowOnce, prominent: true)
                answerButton(.allowSession, prominent: false)
                answerButton(.deny, prominent: false)
            }
            if !store.canControl {
                Text("This device can read but not answer: it needs control access.")
                    .font(.caption)
                    .foregroundStyle(Color.secondaryText)
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(Color.errorText)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.orange.opacity(0.35)))
        .accessibilityElement(children: .contain)
    }

    private func answerButton(_ answer: PermissionRequest.Answer, prominent: Bool) -> some View {
        Button {
            send(answer)
        } label: {
            Group {
                if busy == answer {
                    ProgressView().controlSize(.small)
                } else {
                    Text(answer == .allowSession ? "Allow for session" : answer.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            // A step under footnote, so "Allow for session" fits on one line.
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(AnswerButtonStyle(tone: answer == .deny ? .failed : prominent ? .ready : .working))
        .disabled(!canAnswer)
        .accessibilityLabel(answer.label)
        .accessibilityHint(answer.hint ?? "")
    }

    private func send(_ answer: PermissionRequest.Answer) {
        busy = answer
        failure = nil
        Task {
            do {
                try await store.answerPermission(request, answer, reason: reason.trimmingCharacters(in: .whitespacesAndNewlines))
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                failure = error.localizedDescription
            }
            busy = nil
        }
    }
}

/// A terminal command asking to act as the owner (H-108). Read-only on
/// every device but its own computer: the owner can't see that terminal
/// from here, and allowing it from the phone is the reflex a bot would
/// exploit (UX-014). No buttons, no swipe actions.
struct TerminalCommandCard: View {
    @Environment(AppStore.self) private var store
    let request: PermissionRequest

    static let title = "A terminal command wants to act as you"

    /// The command verbatim; an older daemon sends only its summary.
    private var command: String { request.origin?.command ?? request.summary }
    private var warning: String? {
        request.origin?.bot.map { "It was started inside \($0)’s workspace, so a bot is probably asking, not you." }
    }
    private var action: String { "Answer this on \(store.computerName), in The Hermes app." }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(Self.title, systemImage: "lock.fill")
                .font(.subheadline.weight(.semibold))
            Text(command)
                .font(.callout.monospaced())
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let line = request.origin?.line {
                Text(line).font(.footnote).foregroundStyle(Color.secondaryText)
            }
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.errorText)
            }
            Text(action).font(.footnote.weight(.semibold))
            if let expires = request.expiresAt {
                Text("Denied automatically at \(expires.formatted(date: .omitted, time: .shortened)) if you don’t answer.")
                    .font(.caption)
                    .foregroundStyle(Color.secondaryText)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = ["Terminal command wants to act as you: \(command)."]
        if let line = request.origin?.line { parts.append("\(line).") }
        if let warning { parts.append(warning) }
        parts.append(action)
        return parts.joined(separator: " ")
    }
}

/// A bordered button, 44pt tall, whose words keep 4.5:1 on the orange card: its tone's
/// text colour on a light wash of the tint, laid over a fixed base. Not the card
/// colour, which is lighter in a dark-mode sheet and drops below AA (QA-004).
private struct AnswerButtonStyle: ButtonStyle {
    let tone: Tone
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tone.text)
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .frame(minHeight: 44)
            .background(tone.color.opacity(0.12), in: Capsule())
            .background(Color.answerBase, in: Capsule())
            .opacity(configuration.isPressed ? 0.6 : isEnabled ? 1 : 0.4)
    }
}
