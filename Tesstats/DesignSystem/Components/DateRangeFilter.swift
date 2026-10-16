import SwiftUI

// MARK: - Range model (presets + custom interval)

/// A date filter that the user can drive either from quick presets or a fully custom
/// from/to interval. Replaces the preset-only `TimeRange` wherever custom ranges are wanted.
struct StatsRange: Equatable, Hashable, Sendable {
    enum Preset: String, CaseIterable, Identifiable, Hashable, Sendable {
        case month, quarter, halfYear, year, all, custom
        var id: String { rawValue }

        var label: String {
            switch self {
            case .month: L("30d")
            case .quarter: L("3m")
            case .halfYear: L("6m")
            case .year: L("1y")
            case .all: L("All")
            case .custom: L("Custom")
            }
        }
        var days: Int? {
            switch self {
            case .month: 30
            case .quarter: 90
            case .halfYear: 182
            case .year: 365
            case .all, .custom: nil
            }
        }
    }

    var preset: Preset = .all
    var customStart: Date
    var customEnd: Date

    init(preset: Preset = .all) {
        self.preset = preset
        let now = Date()
        self.customEnd = now
        self.customStart = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
    }

    func contains(_ date: Date, now: Date = Date()) -> Bool {
        let cal = Calendar.current
        switch preset {
        case .custom:
            let lower = cal.startOfDay(for: customStart)
            let upper = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: customEnd)) ?? customEnd
            return date >= lower && date < upper
        default:
            guard let days = preset.days,
                  let cutoff = cal.date(byAdding: .day, value: -days, to: now) else { return true }
            return date >= cutoff && date <= now
        }
    }

    /// Concrete interval for display / export. `nil` means "all time".
    func interval(now: Date = Date()) -> DateInterval? {
        let cal = Calendar.current
        switch preset {
        case .custom:
            let lower = cal.startOfDay(for: customStart)
            let upper = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: customEnd)) ?? customEnd
            guard upper > lower else { return nil }
            return DateInterval(start: lower, end: upper)
        case .all:
            return nil
        default:
            guard let days = preset.days,
                  let cutoff = cal.date(byAdding: .day, value: -days, to: now) else { return nil }
            return DateInterval(start: cutoff, end: now)
        }
    }

    var summaryLabel: String {
        switch preset {
        case .custom: return "\(AppDate.mediumDate(customStart)) – \(AppDate.mediumDate(customEnd))"
        default: return preset.label
        }
    }
}

// MARK: - Filter bar

/// Preset capsules plus a calendar button that opens a custom from/to picker.
struct RangeFilterBar: View {
    @Binding var range: StatsRange
    @State private var showCustomSheet = false

    private let presets: [StatsRange.Preset] = [.month, .quarter, .halfYear, .year, .all]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(presets) { preset in
                presetButton(preset)
            }
            customButton
        }
        .padding(4)
        .background(Brand.elevatedSurface, in: Capsule())
        .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
        .sheet(isPresented: $showCustomSheet) {
            CustomRangeSheet(range: $range)
        }
    }

    private func presetButton(_ preset: StatsRange.Preset) -> some View {
        let active = range.preset == preset
        return Text(preset.label)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(active ? Color.white : Brand.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(active ? Brand.crimson : Color.clear, in: Capsule())
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy(duration: 0.2)) { range.preset = preset } }
    }

    private var customButton: some View {
        let active = range.preset == .custom
        return Button {
            showCustomSheet = true
        } label: {
            Image(systemName: "calendar")
                .font(.caption.weight(.bold))
                .foregroundStyle(active ? Color.white : Brand.textSecondary)
                .frame(width: 38)
                .padding(.vertical, 8)
                .background(active ? Brand.crimson : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Custom range sheet

private struct CustomRangeSheet: View {
    @Binding var range: StatsRange
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var end: Date

    init(range: Binding<StatsRange>) {
        _range = range
        _start = State(initialValue: range.wrappedValue.customStart)
        _end = State(initialValue: range.wrappedValue.customEnd)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.background.ignoresSafeArea()
                Form {
                    Section {
                        DatePicker(L("From"), selection: $start, in: ...end, displayedComponents: .date)
                            .tint(Brand.action)
                        DatePicker(L("To"), selection: $end, in: start..., displayedComponents: .date)
                            .tint(Brand.action)
                    } footer: {
                        Text(L("Filter trips, charging and stats to a specific window."))
                    }
                    Section {
                        ForEach(quickRanges, id: \.0) { item in
                            Button(item.0) { start = item.1; end = Date() }
                                .foregroundStyle(Brand.textPrimary)
                        }
                    } header: {
                        Text(L("Quick set"))
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(L("Custom range"))
            .navigationBarTitleDisplayModeInlineIfAvailable()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Apply")) {
                        range.customStart = start
                        range.customEnd = end
                        range.preset = .custom
                        dismiss()
                    }.fontWeight(.semibold)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
            }
        }
        .tint(Brand.action)
    }

    private var quickRanges: [(String, Date)] {
        let cal = Calendar.current
        let now = Date()
        return [
            (L("This week"), cal.date(byAdding: .day, value: -7, to: now) ?? now),
            (L("This month"), cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now),
            (L("This year"), cal.date(from: cal.dateComponents([.year], from: now)) ?? now),
            (L("Last 12 months"), cal.date(byAdding: .month, value: -12, to: now) ?? now)
        ]
    }
}
