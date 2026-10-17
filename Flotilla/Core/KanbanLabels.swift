import Foundation

// Labels and a board's label groups (0.19 K8). Items carry free labels; a
// label `<group>:<value>` belongs to the board's group `<group>`, so
// `platform:ios` is the value ios of the group platform. A 0.18 home has no
// labels of that kind and sends platforms instead: they read as `platform:`
// labels here, as a 0.19 home would store them. The phone never sends
// platforms.

typealias LabelGroup = Flotilla_Board_V1_LabelGroup

/// A group as the filter bar, the cards and quick add read it.
struct LabelGroupView: Equatable, Identifiable {
    let name: String
    var values: [String]
    var id: String { name }

    /// The label a value stands for: "ios" → "platform:ios".
    func label(_ value: String) -> String { "\(name):\(value)" }
}

enum Labels {
    /// The group a label belongs to, or "" for a plain label.
    static func group(of label: String) -> String {
        guard let colon = label.firstIndex(of: ":"), colon != label.startIndex,
              label.index(after: colon) != label.endIndex else { return "" }
        return String(label[..<colon])
    }

    /// What a card shows: a grouped label's value, else the label.
    static func word(_ label: String) -> String {
        let group = group(of: label)
        return group.isEmpty ? label : String(label.dropFirst(group.count + 1))
    }

    /// A 0.18 platform as the label a 0.19 home stores it as.
    static func label(of platform: Flotilla_Board_V1_Platform) -> String? {
        switch platform {
        case .desktop: "platform:desktop"
        case .ios: "platform:ios"
        case .daemon: "platform:daemon"
        case .infra: "platform:infra"
        case .unspecified, .UNRECOGNIZED: nil
        }
    }

    /// The labels, with the platforms a 0.18 home sends as `platform:` labels.
    /// A 0.19 home fills both from the same labels, so nothing doubles.
    static func merged(_ labels: [String], platforms: [Flotilla_Board_V1_Platform]) -> [String] {
        var all = labels
        for label in platforms.compactMap(label(of:)) where !all.contains(label) { all.append(label) }
        return all
    }

    /// The most values a group the board doesn't declare may use and still be
    /// offered: more is a tag of its own per card (an import's `was:B12`).
    static let maxUndeclaredValues = 8

    /// The groups the filter bar offers, as the desktop does: the board's own
    /// in order, with their values, then any other group the cards use with
    /// at most `maxUndeclaredValues` values, with the values they use.
    static func groups(declared: [LabelGroup], cardLabels: [[String]]) -> [LabelGroupView] {
        var groups = declared.map { LabelGroupView(name: $0.name, values: $0.values) }
        let own = Set(declared.map(\.name))
        for label in cardLabels.joined() {
            let name = group(of: label)
            guard !name.isEmpty else { continue }
            let value = word(label)
            if let index = groups.firstIndex(where: { $0.name == name }) {
                if !groups[index].values.contains(value) { groups[index].values.append(value) }
            } else {
                groups.append(LabelGroupView(name: name, values: [value]))
            }
        }
        return groups.filter { own.contains($0.name) || $0.values.count <= maxUndeclaredValues }
    }
}

extension Flotilla_Board_V1_ItemCard {
    /// Its labels, a 0.18 home's platforms included.
    var allLabels: [String] { Labels.merged(labels, platforms: platforms) }
}

extension Flotilla_Board_V1_Item {
    /// Its labels, a 0.18 home's platforms included.
    var allLabels: [String] { Labels.merged(labels, platforms: platforms) }
}

/// The labels picked in the filter bar. Within a group any picked label
/// matches; every group picked from must match (the desktop's rule).
struct LabelFilter: Equatable {
    private(set) var picked: [String] = []

    var isOn: Bool { !picked.isEmpty }
    func has(_ label: String) -> Bool { picked.contains(label) }

    mutating func toggle(_ label: String) {
        if let index = picked.firstIndex(of: label) { picked.remove(at: index) } else { picked.append(label) }
    }

    mutating func clear() { picked = [] }

    /// Drops what the groups no longer offer (another board, a value gone).
    mutating func keep(only groups: [LabelGroupView]) {
        let offered = Set(groups.flatMap { group in group.values.map(group.label) })
        picked.removeAll { !offered.contains($0) }
    }

    func matches(_ labels: [String]) -> Bool {
        let groups = Set(picked.map(Labels.group(of:)))
        return groups.allSatisfy { group in picked.contains { Labels.group(of: $0) == group && labels.contains($0) } }
    }
}

extension BoardState {
    /// The label groups of a board (the one on screen when nil): its own and
    /// the small ones its cards use. A 0.18 home declares none, so its
    /// platforms make the group `platform`.
    func labelGroups(for boardId: String? = nil) -> [LabelGroupView] {
        let id = boardId ?? selected
        let board = snapshot.boards.first { $0.id == id }
        let cards = snapshot.cards.filter { !$0.draft && (id.isEmpty || $0.boardID.isEmpty || $0.boardID == id) }
        return Labels.groups(declared: board?.labelGroups ?? [], cardLabels: cards.map(\.allLabels))
    }

    /// A column's cards that the filter lets through, in rank order.
    func cards(in column: String, matching filter: LabelFilter) -> [BoardCard] {
        let all = cards(in: column)
        return filter.isOn ? all.filter { filter.matches($0.allLabels) } : all
    }

    /// The labels a card shows: those of the groups the board offers, as
    /// their values ("ios"), in the groups' order. Plain labels and big
    /// undeclared groups stay in the item screen.
    static func cardLabels(_ card: BoardCard, groups: [LabelGroupView]) -> [String] {
        let labels = card.allLabels
        return groups.flatMap { group in group.values.map(group.label).filter(labels.contains) }
    }
}

extension Flotilla_Board_V1_BoardColumn {
    /// "Doing 1 of 3" while a filter hides some cards; else as `chip(count:)`.
    func chip(shown: Int, of total: Int, filtering: Bool) -> String {
        filtering ? "\(name) \(shown) of \(total)" : chip(count: total)
    }
}
