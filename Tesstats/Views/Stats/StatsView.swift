import SwiftUI
import Charts

struct StatsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var range = StatsRange()
    @State private var refreshing = false
    @State private var exportSheet = false
    @State private var showSettings = false

    /// Derived analytics, rebuilt off the main actor only when `digestKey` changes.
    @State private var digest = StatsDigest()
    @State private var digestReady = false

    private var units: Units { Units(config: env.settings.config) }
    private var carID: Int { env.live.resolvedCarID ?? 1 }

    private var pricing: ChargePricing { ChargePricing(config: env.settings.config) }
    private var digestKey: StatsDigestKey {
        StatsDigestKey(revision: env.history.revision,
                       range: range,
                       pricing: pricing,
                       fuelLPer100km: env.settings.config.fuelConsumptionLPer100km)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.background.ignoresSafeArea()
                content
            }
            .navigationTitle(L("Stats"))
            .toolbarTitleDisplayModeInline()
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .leadingBar) { ConnectionStatusMenu() }
                ToolbarItem(placement: .principal) { ToolbarLogo() }
                #endif
                ToolbarItemGroup(placement: .trailingBar) {
                    Button { exportSheet = true } label: { Image(systemName: "square.and.arrow.up") }
                        .tint(Brand.action)
                    ArrangeSectionButton(section: .stats, blockType: StatsBlock.self)
                    RefreshButton(isRefreshing: refreshing) { Task { await refresh() } }
                    #if os(iOS)
                    SettingsGearButton(isPresented: $showSettings)
                    #endif
                }
            }
            .sheet(isPresented: $exportSheet) {
                ExportSheet(drives: digest.drives, charges: digest.charges)
            }
            .settingsSheet(isPresented: $showSettings)
        }
        .task(id: carID) { await env.history.loadIfNeeded(carID: carID) }
        .task(id: digestKey) { await rebuildDigest() }
    }

    /// Aggregating a multi-year history takes long enough to drop frames, so it runs off the
    /// main actor and the result is published in one assignment.
    private func rebuildDigest() async {
        let drives = env.history.drives
        let charges = env.history.charges
        let key = digestKey
        let fresh = await Task.detached(priority: .userInitiated) {
            StatsDigest.make(allDrives: drives, allCharges: charges,
                             range: key.range, pricing: key.pricing,
                             fuelLPer100km: key.fuelLPer100km)
        }.value
        guard !Task.isCancelled else { return }
        withAnimation(.snappy(duration: 0.2)) {
            digest = fresh
            digestReady = true
        }
    }

    /// Anything already downloaded is shown straight away; a load that is still running only
    /// adds a badge, so the screen never goes blank and never stops scrolling.
    @ViewBuilder
    private var content: some View {
        if env.history.hasData {
            loaded.refreshingBadge(env.history.isRefreshing)
        } else {
            switch env.history.phase {
            case .idle, .loading:
                LoadingStateView(label: L("Crunching your stats…"))
            case .failed(let message):
                ErrorStateView(message: message) { Task { await refresh() } }
            case .empty(let message):
                EmptyStateView(systemImage: "chart.bar.xaxis", title: L("No stats yet"), message: message)
            case .loaded:
                EmptyStateView(systemImage: "chart.bar.xaxis", title: L("No data to analyze yet"), message: nil)
            }
        }
    }

    private var loaded: some View {
        ScrollView {
            VStack(spacing: Metrics.cardSpacing) {
                let blocks = SectionLayout.visible(StatsBlock.self, layout: env.settings.config.layout(for: .stats))
                ForEach(blocks) { block in
                    if block == .filters {
                        RangeFilterBar(range: $range)
                            .padding(.top, 4)
                    } else if digestReady, !digest.isEmpty {
                        blockView(block)
                    } else if !digestReady {
                        LoadingCard(title: block.title, systemImage: block.icon)
                    }
                }
                if digestReady && digest.isEmpty {
                    Text(L("No drives or charges in this period."))
                        .font(.subheadline).foregroundStyle(Brand.textSecondary)
                        .frame(maxWidth: .infinity).padding(.top, 30)
                }
                Color.clear.frame(height: 8)
            }
            .padding(.horizontal, Metrics.screenPadding)
        }
        .scrollContentBackground(.hidden)
        .bottomScrollClearance()
        .refreshable { await refresh() }
    }

    @ViewBuilder
    private func blockView(_ block: StatsBlock) -> some View {
        switch block {
        case .filters: EmptyView()
        case .comparison: if let cmp = digest.comparison { ComparisonCard(comparison: cmp, units: units) }
        case .cost: CostCard(cost: digest.cost, units: units)
        case .trends: TrendsCard(monthly: digest.monthly, monthlyAllTime: digest.monthlyAllTime, units: units)
        case .charging: if !digest.chargingLocations.isEmpty { ChargingLocationsCard(locations: digest.chargingLocations, units: units) }
        case .usage: UsageCard(weekdays: digest.weekdays, hours: digest.hours, units: units)
        case .heatmap: HeatmapCard(days: digest.heatmap, units: units)
        case .records: RecordsCard(records: digest.records, units: units)
        case .temperature: if !digest.tempPoints.isEmpty { TempConsumptionCard(points: digest.tempPoints, bins: digest.tempBins, units: units) }
        case .drain: if let drain = digest.drain { PhantomDrainCard(drain: drain, units: units) }
        case .eco: EcoCard(eco: digest.eco, units: units)
        }
    }

    private func refresh() async {
        refreshing = true
        await env.history.refresh(carID: carID)
        refreshing = false
    }
}

// MARK: - Comparison

private struct ComparisonCard: View {
    let comparison: PeriodComparison
    let units: Units

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(L("This month \(comparison.label)"), systemImage: "calendar")
            TileGrid(columns: 2) {
                row(L("Distance"), units.distance(km: comparison.distanceKm.current, digits: 0), PeriodComparison.delta(comparison.distanceKm), invert: false)
                row(L("Energy"), units.energy(kwh: comparison.energyKwh.current, digits: 0), PeriodComparison.delta(comparison.energyKwh), invert: false)
                row(L("Cost"), units.money(comparison.cost.current), PeriodComparison.delta(comparison.cost), invert: true)
                row(L("Consumption"), units.consumption(whPerKm: comparison.consumptionWhPerKm.current > 0 ? comparison.consumptionWhPerKm.current : nil), PeriodComparison.delta(comparison.consumptionWhPerKm), invert: true)
            }
            Text(L("Compares full calendar months — the range filter above does not apply here."))
                .font(.caption2).foregroundStyle(Brand.textTertiary)
        }
        .card()
    }

    /// `invert` flips the good/bad coloring (lower cost & consumption is good).
    private func row(_ title: String, _ value: String, _ delta: Double?, invert: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(Brand.textTertiary).lineLimit(1)
            Text(value).font(.title3.weight(.semibold)).foregroundStyle(Brand.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
            if let delta, abs(delta) >= 0.5 {
                let good = invert ? delta < 0 : delta > 0
                HStack(spacing: 3) {
                    Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right").font(.caption2.weight(.bold))
                    Text(units.percent(delta, signed: true)).font(.caption2.weight(.semibold))
                }
                .foregroundStyle(good ? Brand.online : Brand.warning)
            } else {
                Text(L("≈ same")).font(.caption2).foregroundStyle(Brand.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Trends

private enum TrendMetric: String, CaseIterable, Identifiable {
    case distance, energy, cost, consumption
    var id: String { rawValue }
    var label: String {
        switch self {
        case .distance: L("Distance")
        case .energy: L("Energy")
        case .cost: L("Cost")
        case .consumption: L("Consumption")
        }
    }
}

private struct TrendsCard: View {
    let monthly: [MonthlyStat]
    /// Unfiltered history, pivoted per-year for the year-over-year overlay.
    let monthlyAllTime: [MonthlyStat]
    let units: Units
    @State private var metric: TrendMetric = .distance
    @State private var compareYears = false
    @State private var scrubDate: Date?

    private var years: [(year: Int, months: [MonthlyStat])] { StatsEngine.yearOverYear(monthlyAllTime) }
    private var canCompareYears: Bool { years.count == 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                SectionHeader(L("Trends over time"), systemImage: "chart.bar.xaxis")
                if canCompareYears {
                    Button {
                        withAnimation(.snappy) { compareYears.toggle() }
                    } label: {
                        Label(L("Years"), systemImage: "calendar.badge.clock")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(compareYears ? Brand.crimson : Brand.textTertiary)
                }
            }
            Picker("", selection: $metric) {
                ForEach(TrendMetric.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            if monthly.count < 2 {
                Text(L("Not enough history yet to show monthly trends."))
                    .font(.subheadline).foregroundStyle(Brand.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if metric == .cost && monthly.allSatisfy({ $0.chargeCost <= 0.01 }) {
                Text(L("No cost data. Set a charge price per kWh in Settings — or per location below — to see cost trends."))
                    .font(.subheadline).foregroundStyle(Brand.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if compareYears, canCompareYears {
                yearComparisonChart
            } else {
                Chart {
                    ForEach(monthly) { m in
                        BarMark(x: .value("Month", m.month, unit: .month),
                                y: .value(metric.label, value(m)))
                            .foregroundStyle(Brand.crimson.gradient)
                            .cornerRadius(4)
                            .opacity(scrubbedMonth == nil || scrubbedMonth?.id == m.id ? 1 : 0.45)
                    }
                    if let m = scrubbedMonth {
                        RuleMark(x: .value("Month", m.month, unit: .month))
                            .foregroundStyle(.clear)
                            .annotation(position: .top,
                                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                Text("\(m.month, format: .dateTime.month(.abbreviated).year().appLanguage) · \(scrubbedValueLabel(m))")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Brand.textPrimary)
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Brand.elevatedSurface, in: Capsule())
                            }
                    }
                }
                .chartXSelection(value: $scrubDate)
                .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Brand.hairline); AxisValueLabel() } }
                .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisGridLine().foregroundStyle(Brand.hairline); AxisValueLabel(format: .dateTime.month(.narrow).appLanguage) } }
                .frame(height: 200)
                HStack {
                    Text(unitCaption).font(.caption2).foregroundStyle(Brand.textTertiary)
                    Spacer()
                    Text(totalCaption).font(.caption2.weight(.semibold)).foregroundStyle(Brand.textSecondary)
                }
            }
        }
        .card()
    }

    // MARK: Year-over-year overlay

    @ViewBuilder
    private var yearComparisonChart: some View {
        let cal = Calendar.current
        if years.count >= 2 {
            let previous = years[0], current = years[1]
            Chart {
            ForEach(current.months) { m in
                BarMark(x: .value("Month", cal.component(.month, from: m.month)),
                        y: .value(metric.label, value(m)))
                    .foregroundStyle(Brand.crimson.gradient)
                    .cornerRadius(4)
            }
            ForEach(previous.months) { m in
                let month = cal.component(.month, from: m.month)
                LineMark(x: .value("Month", month),
                         y: .value(metric.label, value(m)))
                    .foregroundStyle(Brand.textTertiary)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                PointMark(x: .value("Month", month),
                          y: .value(metric.label, value(m)))
                    .foregroundStyle(Brand.textTertiary)
                    .symbolSize(18)
            }
            }
            .chartXScale(domain: 0.5...12.5)
            .chartXAxis {
                AxisMarks(values: Array(1...12)) { v in
                    AxisGridLine().foregroundStyle(Brand.hairline)
                    AxisValueLabel {
                        if let m = v.as(Int.self), (1...12).contains(m),
                           LanguageManager.calendar.veryShortMonthSymbols.indices.contains(m - 1) {
                            Text(LanguageManager.calendar.veryShortMonthSymbols[m - 1])
                        }
                    }
                }
            }
            .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Brand.hairline); AxisValueLabel() } }
            .frame(height: 200)
            HStack(spacing: 10) {
                Chip(text: String(current.year), color: Brand.crimson)
                Chip(text: String(previous.year), color: Brand.textTertiary)
                Spacer()
                Text(unitCaption).font(.caption2).foregroundStyle(Brand.textTertiary)
            }
            Text(L("Whole calendar years — the range filter does not apply to this comparison."))
                .font(.caption2).foregroundStyle(Brand.textTertiary)
        }
    }

    /// The month bucket under the scrub position.
    private var scrubbedMonth: MonthlyStat? {
        guard let scrubDate else { return nil }
        let cal = Calendar.current
        return monthly.first { cal.isDate($0.month, equalTo: scrubDate, toGranularity: .month) }
    }

    private func scrubbedValueLabel(_ m: MonthlyStat) -> String {
        switch metric {
        case .distance: units.distance(km: m.distanceKm, digits: 0)
        case .energy: units.energy(kwh: m.energyChargedKwh, digits: 0)
        case .cost: units.money(m.chargeCost)
        case .consumption: units.consumption(whPerKm: m.avgConsumptionWhPerKm > 0 ? m.avgConsumptionWhPerKm : nil)
        }
    }

    private func value(_ m: MonthlyStat) -> Double {
        switch metric {
        case .distance: units.distance == .imperial ? m.distanceKm / 1.609344 : m.distanceKm
        case .energy: m.energyChargedKwh
        case .cost: m.chargeCost
        case .consumption: units.distance == .imperial ? m.avgConsumptionWhPerKm * 1.609344 : m.avgConsumptionWhPerKm
        }
    }

    private var unitCaption: String {
        switch metric {
        case .distance: units.distanceUnit
        case .energy: "kWh"
        case .cost: units.currency
        case .consumption: units.distance == .imperial ? "Wh/mi" : "Wh/km"
        }
    }

    private var totalCaption: String {
        switch metric {
        case .distance: L("Total \(units.distance(km: monthly.reduce(0) { $0 + $1.distanceKm }, digits: 0))")
        case .energy: L("Total \(units.energy(kwh: monthly.reduce(0) { $0 + $1.energyChargedKwh }, digits: 0))")
        case .cost: L("Total \(units.money(monthly.reduce(0) { $0 + $1.chargeCost }))")
        case .consumption: ""
        }
    }
}

// MARK: - Cost

private struct CostCard: View {
    let cost: CostSummary
    let units: Units

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(cost.costIsEstimated ? L("Cost (estimated)") : L("Cost"), systemImage: "creditcard")
            TileGrid(columns: 2) {
                StatTile(title: L("Total"), value: units.money(cost.totalCost), tint: Brand.crimson)
                if let per100 = cost.costPer100Km {
                    StatTile(title: L("Per 100 \(units.distanceUnit)"),
                             value: units.money(units.distance == .imperial ? per100 * 1.609344 : per100))
                }
                if let kwh = cost.avgPricePerKwh {
                    StatTile(title: L("Avg / kWh"), value: units.money(kwh))
                }
                if let monthly = cost.monthlyProjection {
                    StatTile(title: L("≈ Monthly"), value: units.money(monthly), systemImage: "calendar")
                }
                if let annual = cost.annualProjection {
                    StatTile(title: L("≈ Yearly"), value: units.money(annual), systemImage: "calendar")
                }
            }
            if cost.costIsEstimated {
                Text(L("Some sessions use estimated costs from your configured charging prices."))
                    .font(.caption2).foregroundStyle(Brand.textTertiary)
            }
        }
        .card()
    }
}

// MARK: - Eco

private struct EcoCard: View {
    let eco: EcoImpact
    let units: Units

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(L("Environmental impact"), systemImage: "leaf.fill")
            TileGrid(columns: 3) {
                StatTile(title: L("CO₂ avoided"), value: co2, systemImage: "smoke", tint: Brand.online)
                StatTile(title: L("Petrol avoided"), value: "\(units.number(eco.litersAvoided)) L", systemImage: "fuelpump")
                StatTile(title: L("Tree-years"), value: units.number(eco.treeYears), systemImage: "leaf.fill")
            }
            Text(L("Versus an equivalent combustion car over \(units.distance(km: eco.distanceKm, digits: 0))."))
                .font(.caption2).foregroundStyle(Brand.textTertiary)
        }
        .card()
    }

    private var co2: String {
        eco.co2AvoidedKg >= 1000
            ? "\(units.number(eco.co2AvoidedKg / 1000, digits: 2)) t"
            : "\(units.number(eco.co2AvoidedKg)) kg"
    }
}

// MARK: - Temperature vs consumption

private struct TempConsumptionCard: View {
    let points: [TempConsumptionPoint]
    let bins: [TempBin]
    let units: Units

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(L("Consumption vs temperature"), systemImage: "thermometer.snowflake")
            Chart {
                ForEach(points) { p in
                    PointMark(x: .value("Temp", tempX(p.outsideTempC)),
                              y: .value("Wh", consY(p.consumptionWhPerKm)))
                        .foregroundStyle(Brand.crimson.opacity(0.35))
                        .symbolSize(18)
                }
                ForEach(bins) { b in
                    LineMark(x: .value("Temp", tempX(Double(b.lowerC) + 2.5)),
                             y: .value("Wh", consY(b.avgConsumptionWhPerKm)))
                        .foregroundStyle(Brand.crimsonBright)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Brand.hairline); AxisValueLabel() } }
            .chartXAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Brand.hairline); AxisValueLabel() } }
            .frame(height: 200)
            Text(L("Each dot is a drive — colder weather usually pushes consumption up (x: \(tempUnit), y: \(consUnit))."))
                .font(.caption2).foregroundStyle(Brand.textTertiary)
        }
        .card()
    }

    private func tempX(_ c: Double) -> Double { units.temp == .fahrenheit ? c * 9 / 5 + 32 : c }
    private func consY(_ wh: Double) -> Double { units.distance == .imperial ? wh * 1.609344 : wh }
    private var tempUnit: String { units.temp == .fahrenheit ? "°F" : "°C" }
    private var consUnit: String { units.distance == .imperial ? "Wh/mi" : "Wh/km" }
}

// MARK: - Usage patterns

private struct UsageCard: View {
    let weekdays: [WeekdayUsage]
    let hours: [HourUsage]
    let units: Units

    private var weekdaySymbols: [String] { LanguageManager.calendar.shortWeekdaySymbols }
    /// Day labels in the same order as `weekdays` (which starts on the locale's first weekday),
    /// used to fix the chart's category order so it starts on Monday rather than alphabetically.
    private var weekdayOrder: [String] { weekdays.map { weekdaySymbols[($0.weekday - 1) % 7] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(L("When you drive"), systemImage: "clock.arrow.circlepath")
            Text(L("By weekday")).font(.caption).foregroundStyle(Brand.textTertiary)
            Chart(weekdays) { w in
                BarMark(x: .value("Day", weekdaySymbols[(w.weekday - 1) % 7]),
                        y: .value("Distance", units.distance == .imperial ? w.distanceKm / 1.609344 : w.distanceKm))
                    .foregroundStyle(Brand.crimson.gradient)
                    .cornerRadius(3)
            }
            .chartXScale(domain: weekdayOrder)
            .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Brand.hairline); AxisValueLabel() } }
            .frame(height: 130)

            Text(L("By hour of day")).font(.caption).foregroundStyle(Brand.textTertiary).padding(.top, 4)
            Chart(hours) { h in
                BarMark(x: .value("Hour", h.hour),
                        y: .value("Drives", h.driveCount))
                    .foregroundStyle(Brand.driving.gradient)
                    .cornerRadius(2)
            }
            .chartXScale(domain: 0...23)
            .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) { v in AxisValueLabel { if let h = v.as(Int.self) { Text("\(h)h") } } } }
            .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Brand.hairline); AxisValueLabel() } }
            .frame(height: 110)
        }
        .card()
    }
}

// MARK: - Calendar heatmap

private struct HeatmapCard: View {
    let days: [CalendarDay]
    let units: Units

    @State private var gridWidth: CGFloat = 0
    @State private var selectedDay: CalendarDay?
    private let cellSpacing: CGFloat = 3

    private var maxKm: Double { max(1, days.map(\.distanceKm).max() ?? 1) }
    private var weeks: [[CalendarDay]] { stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) } }

    /// Cell size derived so the whole grid spans the available width edge-to-edge — that keeps the
    /// left and right margins identical (both equal to the card padding) on any screen size.
    private var cellSize: CGFloat {
        let cols = max(weeks.count, 1)
        guard gridWidth > 0 else { return 13 }
        return max(6, (gridWidth - CGFloat(cols - 1) * cellSpacing) / CGFloat(cols))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(L("Activity"), systemImage: "calendar")
            monthLabels
            HStack(alignment: .top, spacing: cellSpacing) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: cellSpacing) {
                        ForEach(week) { day in
                            cell(day)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
            if let day = selectedDay {
                selectionDetail(day)
            } else {
                HStack(spacing: 6) {
                    Text(L("Less")).font(.caption2).foregroundStyle(Brand.textTertiary)
                    ForEach(0..<5) { i in
                        RoundedRectangle(cornerRadius: 2).fill(Brand.crimson.opacity(0.15 + Double(i) * 0.2)).frame(width: 11, height: 11)
                    }
                    Text(L("More")).font(.caption2).foregroundStyle(Brand.textTertiary)
                    Spacer()
                    Text(L("Tap a day for details")).font(.caption2).foregroundStyle(Brand.textTertiary)
                }
            }
        }
        .card()
    }

    private func cell(_ day: CalendarDay) -> some View {
        let selected = selectedDay?.id == day.id
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color(for: day.distanceKm))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(Brand.textPrimary, lineWidth: 1.5)
                }
            }
            .frame(width: cellSize, height: cellSize)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.snappy(duration: 0.15)) {
                    selectedDay = selected ? nil : day
                }
            }
    }

    /// GitHub-style month abbreviations above the grid, one at each month change.
    private var monthLabels: some View {
        let cal = Calendar.current
        let step = cellSize + cellSpacing
        return ZStack(alignment: .topLeading) {
            Color.clear.frame(height: 12)
            ForEach(Array(weeks.enumerated()), id: \.offset) { idx, week in
                if let first = week.first?.day, showsLabel(at: idx, calendar: cal) {
                    Text(first, format: .dateTime.month(.abbreviated).appLanguage)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Brand.textTertiary)
                        .fixedSize()
                        .offset(x: CGFloat(idx) * step)
                }
            }
        }
    }

    /// Label a column when its first day starts a new month vs. the previous column.
    /// The very first column is labeled only if no month change follows within two
    /// columns (so two labels never overlap).
    private func showsLabel(at index: Int, calendar cal: Calendar) -> Bool {
        func month(_ i: Int) -> Int? { weeks[i].first.map { cal.component(.month, from: $0.day) } }
        guard let current = month(index) else { return false }
        if index == 0 {
            let next = (1...2).compactMap { $0 < weeks.count ? month($0) : nil }
            return next.allSatisfy { $0 == current }
        }
        return month(index - 1) != current
    }

    private func selectionDetail(_ day: CalendarDay) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar").font(.caption).foregroundStyle(Brand.crimson)
            Text(day.day, format: .dateTime.weekday(.abbreviated).day().month().year().appLanguage)
                .font(.caption.weight(.semibold)).foregroundStyle(Brand.textPrimary)
            Spacer()
            Text(day.driveCount == 0
                 ? L("No drives")
                 : L("\(day.driveCount) drives · \(units.distance(km: day.distanceKm, digits: 1))"))
                .font(.caption).foregroundStyle(Brand.textSecondary)
        }
        .padding(.top, 2)
    }

    private func color(for km: Double) -> Color {
        guard km > 0 else { return Brand.elevatedSurface }
        let t = min(1, km / maxKm)
        return Brand.crimson.opacity(0.18 + t * 0.75)
    }
}

// MARK: - Phantom drain

private struct PhantomDrainCard: View {
    let drain: PhantomDrain
    let units: Units

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(L("Phantom drain"), systemImage: "moon.zzz")
            TileGrid(columns: 2) {
                StatTile(title: L("Per day"), value: units.percent(drain.avgPercentPerDay, digits: 1), tint: Brand.warning)
                StatTile(title: L("Range / day"), value: units.distance(km: drain.avgRangeLossKmPerDay, digits: 1))
            }
            Text(L("Estimated standby loss while parked, from \(drain.idleSamples) idle periods. Real-world, not a defect."))
                .font(.caption2).foregroundStyle(Brand.textTertiary)
        }
        .card()
    }
}

// MARK: - Charging locations

private struct ChargingLocationsCard: View {
    @Environment(AppEnvironment.self) private var env
    let locations: [ChargingLocation]
    let units: Units

    @State private var editing: ChargingLocation?
    @State private var priceText = ""

    private var shown: [ChargingLocation] { Array(locations.prefix(6)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(L("Where you charge"), systemImage: "mappin.circle")
            ForEach(shown) { loc in
                Button { beginEditing(loc) } label: { row(loc) }
                    .buttonStyle(.plain)
                if loc.id != shown.last?.id { Divider().overlay(Brand.hairline) }
            }
            Text(L("Tap a place to set its price per kWh for more accurate cost. Optional."))
                .font(.caption2).foregroundStyle(Brand.textTertiary)
        }
        .card()
        .alert(L("Price per kWh"), isPresented: editingBinding, presenting: editing) { loc in
            TextField(defaultPriceText, text: $priceText)
                .keyboardTypeDecimal()
            Button(L("Save")) { savePrice(for: loc) }
            if override(loc) != nil {
                Button(L("Use default"), role: .destructive) { clearPrice(for: loc) }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: { loc in
            Text(L("Price you pay per kWh at \(loc.name). Used to estimate cost when TeslaMate has none. Leave empty to use the default (\(defaultPriceLabel))."))
        }
    }

    private func row(_ loc: ChargingLocation) -> some View {
        HStack(spacing: 10) {
            Image(systemName: loc.isFast ? "bolt.car.fill" : "house.fill")
                .font(.subheadline).foregroundStyle(Brand.crimson).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(loc.name).font(.subheadline.weight(.medium)).foregroundStyle(Brand.textPrimary).lineLimit(1)
                Text(L("\(loc.sessions) sessions · \(units.energy(kwh: loc.energyKwh, digits: 0))"))
                    .font(.caption2).foregroundStyle(Brand.textTertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(loc.cost > 0 ? units.money(loc.cost) : units.power(kw: loc.avgPowerKw > 0 ? loc.avgPowerKw : nil))
                    .font(.caption.weight(.semibold)).foregroundStyle(Brand.textSecondary)
                if let custom = override(loc) {
                    Text(L("\(units.money(custom))/kWh"))
                        .font(.caption2.weight(.semibold)).foregroundStyle(Brand.crimson)
                }
            }
            Image(systemName: "chevron.right")
                .font(.caption2).foregroundStyle(Brand.textTertiary)
        }
        .contentShape(Rectangle())
    }

    private var editingBinding: Binding<Bool> {
        Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })
    }
    private func override(_ loc: ChargingLocation) -> Double? {
        env.settings.config.chargePricePerKwhByLocation[loc.name]
    }
    private var defaultPriceText: String { String(format: "%g", env.settings.config.chargePricePerKwh) }
    private var defaultPriceLabel: String { units.money(env.settings.config.chargePricePerKwh) }

    private func beginEditing(_ loc: ChargingLocation) {
        priceText = override(loc).map { String(format: "%g", $0) } ?? ""
        editing = loc
    }
    private func savePrice(for loc: ChargingLocation) {
        if let v = ChargePriceInput.value(from: priceText) {
            env.settings.config.chargePricePerKwhByLocation[loc.name] = v
        } else {
            env.settings.config.chargePricePerKwhByLocation.removeValue(forKey: loc.name)
        }
        env.settings.save()
        editing = nil
    }
    private func clearPrice(for loc: ChargingLocation) {
        env.settings.config.chargePricePerKwhByLocation.removeValue(forKey: loc.name)
        env.settings.save()
        editing = nil
    }
}

// MARK: - Records

private struct RecordsCard: View {
    let records: Superlatives
    let units: Units

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(L("Records"), systemImage: "trophy")
            if let d = records.longestDrive {
                record("road.lanes", L("Longest trip"), "\(units.distance(km: d.distanceKm)) · \(d.destinationName)")
            }
            if let d = records.mostEfficientDrive, let c = d.consumptionWhPerKm {
                record("leaf", L("Most efficient"), "\(units.consumption(whPerKm: c)) · \(d.destinationName)")
            }
            if let top = records.topSpeedKmh {
                record("speedometer", L("Top speed"), units.speed(kmh: top))
            }
            if let kw = records.maxRegenKw, kw > 0 {
                record("arrow.uturn.down.circle", L("Peak regen"),
                       records.bestRegenDrive.map { "\(units.power(kw: kw)) · \($0.destinationName)" } ?? units.power(kw: kw))
            }
            if let c = records.biggestCharge {
                record("bolt.fill", L("Biggest charge"), "\(units.energy(kwh: c.energyAddedKwh)) · \(c.locationName)")
            }
            if let c = records.fastestCharge, let p = c.avgPowerKw {
                record("bolt.car", L("Highest avg power"), "\(units.power(kw: p)) · \(c.locationName)")
            }
        }
        .card()
    }

    private func record(_ icon: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.subheadline).foregroundStyle(Brand.crimson).frame(width: 22)
            Text(title).font(.subheadline).foregroundStyle(Brand.textSecondary)
            Spacer(minLength: 10)
            Text(value).font(.subheadline.weight(.medium)).foregroundStyle(Brand.textPrimary)
                .lineLimit(1).multilineTextAlignment(.trailing)
        }
    }
}
