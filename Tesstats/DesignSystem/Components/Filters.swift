import SwiftUI

// MARK: - Filter option protocol + chip row

protocol FilterOption: Identifiable, Hashable, CaseIterable, Sendable {
    var filterLabel: String { get }
}

/// Full-width segmented control — even segments, selected one highlighted crimson, all
/// inside a single rounded container. The selected background is applied to the bounded
/// text frame (not an expanding shape), so the control keeps a fixed, subtle height.
struct SegmentedFilter<T: FilterOption>: View where T.AllCases: RandomAccessCollection {
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(T.allCases)) { option in
                let active = option == selection
                Text(option.filterLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(active ? Color.white : Brand.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(active ? Brand.crimson : Color.clear, in: Capsule())
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy(duration: 0.2)) { selection = option } }
            }
        }
        .padding(4)
        .background(Brand.elevatedSurface, in: Capsule())
        .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
    }
}

// MARK: - Time range

enum TimeRange: String, FilterOption {
    case month, quarter, halfYear, year, all

    var id: String { rawValue }
    var filterLabel: String {
        switch self {
        case .month: L("30d")
        case .quarter: L("3m")
        case .halfYear: L("6m")
        case .year: L("1y")
        case .all: L("All")
        }
    }
    private var days: Int? {
        switch self {
        case .month: 30
        case .quarter: 90
        case .halfYear: 182
        case .year: 365
        case .all: nil
        }
    }
    func contains(_ date: Date, now: Date = Date()) -> Bool {
        guard let days, let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else { return true }
        return date >= cutoff && date <= now
    }
}

// MARK: - Charge type filter

enum ChargeTypeFilter: String, FilterOption, Sendable {
    case all, home, fast

    var id: String { rawValue }
    var filterLabel: String {
        switch self {
        case .all: L("All")
        case .home: L("Home / AC")
        case .fast: L("DC fast")
        }
    }
    func matches(_ charge: ChargeRecord) -> Bool {
        switch self {
        case .all: true
        case .home: !charge.isFastCharger
        case .fast: charge.isFastCharger
        }
    }
}

// MARK: - Search field

struct SearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.subheadline).foregroundStyle(Brand.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .foregroundStyle(Brand.textPrimary)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Brand.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Brand.elevatedSurface, in: Capsule())
    }
}

// MARK: - Load more (pagination) footer

struct LoadMoreButton: View {
    let remaining: Int
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle")
                Text(L("Load \(min(remaining, 25)) more (\(remaining) left)"))
            }
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .glassButtonStyle()
        .padding(.top, 4)
    }
}

// MARK: - Refresh toolbar button

struct RefreshButton: View {
    let isRefreshing: Bool
    let action: () -> Void
    @State private var spin = false

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: "arrow.clockwise")
                .rotationEffect(.degrees(spin ? 360 : 0))
        }
        .tint(Brand.action)
        .accessibilityLabel(L("Refresh"))
        .accessibilityIdentifier("update-data")
        .onChange(of: isRefreshing) { _, refreshing in
            if refreshing {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { spin = true }
            } else {
                withAnimation(.default) { spin = false }
            }
        }
    }
}
