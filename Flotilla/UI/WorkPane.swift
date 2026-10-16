import SwiftUI

/// What the bot is doing and has done: commands running now, its tasks,
/// what is scheduled, then the commands and tasks it finished, newest first,
/// more as the list's end comes into view. Gravity's Tasks and Commands, in
/// one list on the phone.
struct WorkPane: View {
    @Environment(AppStore.self) private var store
    let botId: String
    @State private var commands: [BotCommand] = []
    @State private var commandLimit = Page.size
    @State private var tasks: [BotTask] = []
    @State private var closedLimit = Page.size
    @State private var moreClosed = false
    @State private var routines: [Routine] = []
    @State private var loaded = false
    @State private var error: String?

    private var running: [BotCommand] { BotCommand.sections(commands).running }
    private var finished: [BotCommand] { BotCommand.sections(commands).finished }
    private var openTasks: [BotTask] { tasks.filter(\.isOpen) }
    private var closedTasks: [BotTask] { tasks.filter { !$0.isOpen } }
    private var upcoming: [Routine] {
        routines.filter { $0.enabled && $0.nextRunAt != nil }.sorted { $0.nextRunAt! < $1.nextRunAt! }
    }

    var body: some View {
        List {
            if let error {
                Text(error).font(.footnote).foregroundStyle(Color.errorText)
            }
            if loaded, error == nil, commands.isEmpty, tasks.isEmpty, upcoming.isEmpty {
                EmptyNote(text: "\(store.bot(botId)?.name ?? "This bot") has not run anything yet.", systemImage: "hammer")
            }
            if !running.isEmpty {
                Section {
                    ForEach(running) { CommandRow(command: $0) }
                } header: {
                    SectionTitle("Running", count: running.count)
                }
            }
            if !openTasks.isEmpty {
                Section {
                    ForEach(openTasks) { TaskRowView(botId: botId, task: $0) }
                } header: {
                    SectionTitle("Tasks", count: openTasks.count)
                }
            }
            if !upcoming.isEmpty {
                Section {
                    ForEach(upcoming) { UpcomingRow(routine: $0) }
                } header: {
                    SectionTitle("Routines", count: upcoming.count)
                }
            }
            if !finished.isEmpty {
                Section {
                    ForEach(finished) { CommandRow(command: $0) }
                    ListEnd(hasMore: commands.count >= commandLimit, noun: "commands", loaded: commands.count) {
                        commandLimit += Page.size
                        try await loadCommands()
                    }
                } header: {
                    SectionTitle("Commands")
                }
            }
            if !closedTasks.isEmpty {
                Section {
                    ForEach(closedTasks) { TaskRowView(botId: botId, task: $0) }
                    ListEnd(hasMore: moreClosed, noun: "tasks", loaded: closedTasks.count) {
                        closedLimit += Page.size
                        try await loadTasks()
                    }
                } header: {
                    SectionTitle("Done")
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
        .task(id: store.status) { await load() }
        // A working bot changes its chat constantly: refetch once it pauses,
        // not on every step, so a slow link is not kept full.
        .task(id: store.chatRevision[botId]) {
            guard loaded else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            try? await loadCommands()
        }
        // Tasks open and close through bus messages and routine runs.
        .task(id: store.busRevision) {
            guard loaded else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            try? await loadTasks()
        }
        // A background command's output keeps growing: reread it now and then.
        .task(id: BotCommand.needsPolling(commands)) {
            guard BotCommand.needsPolling(commands) else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                try? await loadCommands()
            }
        }
    }

    private func load() async {
        guard store.status == .connected else { return }
        do {
            try await loadCommands()
            try await loadTasks()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func loadCommands() async throws {
        guard store.hasCommands else { return }
        commands = try await store.botCommands(botId: botId, limit: commandLimit)
    }

    private func loadTasks() async throws {
        async let listed = store.listTasks(botId: botId, closedLimit: closedLimit)
        async let scheduled = store.listRoutines(botId: botId)
        (tasks, moreClosed) = try await listed
        routines = (try? await scheduled) ?? routines
    }
}
