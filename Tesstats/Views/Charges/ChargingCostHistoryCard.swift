import SwiftUI
import Charts

struct ChargingCostHistoryCard: View {
    @Environment(AppEnvironment.self) private var env
    @State private var filter = ChargingCostFilter()
    @State private var history = ChargingCostHistory()
    @State private var locations: [String] = []
    @State private var ready = false
    @State private var showFilters = false
    @State private var selectedMonth: Date?

    private var units: Units { Units(config: env.settings.config) }
    private struct Key: Equatable {
        var revision: Int
        var carID: Int?
        var filter: ChargingCostFilter
        var pricing: ChargePricing
    }
    private var key: Key {
        Key(revision: env.history.revision, carID: env.live.resolvedCarID,
            filter: filter, pricing: ChargePricing(config: env.settings.config))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionHeader(L("Monthly charging cost"), systemImage: "chart.bar.xaxis")
                Spacer(minLength: 4)
                Button { showFilters = true } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.title2).frame(minWidth: 44, minHeight: 44)
                }
                .tint(Brand.action)
                .accessibilityLabel(L("Filter charging costs"))
                .accessibilityIdentifier("charging-cost-filters")
            }
            HStack(alignment: .firstTextBaseline) {
                Text(units.money(history.total))
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(Brand.textPrimary).minimumScaleFactor(0.6).lineLimit(1)
                    .accessibilityIdentifier("charging-cost-total")
                Spacer()
                Text("\(history.sessions) \(L("sessions"))")
                    .font(.caption).foregroundStyle(Brand.textSecondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label(periodLabel, systemImage: "calendar")
                Label(filter.locations.isEmpty ? L("All locations") : filter.locations.sorted().joined(separator: ", "),
                      systemImage: "mappin.and.ellipse")
                    .lineLimit(2)
                    .accessibilityIdentifier("charging-cost-places")
            }
            .font(.caption).foregroundStyle(Brand.textSecondary)

            if !ready {
                ProgressView().frame(maxWidth: .infinity).frame(height: 200)
            } else if history.sessions == 0 {
                ContentUnavailableView(L("No charges match your filters."), systemImage: "chart.bar.xaxis")
                    .frame(height: 200)
            } else {
                monthlyChart
                if let selectedMonth,
                   let selected = history.months.first(where: { Calendar.current.isDate($0.start, equalTo: selectedMonth, toGranularity: .month) }) {
                    HStack {
                        Text(monthLabel(selected.start))
                        Spacer()
                        Text(units.money(selected.cost)).fontWeight(.semibold)
                    }
                    .font(.subheadline).foregroundStyle(Brand.action)
                }
            }
            Text(L("Independent filters for this chart. Sessions are counted by their start date."))
                .font(.caption2).foregroundStyle(Brand.textTertiary)
            if history.estimatedSessions > 0 {
                Label(L("Includes estimated costs"), systemImage: "info.circle")
                    .font(.caption2).foregroundStyle(Brand.textSecondary)
            }
        }
        .card()
        .sheet(isPresented: $showFilters) {
            ChargingCostFilterSheet(filter: filter, locations: locations, charges: env.history.charges) {
                filter = $0
            }
        }
        .task(id: key) {
            let snapshot = key
            let charges = env.history.charges
            ready = false
            let result = await Task.detached(priority: .userInitiated) {
                (ChargingCostHistory.make(charges: charges, pricing: snapshot.pricing, filter: snapshot.filter),
                 Array(Set(charges.map(\.locationName))).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
            }.value
            guard !Task.isCancelled else { return }
            history = result.0
            locations = result.1
            selectedMonth = nil
            ready = true
        }
        .onChange(of: env.live.resolvedCarID) { _, _ in filter.locations = [] }
    }

    private var monthlyChart: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                Chart(history.months) { month in
                    BarMark(x: .value(L("Month"), month.start, unit: .month),
                            y: .value(env.settings.config.currencyCode, month.cost), width: .ratio(0.6))
                        .foregroundStyle(Brand.action.gradient)
                        .cornerRadius(5)
                        .accessibilityLabel(monthLabel(month.start))
                        .accessibilityValue(units.money(month.cost))
                }
                .chartYScale(domain: 0...max(1, (history.months.map(\.cost).max() ?? 0) * 1.12))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(date.formatted(.dateTime.month(.abbreviated).year(.twoDigits).locale(LanguageManager.locale)))
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .chartXSelection(value: $selectedMonth)
                .frame(width: max(geometry.size.width, CGFloat(history.months.count) * 64), height: 210)
                .padding(.top, 4)
            }
            .defaultScrollAnchor(.trailing)
            .accessibilityIdentifier("charging-cost-chart")
        }
        .frame(height: 222)
    }

    private var periodLabel: String {
        switch filter.period {
        case .days: "\(AppDate.mediumDate(filter.start)) – \(AppDate.mediumDate(filter.end))"
        case .months: "\(monthLabel(filter.start)) – \(monthLabel(filter.end))"
        case .years: "\(Calendar.current.component(.year, from: filter.start)) – \(Calendar.current.component(.year, from: filter.end))"
        }
    }
    private func monthLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).year().locale(LanguageManager.locale))
    }
}

private struct ChargingCostFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var filter: ChargingCostFilter
    let locations: [String]
    let charges: [ChargeRecord]
    let apply: (ChargingCostFilter) -> Void
    @State private var search = ""

    private var years: [Int] {
        let calendar = Calendar.current
        let earliest = charges.map { calendar.component(.year, from: $0.startDate) }.min() ?? calendar.component(.year, from: Date())
        let latest = max(calendar.component(.year, from: Date()), charges.map { calendar.component(.year, from: $0.startDate) }.max() ?? earliest)
        return Array(min(earliest, calendar.component(.year, from: filter.start))...max(latest, calendar.component(.year, from: filter.end)))
    }
    private var matchingLocations: [String] {
        locations.filter { search.isEmpty || $0.localizedStandardContains(search) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L("Date range")) {
                    Picker(L("Period"), selection: $filter.period) {
                        ForEach(ChargingCostFilter.Period.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("charging-cost-period")
                    if filter.period == .days {
                        DatePicker(L("From"), selection: $filter.start, displayedComponents: .date)
                        DatePicker(L("To"), selection: $filter.end, displayedComponents: .date)
                    } else {
                        dateRow(L("From"), date: $filter.start)
                        dateRow(L("To"), date: $filter.end)
                    }
                    if filter.interval() == nil {
                        Text(L("The end must be on or after the start.")).foregroundStyle(Brand.warning)
                    }
                }
                Section {
                    SearchField(placeholder: L("Search location"), text: $search)
                        .accessibilityIdentifier("charging-cost-location-search")
                    Button { filter.locations = [] } label: {
                        HStack {
                            Text(L("All locations"))
                            Spacer()
                            if filter.locations.isEmpty { Image(systemName: "checkmark.circle.fill") }
                        }
                    }
                    .accessibilityIdentifier("charging-cost-all-locations")
                    ForEach(matchingLocations, id: \.self) { location in
                        Button {
                            if filter.locations.contains(location) { filter.locations.remove(location) }
                            else { filter.locations.insert(location) }
                        } label: {
                            HStack {
                                Text(location).foregroundStyle(Brand.textPrimary)
                                Spacer()
                                Image(systemName: filter.locations.contains(location) ? "checkmark.circle.fill" : "circle")
                            }
                        }
                        .accessibilityValue(filter.locations.contains(location) ? L("Selected") : L("Not selected"))
                        .accessibilityIdentifier("charging-cost-location-\(location)")
                    }
                    if matchingLocations.isEmpty { Text(L("No charging places")).foregroundStyle(Brand.textSecondary) }
                } header: { Text(L("Locations")) }
                  footer: { Text(L("Select one or more places. All locations are included when none are selected.")) }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .navigationTitle(L("Costs"))
            .navigationBarTitleDisplayModeInlineIfAvailable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Apply")) { apply(filter); dismiss() }
                        .disabled(filter.interval() == nil)
                        .accessibilityIdentifier("charging-cost-apply")
                }
            }
        }
        .tint(Brand.action)
    }

    private func dateRow(_ title: String, date: Binding<Date>) -> some View {
        HStack {
            Text(title)
            Spacer()
            if filter.period == .months {
                Picker(L("Month"), selection: component(.month, date: date)) {
                    ForEach(1...12, id: \.self) { month in
                        Text(LanguageManager.calendar.monthSymbols[month - 1]).tag(month)
                    }
                }.labelsHidden()
            }
            Picker(L("Year"), selection: component(.year, date: date)) {
                ForEach(years, id: \.self) { Text(String($0)).tag($0) }
            }.labelsHidden()
        }
    }

    private func component(_ part: Calendar.Component, date: Binding<Date>) -> Binding<Int> {
        Binding(get: { Calendar.current.component(part, from: date.wrappedValue) }, set: { value in
            var pieces = Calendar.current.dateComponents([.year, .month], from: date.wrappedValue)
            pieces.day = 1
            pieces.setValue(value, for: part)
            if let result = Calendar.current.date(from: pieces) { date.wrappedValue = result }
        })
    }
}
