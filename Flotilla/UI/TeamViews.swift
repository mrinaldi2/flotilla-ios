import SwiftUI

// The team on demand on the phone (0.23, `team_on_demand_v1`): the running
// counter and its queue where a computer's or a project's bots are listed,
// Wake now and Sleep now on a bot, its presence, and the computer's limits.
// Nothing here shows for an older daemon.

/// "4 of 6 running · 2 waiting" on this computer, and who waits for a slot
/// in the order they will start; `projectId` keeps the queue to its bots.
struct TeamStatusSection: View {
    @Environment(AppStore.self) private var store
    var projectId: String? = nil

    var body: some View {
        if store.hasTeamOnDemand, let team = store.team {
            let queue = projectId.map(team.queue(in:)) ?? team.queue
            Section {
                ItemRow(title: team.words,
                        subtitle: "On \(store.computerName) · idle bots sleep after \(team.idleSleepMinutes) min") {
                    IconTile(systemImage: "person.3", tone: team.full ? .working : .ready)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("team-running")
                ForEach(queue) { wake in
                    TeamWakeRow(wake: wake, place: team.place(of: wake.botId) ?? 0)
                }
            } header: {
                SectionTitle("Running")
            } footer: {
                if !queue.isEmpty {
                    Text("They start in this order as slots free up: what you woke, then the lead, then card work by priority. An urgent bug goes to the front of the card work.")
                        .foregroundStyle(Color.secondaryText)
                }
            }
        }
    }
}

/// One wake waiting for a slot: who, why, and its place in line.
struct TeamWakeRow: View {
    @Environment(AppStore.self) private var store
    let wake: TeamWake
    let place: Int

    var body: some View {
        let bot = store.bot(wake.botId)
        let row = ItemRow(title: bot?.name ?? "A bot", subtitle: wake.words,
                          detail: wake.queuedAt.map { "Waiting since \($0.relative)" }) {
            if let bot {
                AvatarView(avatar: bot.avatar, name: bot.name, size: 32)
            } else {
                IconTile(systemImage: "person")
            }
        } trailing: {
            HStack(spacing: 6) {
                if wake.urgent { Pill(text: "Urgent bug", tone: .failed) }
                if place > 0 { Text("#\(place)").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(Color.secondaryText) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("team-wake-\(bot?.name ?? wake.botId)")
        if let bot { row.botTeamActions(bot) } else { row }
    }
}

extension View {
    /// Wake now and Sleep now on a bot's row: a leading swipe and its menu.
    func botTeamActions(_ bot: Bot) -> some View { modifier(BotTeamActions(bot: bot)) }
}

private struct BotTeamActions: ViewModifier {
    @Environment(AppStore.self) private var store
    let bot: Bot
    @State private var failure: String?

    private var project: Project? { store.projects.first { $0.id == bot.projectId } }
    private var able: Bool { store.hasTeamOnDemand && store.canControl && store.status == .connected }
    private var wakes: Bool { able && TeamRules.canWake(bot) }
    private var sleeps: Bool { able && TeamRules.canSleep(bot, project: project) }

    func body(content: Content) -> some View {
        if wakes || sleeps {
            content
                .swipeActions(edge: .leading) {
                    if wakes {
                        Button("Wake now", systemImage: "sun.max") { run(wake: true) }.tint(.accentColor)
                    } else {
                        Button("Sleep now", systemImage: "moon.zzz") { run(wake: false) }.tint(.indigo)
                    }
                }
                .contextMenu {
                    if wakes { Button("Wake now", systemImage: "sun.max") { run(wake: true) } }
                    if sleeps { Button("Sleep now", systemImage: "moon.zzz") { run(wake: false) } }
                }
                .errorAlert(wakes ? "Couldn’t wake \(bot.name)." : "Couldn’t send \(bot.name) to sleep.", $failure)
        } else {
            content
        }
    }

    private func run(wake: Bool) {
        Task {
            do {
                if wake { try await store.wakeBot(bot.id) } else { try await store.sleepBot(bot.id) }
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// Under the bot's panes while it is asleep or waits for a slot: what that
/// means, and Wake now.
struct BotRestBanner: View {
    @Environment(AppStore.self) private var store
    let bot: Bot
    @State private var waking = false
    @State private var failure: String?

    private var waitsForOwner: Bool { store.team?.queue.first { $0.botId == bot.id }?.reason == "owner" }

    private var line: String {
        guard bot.state == .queued else { return "Asleep. It wakes when work arrives, or when you wake it." }
        var parts = ["Waiting for a slot"]
        if let place = store.team?.place(of: bot.id) { parts.append(place == 1 ? "next in line" : "#\(place) in line") }
        if let team = store.team { parts.append("\(team.running) of \(team.maxRunning) running") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(tone: .quiet, size: 12, hollow: true)
            Text(line).font(.footnote.weight(.medium)).foregroundStyle(Color.secondaryText).lineLimit(2)
            Spacer(minLength: 4)
            if store.canControl, !(bot.state == .queued && waitsForOwner) {
                Button(waking ? "Waking…" : "Wake now") { wake() }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
                    .disabled(waking || store.status != .connected)
                    .accessibilityIdentifier("bot-wake")
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bot-rest")
        .errorAlert("Couldn’t wake \(bot.name).", $failure)
        .onChange(of: bot.state) { _, _ in waking = false }
    }

    private func wake() {
        waking = true
        Task {
            do { try await store.wakeBot(bot.id) } catch {
                waking = false
                failure = error.localizedDescription
            }
        }
    }
}

/// Always on or on demand, and Sleep now, in the bot's More pane.
struct BotPresenceSection: View {
    @Environment(AppStore.self) private var store
    let bot: Bot
    @State private var saving = false
    @State private var note: String?
    @State private var failure: String?

    private var project: Project? { store.projects.first { $0.id == bot.projectId } }
    private var locked: String? { TeamRules.presenceLocked(bot, project: project) }
    /// The lead is always on whatever the bot says.
    private var presence: BotPresence { project?.leadBotId == bot.id ? .alwaysOn : bot.presence ?? .alwaysOn }

    var body: some View {
        Section {
            Picker("Runs", selection: Binding(get: { presence }, set: { save($0) })) {
                ForEach(BotPresence.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(locked != nil || !store.canControl || store.status != .connected || saving)
            .accessibilityIdentifier("bot-presence")
            // On the row, not the Section: a List applies a section's modifiers to each row.
            .errorAlert("Couldn’t change when \(bot.name) runs.", $failure)
            if TeamRules.canSleep(bot, project: project), store.canControl {
                Button { sleep() } label: { Label("Sleep now", systemImage: "moon.zzz") }
                    .disabled(store.status != .connected)
                    .accessibilityIdentifier("bot-sleep")
            }
            if TeamRules.canWake(bot), store.canControl {
                Button { wake() } label: { Label("Wake now", systemImage: "sun.max") }
                    .disabled(store.status != .connected)
                    .accessibilityIdentifier("bot-wake-now")
            }
            if let note { Text(note).font(.footnote).foregroundStyle(Color.secondaryText) }
        } header: {
            SectionTitle("Running")
        } footer: {
            Text(locked ?? Self.help(presence)).foregroundStyle(Color.secondaryText)
        }
    }

    static func help(_ presence: BotPresence) -> String {
        switch presence {
        case .alwaysOn: "Keeps running, and takes one of this computer's running slots all the time."
        case .onDemand: "Sleeps after a few idle minutes and wakes when work arrives: a card, a task, a message, a routine or you opening its chat. Its conversation and memory are kept."
        }
    }

    private func save(_ next: BotPresence) {
        guard next != presence else { return }
        saving = true
        Task {
            do {
                try await store.setBotPresence(bot.id, next)
                note = next == .alwaysOn ? "\(bot.name) keeps running from now on." : "\(bot.name) sleeps once it is idle, and wakes when work arrives."
            } catch {
                failure = error.localizedDescription
            }
            saving = false
        }
    }

    private func sleep() {
        Task {
            do {
                try await store.sleepBot(bot.id)
                note = "\(bot.name) goes to sleep once its turn ends."
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func wake() {
        Task {
            do {
                try await store.wakeBot(bot.id)
                note = "\(bot.name) is waking up."
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// How many bots may run at once on the computer, and how long an on-demand
/// bot stays idle before it sleeps (`set_config`). Both apply at once;
/// lowering the cap stops no running bot.
struct TeamLimitsSection: View {
    @Environment(AppStore.self) private var store
    @State private var maxRunning = TeamLimits.runningDefault
    @State private var idleMinutes = TeamLimits.idleDefault
    @State private var saving = false
    @State private var failure: String?

    private var saved: (Int, Int)? { store.team.map { ($0.maxRunning, $0.idleSleepMinutes) } }
    private var dirty: Bool { saved.map { $0.0 != maxRunning || $0.1 != idleMinutes } ?? false }

    var body: some View {
        if store.hasTeamOnDemand {
            Section {
                Stepper("Bots running at once: \(maxRunning)", value: $maxRunning, in: TeamLimits.running)
                    .accessibilityIdentifier("team-max-running")
                Stepper("Sleep after \(idleMinutes) idle min", value: $idleMinutes, in: TeamLimits.idle,
                        step: idleMinutes >= 60 ? 15 : idleMinutes >= 10 ? 5 : 1)
                    .accessibilityIdentifier("team-idle-minutes")
                Button(saving ? "Saving…" : "Save") { save() }
                    .disabled(!dirty || saving || !store.canControl || store.status != .connected)
                    .accessibilityIdentifier("team-limits-save")
                    .errorAlert("Couldn’t save the team’s limits.", $failure)
            } header: {
                SectionTitle("Team")
            } footer: {
                Text("At most this many bots run on \(store.computerName), always-on ones included; a bot woken past it waits for a slot. Lowering it stops no running bot. An on-demand bot sleeps after this many idle minutes. Defaults: 6 bots, 10 minutes.")
                    .foregroundStyle(Color.secondaryText)
            }
            .disabled(!store.canControl)
            .onAppear(perform: load)
            .onChange(of: store.team) { _, _ in if !dirty, !saving { load() } }
        }
    }

    private func load() {
        guard let saved else { return }
        maxRunning = saved.0
        idleMinutes = saved.1
    }

    private func save() {
        saving = true
        Task {
            do {
                try await store.setTeamLimits(maxRunning: maxRunning != saved?.0 ? maxRunning : nil,
                                              idleMinutes: idleMinutes != saved?.1 ? idleMinutes : nil)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                failure = error.localizedDescription
            }
            saving = false
            load()
        }
    }
}

/// The ranges `set_config` takes.
enum TeamLimits {
    static let running = 1...32
    static let idle = 1...1440
    static let runningDefault = 6
    static let idleDefault = 10
}
