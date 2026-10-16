import SwiftUI

/// The bot's own browser, live: its tabs, the page on show, and every browser
/// action it took with the turn that led to it. The bot screen starts
/// watching when the bot is opened, so this is live the moment it is chosen.
struct BrowserPane: View {
    @Environment(AppStore.self) private var store
    let botId: String
    @State private var activity: [BrowserAction] = []
    @State private var activityLimit = Page.size
    @State private var activityError: String?
    @State private var loaded = false
    @State private var zoomed = false

    private var bot: Bot? { store.bot(botId) }
    private var name: String { bot?.name ?? "The bot" }
    private var tabs: BrowserTabs? { store.browserTabs?.botId == botId ? store.browserTabs : nil }
    private var frame: BrowserFrame? { store.browserFrame.flatMap { $0.belongs(to: tabs) ? $0 : nil } }

    /// Where the bot's browser stands, said above the screen.
    private var note: String {
        if let machine = bot?.peerName { return "\(name) runs on \(machine); its browser streams from there." }
        return bot?.userChrome == true
            ? "\(name) uses a browser of its own, and may also use your Chrome."
            : "\(name) uses a browser of its own; your Chrome is off limits."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(note).font(.footnote).foregroundStyle(Color.secondaryText)
                if let tabs, tabs.open {
                    TabStrip(tabs: tabs) { store.watchBrowser(botId, tabId: $0) }
                }
                screen
                activityList
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .refreshable { await loadActivity() }
        .task { await loadActivity() }
        // Browsing happens in turns: reread the log shortly after the chat moves.
        .task(id: store.chatRevision[botId]) {
            guard loaded else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await loadActivity()
        }
        .fullScreenCover(isPresented: $zoomed) {
            if let frame, let image = UIImage(data: frame.jpeg) {
                ZoomedScreen(image: image, title: tabs?.activeTab?.label ?? name) { zoomed = false }
            }
        }
    }

    @ViewBuilder private var screen: some View {
        if let tabs {
            if !tabs.open {
                placeholder(tabs.reason ?? "\(name)'s browser is closed. It opens when \(name) first browses.")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if let url = tabs.activeTab?.url, !url.isEmpty {
                        Text(url).font(.caption.monospaced()).foregroundStyle(Color.secondaryText).lineLimit(1).truncationMode(.middle)
                    }
                    if let frame, let image = UIImage(data: frame.jpeg) {
                        // The page's own shape, never cropped.
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(CGSize(width: max(frame.width, 1), height: max(frame.height, 1)), contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color(.separator)))
                            .onTapGesture { zoomed = true }
                            .accessibilityLabel("What \(name)'s browser shows")
                    } else {
                        placeholder("Waiting for the page…")
                    }
                }
            }
        } else {
            placeholder(store.status == .connected ? "Looking for the browser…" : store.status.label)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(Color.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 180)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private var activityList: some View {
        let groups = BrowserTurnGroup.group(activity)
        VStack(alignment: .leading, spacing: 10) {
            Text("Activity").font(.headline).padding(.top, 8)
            if let activityError {
                Text(activityError).font(.footnote).foregroundStyle(Color.errorText)
            }
            if loaded, groups.isEmpty, activityError == nil {
                EmptyNote(text: "No browsing yet.", systemImage: "globe")
            }
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(group.why).font(.subheadline.weight(.semibold))
                        Spacer()
                        if let at = group.at { Text(TaskTime.text(at)).font(.caption).foregroundStyle(Color.secondaryText) }
                    }
                    if !group.ask.isEmpty {
                        Text(group.ask).font(.footnote).foregroundStyle(Color.secondaryText).lineLimit(2)
                    }
                    ForEach(group.actions) { action in ActionRow(action: action) }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            // A full page means there may be older ones.
            ListEnd(hasMore: activity.count >= activityLimit, noun: "activity", loaded: activity.count) {
                activityLimit += Page.size
                await loadActivity()
            }
        }
    }

    private func loadActivity() async {
        guard store.status == .connected else { return }
        do {
            activity = try await store.browserActivity(botId: botId, limit: activityLimit)
            activityError = nil
        } catch {
            activityError = error.localizedDescription
        }
        loaded = true
    }
}

/// The bot's tabs; picking one shows it, "Follow bot" goes back to the bot's.
private struct TabStrip: View {
    let tabs: BrowserTabs
    let pick: (String?) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tabs.tabs) { tab in
                    let active = tab.id == tabs.active
                    Button { pick(tab.id) } label: {
                        Text(tab.label)
                            .lineLimit(1)
                            .frame(maxWidth: 170)
                            .font(.caption.weight(active ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(active ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemFill), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
                Button { pick(nil) } label: {
                    Label("Follow bot", systemImage: tabs.following ? "eye.fill" : "eye")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundStyle(tabs.following ? Color.accentColor : .secondary)
                        .background(tabs.following ? Color.accentColor.opacity(0.12) : Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Show whichever tab the bot is using")
            }
        }
    }
}

private struct ActionRow: View {
    let action: BrowserAction

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(action.status == "error" ? Color.orange : action.status == "running" ? .accentColor : .secondary)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(action.title).font(.footnote)
                    if action.ownersChrome {
                        Pill(text: "Your Chrome", tone: .needsYou)
                    }
                }
                if let subtitle = action.subtitle {
                    Text(subtitle).font(.caption.monospaced()).foregroundStyle(Color.secondaryText).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }
}

/// The page full screen, to pinch into.
private struct ZoomedScreen: View {
    let image: UIImage
    let title: String
    let close: () -> Void
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width * scale * pinch)
                }
            }
            .background(Color.black)
            .gesture(MagnifyGesture()
                .updating($pinch) { value, state, _ in state = value.magnification }
                .onEnded { value in scale = min(max(scale * value.magnification, 1), 5) })
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) } }
        }
    }
}
