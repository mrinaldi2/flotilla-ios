import SwiftUI

// "Gravity Night": the one look every list in the app shares. Every list is
// an inset grouped card; every row has a leading avatar, tile or dot, one
// title, at most two lines under it, and one trailing element; status is a
// dot and a word; a badge is a tinted capsule; long lists load their next
// page as their end comes into view.

/// What a colour means, wherever it appears.
enum Tone {
    case ready, working, needsYou, failed, quiet, worker
    /// A computer that is away: what it shows is as of when it was last seen.
    case away

    var color: Color {
        switch self {
        case .ready: .green
        case .working: .accentColor
        case .needsYou: .orange
        case .failed: .red
        case .quiet: .secondary
        case .worker: .teal
        case .away: .yellow
        }
    }

    /// The colour for words in this tone. The system tints are for fills and
    /// dots; as text on white most fall under WCAG AA (4.5:1), so light mode
    /// uses darker shades of the same hue.
    var text: Color {
        switch self {
        case .ready: .successText
        case .working: .workingText
        case .needsYou: .warningText
        case .failed: .errorText
        case .quiet: .secondaryText
        case .worker: .workerText
        case .away: .awayText
        }
    }
}

extension Color {
    /// Warning words. System orange stays for fills and dots only.
    static let warningText = Color(light: 0xC93400, dark: 0xFF9F0A)
    static let successText = Color(light: 0x1E7B34, dark: 0x30D158)
    static let errorText = Color(light: 0xD70015, dark: 0xFF6961)
    /// Under a permission card's answer buttons: the same in a sheet or on a
    /// screen, whatever the elevation (QA-004).
    static let answerBase = Color(light: 0xFFFFFF, dark: 0x1C1C1E)
    static let workerText = Color(light: 0x007A8F, dark: 0x40CBE0)
    /// Working words, in the accent's hue. Text in the accent tint itself is
    /// under 4.5:1 on grouped backgrounds and pills.
    static let workingText = Color(light: 0x3451C6, dark: 0x8FA8FF)
    /// Secondary words: captions, footers, placeholders, quiet badges. The
    /// system's secondary and placeholder greys are 3.4:1 and 1.7:1 on white;
    /// this stays above 4.5:1 on every list, fill and card background.
    static let secondaryText = Color(light: 0x636366, dark: 0xAEAEB2)
    /// Words for a computer that is away, in amber: system yellow is far under
    /// 4.5:1 as text on white.
    static let awayText = Color(light: 0x8A5A00, dark: 0xF2C063)
    /// The one filled button on a card's ask (Answer, Review…) and its words.
    static let askButton = Color(light: 0xC93400, dark: 0xFF9F0A)
    static let onAskButton = Color(light: 0xFFFFFF, dark: 0x1A0B00)

    /// A project's tile on Projects: deep enough that its white monogram
    /// stays above 4.5:1, the same in both modes.
    static let projectGlyphs: [UInt32] = [0x0C3062, 0x6A4C93, 0x0E6E66, 0xB8392F, 0x4D7A26, 0x7A5C2E,
                                          0x1F4E79, 0x8A3B12, 0x2E6B4F, 0x4F6D8A, 0x555B66]

    /// A colour that follows light and dark mode.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
                           blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        })
    }
}

extension BoardSegment.Shade {
    /// A mini board's columns (BG-Rules §4) step in lightness, not only hue:
    /// To do lightest and Done darkest in light mode, the other way round in
    /// dark, Review in the needs-you family because it is the owner's column.
    var color: Color {
        switch self {
        case .todo: Color(light: 0xD9D2C3, dark: 0x3A414E)
        case .ready: Color(light: 0xB5AB98, dark: 0x4E5666)
        case .doing: Color(light: 0x2A9D8F, dark: 0x2E9C8F)
        case .review: Color(light: 0xC8352A, dark: 0xFF7A6E)
        case .verify: Color(light: 0x9C2A20, dark: 0xFFA397)
        case .done: Color(light: 0x0C3062, dark: 0xC3D3FF)
        case .cancelled: Color(light: 0x8E8676, dark: 0x59606C)
        case .more: Color(light: 0xA79F8F, dark: 0x59606C)
        }
    }

    /// Board order, lightest to darkest in light mode.
    static let ramp: [Self] = [.todo, .ready, .doing, .review, .verify, .done]
}

extension BotState {
    var tone: Tone {
        switch self {
        case .working: .working
        case .ready: .ready
        case .waitingForUser, .waitingForApproval, .rateLimited: .needsYou
        case .authFailed, .crashed: .failed
        case .starting, .stopping, .stopped, .asleep, .queued, .unknown: .quiet
        }
    }
}

extension Text {
    /// A text field's placeholder in the readable secondary colour: the
    /// system placeholder grey is 1.7:1 on white.
    static func placeholder(_ text: LocalizedStringKey) -> Text {
        Text(text).foregroundStyle(Color.secondaryText)
    }

    @_disfavoredOverload
    static func placeholder(_ text: String) -> Text {
        Text(text).foregroundStyle(Color.secondaryText)
    }
}

struct StatusDot: View {
    let tone: Tone
    var size: CGFloat = 8
    /// A ring instead of a dot (◌): nothing running, and nothing wrong (a bot asleep).
    var hollow = false

    var body: some View {
        Group {
            if hollow {
                Circle().strokeBorder(tone.color, style: StrokeStyle(lineWidth: 1.5, dash: [1.6, 1.4]))
            } else {
                Circle().fill(tone.color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A dot and a word: the status of a bot, a command, a computer.
struct StatusLabel: View {
    let text: String
    let tone: Tone
    /// A spinner instead of the dot, for something under way.
    var busy = false
    /// A ring instead of the dot (◌ Asleep).
    var hollow = false

    var body: some View {
        HStack(spacing: 5) {
            if busy {
                ProgressView().controlSize(.mini)
            } else {
                StatusDot(tone: tone, hollow: hollow)
            }
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(tone == .needsYou || tone == .failed ? tone.text : Color.secondaryText)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The one badge: a word in a tinted capsule. The tint is kept light so the
/// word, in its tone's text colour, stays at 4.5:1 or more on it.
struct Pill: View {
    let text: String
    var tone: Tone = .quiet

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(tone.text)
            .background(tone.color.opacity(0.12), in: Capsule())
    }
}

/// An SF Symbol on a rounded square, leading a row about a thing (a file,
/// a command, a computer) rather than a bot.
struct IconTile: View {
    let systemImage: String
    var tone: Tone? = nil
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(tone.map { $0.color.opacity(0.18) } ?? Color(.tertiarySystemFill))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.48, weight: .medium))
                    .foregroundStyle(tone?.color ?? .secondary)
            }
            .accessibilityHidden(true)
    }
}

/// The row every list uses: leading, a title, up to two lines under it, trailing.
struct ItemRow<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    var detail: String?
    var monoSubtitle = false
    var titleLines = 1
    var subtitleLines = 1
    var titleTone: Tone?
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            leading()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(titleTone?.text ?? .primary)
                    .lineLimit(titleLines)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(monoSubtitle ? .caption.monospaced() : .footnote)
                        .foregroundStyle(Color.secondaryText)
                        .lineLimit(subtitleLines)
                }
                if let detail, !detail.isEmpty {
                    Text(detail).font(.footnote).foregroundStyle(Color.secondaryText).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.vertical, 5)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        // iPad pointer: rows light up under it (UX-023 §2.7).
        .hoverEffect(.highlight)
    }
}

extension ItemRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, detail: String? = nil, monoSubtitle: Bool = false,
         titleLines: Int = 1, subtitleLines: Int = 1, titleTone: Tone? = nil,
         @ViewBuilder leading: @escaping () -> Leading) {
        self.init(title: title, subtitle: subtitle, detail: detail, monoSubtitle: monoSubtitle,
                  titleLines: titleLines, subtitleLines: subtitleLines, titleTone: titleTone,
                  leading: leading, trailing: { EmptyView() })
    }
}

/// A section's title with how many it holds.
struct SectionTitle: View {
    let text: String
    var count: Int?

    init(_ text: String, count: Int? = nil) {
        self.text = text
        self.count = count
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
            if let count { Text("\(count)") }
        }
        // List headers are the system grey, 3.3:1 on the grouped background.
        .foregroundStyle(Color.secondaryText)
    }
}

/// A list with nothing in it yet, said once, the same way everywhere.
struct EmptyNote: View {
    let text: String
    var systemImage = "tray"

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(Color.secondaryText)
            .padding(.vertical, 6)
    }
}

/// The last row of a list that loads a page at a time. It loads the next page
/// as it comes into view, says so quietly, offers Try again when that fails,
/// and once everything is in says how many there are.
struct ListEnd: View {
    let hasMore: Bool
    /// What the list holds, plural: "commands".
    let noun: String
    /// How many are loaded, so the next page starts once the last one lands.
    let loaded: Int
    let load: () async throws -> Void
    @State private var failed = false
    @State private var trying = 0

    var body: some View {
        if hasMore {
            Group {
                if failed {
                    HStack {
                        Text("Couldn’t load earlier \(noun)").foregroundStyle(Color.warningText)
                        Spacer()
                        Button("Try again") { failed = false; trying += 1 }.fontWeight(.semibold)
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading earlier \(noun)…").foregroundStyle(Color.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(.subheadline)
            .frame(minHeight: 36)
            // Runs when the row scrolls into view, again after each page.
            .task(id: "\(loaded)-\(trying)") {
                guard !failed else { return }
                do { try await load() } catch { failed = true }
            }
        } else if loaded > Page.size {
            Text("All \(loaded) \(noun)")
                .font(.footnote)
                .foregroundStyle(Color.secondaryText)
                .frame(maxWidth: .infinity)
        }
    }
}

/// The computer a view belongs to, with everything its views read.
extension View {
    func computerEnvironment(_ computer: Computer) -> some View {
        environment(computer)
            .environment(computer.store)
            .environment(computer.lens)
            .environment(computer.screen)
    }
}
