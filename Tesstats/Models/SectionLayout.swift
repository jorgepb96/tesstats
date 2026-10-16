import Foundation

/// A block the user can move or hide inside a section.
///
/// Every scrollable screen is built from these, so one editor and one persistence format
/// cover Summary, Trips, Charging, Battery and Stats.
protocol SectionBlock: RawRepresentable<String>, CaseIterable, Identifiable, Hashable, Sendable {
    var title: String { get }
    var icon: String { get }
    /// A one-line "what is this for", shown in the layout editor.
    var blurb: String { get }
}

extension SectionBlock {
    var id: String { rawValue }
}

/// The screens whose layout the user can rearrange.
enum SectionID: String, CaseIterable, Sendable {
    case summary, trips, charging, battery, stats, parking

    var title: String {
        switch self {
        case .summary: L("Summary")
        case .trips: L("Trips")
        case .charging: L("Charging")
        case .battery: L("Battery")
        case .stats: L("Stats")
        case .parking: L("Parking")
        }
    }
}

/// Persisted arrangement of one section. Empty means "defaults".
struct SectionLayoutState: Codable, Equatable, Sendable {
    var order: [String] = []
    var hidden: [String] = []

    var isDefault: Bool { order.isEmpty && hidden.isEmpty }
}

enum SectionLayout {
    /// Every block in user order. Blocks added by a later app version are unknown to a saved
    /// order, so they are appended rather than silently dropped.
    static func resolved<B: SectionBlock>(_ type: B.Type, layout: SectionLayoutState) -> [B] {
        let saved = layout.order.compactMap { B(rawValue: $0) }
        guard !saved.isEmpty else { return Array(B.allCases) }
        var result = saved
        let defaults = Array(B.allCases)
        // Insert blocks added by an app update close to their default neighbours. Appending
        // everything at the end made newly configurable header cards look immovable for users
        // who already had a saved order from an older release.
        for (defaultIndex, block) in defaults.enumerated() where !result.contains(block) {
            if let next = defaults.dropFirst(defaultIndex + 1).first(where: { result.contains($0) }),
               let insertion = result.firstIndex(of: next) {
                result.insert(block, at: insertion)
            } else {
                result.append(block)
            }
        }
        return result
    }

    /// The blocks actually drawn, in user order.
    static func visible<B: SectionBlock>(_ type: B.Type, layout: SectionLayoutState) -> [B] {
        let hidden = Set(layout.hidden)
        return resolved(type, layout: layout).filter { !hidden.contains($0.rawValue) }
    }
}
