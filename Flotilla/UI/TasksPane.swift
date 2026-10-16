import SwiftUI

/// One task: who it is with, what was asked, and how it ended. The list holds
/// previews; a tap opens the whole request and result, loading them when the
/// preview was cut, as the markdown bots write.
struct TaskRowView: View {
    @Environment(AppStore.self) private var store
    let botId: String
    let task: BotTask
    @State private var open = false
    @State private var full: BotTask?
    @State private var error: String?
    @State private var loading = false

    private var shown: BotTask { full ?? task }

    private var when: String {
        if task.isOpen {
            return task.deadlineAt.map { "Due \(TaskTime.text($0))" } ?? ""
        }
        return task.closedAt.map(TaskTime.text) ?? ""
    }

    private var stateLabel: String { TaskStateLabel.label(task.state) }

    private var tone: Tone {
        switch task.state {
        case "open": .working
        case "done": .ready
        case "cancelled": .quiet
        default: .needsYou
        }
    }

    /// Two lines may hide some of the request, or the daemon cut it, or there is a result to see.
    private var hasMore: Bool {
        task.cut || task.result != nil || task.request.count > 110 || task.request.contains("\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ItemRow(title: task.counterpart, subtitle: open ? nil : task.request, detail: when, subtitleLines: 2) {
                IconTile(systemImage: task.role == "assigned" ? "tray.and.arrow.down" : "arrow.up.forward", tone: tone)
            } trailing: {
                if !task.isOpen { Pill(text: stateLabel, tone: tone) }
            }
            .contentShape(Rectangle())
            .onTapGesture { if hasMore || open { Task { await toggle() } } }
            .accessibilityAddTraits(hasMore ? .isButton : [])
            if open {
                MarkdownText(shown.request)
                if let result = shown.result, !result.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Result", systemImage: "checkmark.seal").font(.caption.weight(.semibold)).foregroundStyle(Color.successText)
                        MarkdownText(result)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if loading { ProgressView().controlSize(.small) }
                if let error { Text(error).font(.caption).foregroundStyle(Color.errorText) }
            }
        }
    }

    private func toggle() async {
        withAnimation(.snappy) { open.toggle() }
        guard open, task.cut, full == nil else { return }
        loading = true
        defer { loading = false }
        do {
            full = try await store.task(botId: botId, taskId: task.id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A routine's next scheduled run.
struct UpcomingRow: View {
    let routine: Routine
    @State private var open = false

    var body: some View {
        ItemRow(title: "Routine \(routine.name)", subtitle: routine.prompt,
                detail: routine.nextRunAt.map { "Next run \(TaskTime.text($0))" }, subtitleLines: open ? 12 : 2) {
            IconTile(systemImage: "calendar.badge.clock", tone: .working)
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy) { open.toggle() } }
    }
}

enum TaskTime {
    static func text(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }
}
