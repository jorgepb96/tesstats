import SwiftUI
import Charts

struct BatteryView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var timeRange: TimeRange = .all
    @State private var refreshing = false
    @State private var showSettings = false
    @State private var scrubDate: Date?

    private var units: Units { Units(config: env.settings.config) }
    private var carID: Int { env.live.resolvedCarID ?? 1 }

    /// The degradation curve, already unit-converted. Held in `@State` and rebuilt only when
    /// something that changes it changes: it used to be re-derived three times per body pass,
    /// and once more per frame of a chart scrub.
    @State private var curve = BatteryCurve()
    @State private var curveReady = false

    private struct CurveKey: Equatable {
        var revision: Int
        var timeRange: TimeRange
        var imperial: Bool
    }

    private var curveKey: CurveKey {
        CurveKey(revision: env.history.revision,
                 timeRange: timeRange,
                 imperial: units.distance == .imperial)
    }

    private func rebuildCurve() async {
        let battery = env.history.battery
        let key = curveKey
        let fresh = await Task.detached(priority: .userInitiated) {
            BatteryCurve.make(points: battery, timeRange: key.timeRange, imperial: key.imperial)
        }.value
        guard !Task.isCancelled else { return }
        curve = fresh
        curveReady = true
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.background.ignoresSafeArea()
                content
            }
            .navigationTitle(L("Battery"))
            .toolbarTitleDisplayModeInline()
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .leadingBar) { ConnectionStatusMenu() }
                ToolbarItem(placement: .principal) { ToolbarLogo() }
                #endif
                ToolbarItemGroup(placement: .trailingBar) {
                    ArrangeSectionButton(section: .battery, blockType: BatteryBlock.self)
                    RefreshButton(isRefreshing: refreshing) { Task { await refresh() } }
                    #if os(iOS)
                    SettingsGearButton(isPresented: $showSettings)
                    #endif
                }
            }
            .settingsSheet(isPresented: $showSettings)
        }
        .task(id: carID) { await env.history.loadIfNeeded(carID: carID) }
        .task(id: curveKey) { await rebuildCurve() }
    }

    @ViewBuilder
    private func blockView(_ block: BatteryBlock) -> some View {
        switch block {
        case .current: if let state = env.live.currentState { liveHealthCard(state) }
        case .timeline: SocTimelineCard(drives: env.history.drives,
                                        charges: env.history.charges,
                                        liveSoc: env.live.currentState?.batteryLevel,
                                        revision: env.history.revision)
        case .health: officialHealthCard
        case .degradation: degradationCard
        case .efficiency: efficiencyCard
        case .updates: updatesCard
        }
    }

    /// Whatever is already downloaded stays on screen; a load still in flight only adds a badge.
    @ViewBuilder
    private var content: some View {
        if env.history.hasData || env.live.currentState != nil {
            loaded.refreshingBadge(env.history.isRefreshing)
        } else {
            switch env.history.phase {
            case .idle, .loading:
                LoadingStateView(label: L("Loading battery data…"))
            case .failed(let message):
                ErrorStateView(message: message) { Task { await refresh() } }
            case .empty(let message):
                EmptyStateView(systemImage: "battery.25percent", title: L("No battery data"), message: message)
            case .loaded:
                EmptyStateView(systemImage: "battery.25percent", title: L("No battery data"), message: nil)
            }
        }
    }

    private var loaded: some View {
        ScrollView {
            VStack(spacing: Metrics.cardSpacing) {
                ForEach(SectionLayout.visible(BatteryBlock.self, layout: env.settings.config.layout(for: .battery))) { block in
                    // `.current` reads only the live MQTT state, so it never waits on history.
                    if curveReady || block == .current {
                        blockView(block)
                    } else {
                        LoadingCard(title: block.title, systemImage: block.icon)
                    }
                }
                Color.clear.frame(height: 8)
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.top, 4)
        }
        .scrollContentBackground(.hidden)
        .bottomScrollClearance()
        .refreshable { await refresh() }
    }

    private func liveHealthCard(_ state: VehicleState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(L("Current"), systemImage: "heart.text.square")
            TileGrid(columns: 3) {
                StatTile(title: L("Charge"), value: "\(state.batteryLevel ?? 0)%", tint: Brand.crimson)
                StatTile(title: L("Usable"), value: state.usableBatteryLevel.map { "\($0)%" } ?? "—")
                StatTile(title: L("Range"), value: units.range(km: state.range(for: units.range)))
                if let cap = currentCapacity {
                    StatTile(title: L("Capacity now"), value: units.energy(kwh: cap, digits: 1), tint: Brand.crimson)
                }
                if let eff = env.history.carInfo?.efficiencyKwhPerKm, eff > 0 {
                    UnitStatTile(title: L("Rated eff."), value: units.consumption(whPerKm: eff * 1000)) { UnitToggle.consumption(env) }
                }
                StatTile(title: L("Health"),
                         value: state.healthy == true ? L("OK") : (state.healthy == false ? L("Check") : "—"),
                         tint: state.healthy == false ? Brand.danger : Brand.online)
            }
        }
        .card()
    }

    private var currentCapacity: Double? { env.history.battery.last?.usableCapacityKwh }
    private var originalCapacity: Double? { env.history.battery.first?.usableCapacityKwh }

    /// Footnote adapts to whether we have TeslaMate's official figures or only the local estimate.
    private var degradationFootnote: String {
        env.history.batteryHealthSummary != nil
            ? L("Battery health uses TeslaMate's official calculation. The degradation curve below is derived from your charge history.")
            : L("Degradation is derived from charge data (rated range projected to 100% and measured kWh per SoC). An estimate, not a factory spec.")
    }

    /// Official battery-health snapshot from TeslaMateApi, shown when available.
    @ViewBuilder
    private var officialHealthCard: some View {
        if let h = env.history.batteryHealthSummary, h.healthPercentage > 0 || h.maxCapacityKwh > 0 {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(L("Battery health"), systemImage: "cross.case")
                HStack(spacing: 16) {
                    if h.healthPercentage > 0 { statBlock(L("Health"), units.percent(h.healthPercentage)) }
                    if let loss = h.capacityLossFraction { statBlock(L("Degraded"), units.percent(loss * 100, digits: 1)) }
                }
                TileGrid(columns: 2) {
                    if h.currentCapacityKwh > 0 {
                        StatTile(title: L("Capacity now"), value: units.energy(kwh: h.currentCapacityKwh, digits: 1), tint: Brand.crimson)
                    }
                    if h.maxCapacityKwh > 0 {
                        StatTile(title: L("Capacity when new"), value: units.energy(kwh: h.maxCapacityKwh, digits: 1))
                    }
                    if h.currentRangeKm > 0 {
                        StatTile(title: L("Max range now"), value: units.range(km: h.currentRangeKm))
                    }
                    if h.maxRangeKm > 0 {
                        StatTile(title: L("Max range when new"), value: units.range(km: h.maxRangeKm))
                    }
                }
            }
            .card()
        }
    }

    /// Firmware update history from TeslaMateApi's /updates endpoint.
    @ViewBuilder
    private var updatesCard: some View {
        if !env.history.updates.isEmpty {
            let shown = Array(env.history.updates.prefix(8))
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(L("Software updates"), systemImage: "arrow.down.circle")
                ForEach(shown) { u in
                    HStack(spacing: 10) {
                        Image(systemName: "cpu").font(.subheadline).foregroundStyle(Brand.crimson).frame(width: 22)
                        Text(u.version).font(.subheadline.weight(.medium)).foregroundStyle(Brand.textPrimary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Spacer(minLength: 10)
                        Text(units.shortDate(u.startDate)).font(.caption.weight(.medium)).foregroundStyle(Brand.textSecondary)
                    }
                    if u.id != shown.last?.id { Divider().overlay(Brand.hairline) }
                }
            }
            .card()
        }
    }


    private var degradationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeader(L("Degradation"), systemImage: "chart.line.downtrend.xyaxis")
            }
            SegmentedFilter(selection: $timeRange)

            if curve.points.count < 2 {
                Text(L("Not enough charge history yet to plot a degradation curve."))
                    .font(.subheadline).foregroundStyle(Brand.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                HStack(spacing: 16) {
                    statBlock(L("Max range now"), units.range(km: env.history.battery.last?.maxRangeKm))
                    if let lost = degradationSummary {
                        statBlock(L("Lost"), units.percent(lost, digits: 1))
                    }
                    if let cap = currentCapacity {
                        statBlock(L("Capacity"), units.energy(kwh: cap, digits: 1))
                    }
                }
                Chart {
                    ForEach(curve.points) { point in
                        AreaMark(x: .value("Date", point.date), y: .value("Range", point.value))
                            .foregroundStyle(LinearGradient(colors: [Brand.crimson.opacity(0.35), .clear],
                                                             startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Date", point.date), y: .value("Range", point.value))
                            .foregroundStyle(Brand.crimson)
                            .interpolationMethod(.catmullRom)
                        PointMark(x: .value("Date", point.date), y: .value("Range", point.value))
                            .foregroundStyle(Brand.crimson)
                            .symbolSize(16)
                    }
                    if let p = scrubbedDegradationPoint {
                        RuleMark(x: .value("Date", p.date))
                            .foregroundStyle(Brand.textTertiary.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        PointMark(x: .value("Date", p.date), y: .value("Range", p.value))
                            .foregroundStyle(Brand.crimsonBright)
                            .symbolSize(50)
                            .annotation(position: .top,
                                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                Text("\(p.date, format: .dateTime.month(.abbreviated).year().appLanguage) · \(units.range(km: rawRangeKm(for: p)))")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Brand.textPrimary)
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Brand.elevatedSurface, in: Capsule())
                            }
                    }
                }
                .chartXSelection(value: $scrubDate)
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Brand.hairline); AxisValueLabel() } }
                .chartXAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Brand.hairline); AxisValueLabel(format: .dateTime.month(.abbreviated).appLanguage) } }
                .frame(height: 200)
                Text(L("Touch and drag to inspect a month."))
                    .font(.caption2).foregroundStyle(Brand.textTertiary)
            }
            Text(degradationFootnote)
                .font(.caption2).foregroundStyle(Brand.textTertiary)
        }
        .card()
    }

    /// Nearest degradation sample to the scrubbed date.
    private var scrubbedDegradationPoint: BatteryCurve.Point? {
        guard let scrubDate else { return nil }
        return curve.points.min {
            abs($0.date.timeIntervalSince(scrubDate)) < abs($1.date.timeIntervalSince(scrubDate))
        }
    }

    /// The chart value is already unit-converted; recover km for `units.range` formatting.
    private func rawRangeKm(for point: BatteryCurve.Point) -> Double {
        units.distance == .imperial ? point.value * 1.609344 : point.value
    }

    private var degradationSummary: Double? { curve.lostPercent }

    private var totalChargedKwh: Double { env.history.chargeAggregates.totalEnergyKwh }
    private var chargeCycles: Double? {
        guard let cap = currentCapacity ?? originalCapacity, cap > 0, totalChargedKwh > 0 else { return nil }
        return totalChargedKwh / cap
    }

    private var efficiencyCard: some View {
        let eff = env.history.efficiency
        let info = env.history.carInfo
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(L("Efficiency & totals"), systemImage: "leaf")
            TileGrid(columns: 3) {
                ConsumptionStat(title: L("Avg consumption"), whPerKm: eff.avgWhPerKm > 0 ? eff.avgWhPerKm : nil, units: units)
                StatTile(title: L("Distance"), value: units.distance(km: eff.totalDistanceKm, digits: 0))
                StatTile(title: L("Top speed"), value: units.speed(kmh: eff.maxSpeedKmh > 0 ? eff.maxSpeedKmh : nil))
                StatTile(title: L("Charge cycles"),
                         value: chargeCycles.map { units.number($0) } ?? "—",
                         systemImage: "arrow.triangle.2.circlepath", tint: Brand.crimson)
                StatTile(title: L("Total charged"), value: units.energy(kwh: totalChargedKwh, digits: 0))
                if let orig = originalCapacity, let now = currentCapacity, orig > 0 {
                    StatTile(title: L("Capacity loss"), value: units.percent(max(0, (1 - now / orig) * 100), digits: 1))
                }
                StatTile(title: L("Total drives"), value: info?.totalDrives.map(String.init) ?? "\(eff.totalDrives)")
                if let charges = info?.totalCharges {
                    StatTile(title: L("Total charges"), value: "\(charges)")
                }
                if let updates = info?.totalUpdates {
                    StatTile(title: L("SW updates"), value: "\(updates)")
                }
            }
        }
        .card()
    }

    private func statBlock(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(Brand.textTertiary)
            Text(value).font(.title3.weight(.bold)).foregroundStyle(Brand.crimson)
        }
    }

    private func refresh() async {
        refreshing = true
        await env.history.refresh(carID: carID)
        refreshing = false
    }
}

// MARK: - State-of-charge timeline

/// Battery % over the last 7/30 days, reconstructed from drive & charge boundaries.
private struct SocTimelineCard: View {
    let drives: [DriveRecord]
    let charges: [ChargeRecord]
    /// Live battery level, appended as the newest sample when available.
    let liveSoc: Int?
    /// History revision — the series only needs rebuilding when the records actually change.
    let revision: Int

    @State private var days = 7
    @State private var scrubDate: Date?

    /// The reconstructed series. Held in `@State`, not computed: it was being rebuilt from the
    /// whole history three times per body pass — and a chart scrub redraws every frame.
    @State private var samples: [SocSample] = []
    @State private var samplesReady = false

    private struct SampleKey: Equatable {
        var revision: Int
        var days: Int
        var liveSoc: Int?
    }

    private var sampleKey: SampleKey {
        SampleKey(revision: revision, days: days, liveSoc: liveSoc)
    }

    private func rebuildSamples() async {
        let drives = drives
        let charges = charges
        let days = days
        let liveSoc = liveSoc
        let fresh = await Task.detached(priority: .userInitiated) { () -> [SocSample] in
            var s = StatsEngine.socTimeline(drives: drives, charges: charges, days: days)
            if let liveSoc {
                s.append(SocSample(date: Date(), soc: liveSoc, kind: .drive))
            }
            return s
        }.value
        guard !Task.isCancelled else { return }
        samples = fresh
        samplesReady = true
    }

    private var scrubbed: SocSample? {
        guard let scrubDate else { return nil }
        return samples.min {
            abs($0.date.timeIntervalSince(scrubDate)) < abs($1.date.timeIntervalSince(scrubDate))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeader(L("Battery over time"), systemImage: "waveform.path.ecg")
                Picker("", selection: $days) {
                    Text(L("7d")).tag(7)
                    Text(L("30d")).tag(30)
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
            }

            let points = samples
            if !samplesReady {
                BrandLoader(size: .card)
                    .frame(maxWidth: .infinity, minHeight: 170)
            } else if points.count < 2 {
                Text(L("Not enough drive or charge history in this window yet."))
                    .font(.subheadline).foregroundStyle(Brand.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 70)
            } else {
                Chart {
                    ForEach(points) { p in
                        AreaMark(x: .value("Date", p.date), y: .value("SoC", p.soc))
                            .foregroundStyle(LinearGradient(colors: [Brand.online.opacity(0.25), .clear],
                                                             startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", p.date), y: .value("SoC", p.soc))
                            .foregroundStyle(Brand.online)
                            .interpolationMethod(.monotone)
                    }
                    // Mark charge endpoints so charging jumps are recognizable.
                    ForEach(points.filter { $0.kind == .charge }) { p in
                        PointMark(x: .value("Date", p.date), y: .value("SoC", p.soc))
                            .foregroundStyle(Brand.crimson)
                            .symbolSize(14)
                    }
                    if let p = scrubbed {
                        RuleMark(x: .value("Date", p.date))
                            .foregroundStyle(Brand.textTertiary.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        PointMark(x: .value("Date", p.date), y: .value("SoC", p.soc))
                            .foregroundStyle(Brand.textPrimary)
                            .symbolSize(50)
                            .annotation(position: .top,
                                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                Text("\(p.date, format: .dateTime.day().month(.abbreviated).hour().minute().appLanguage) · \(p.soc)%")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Brand.textPrimary)
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Brand.elevatedSurface, in: Capsule())
                            }
                    }
                }
                .chartXSelection(value: $scrubDate)
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) { v in
                    AxisGridLine().foregroundStyle(Brand.hairline)
                    AxisValueLabel { if let s = v.as(Int.self) { Text("\(s)%") } }
                } }
                .chartXAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Brand.hairline); AxisValueLabel(format: days <= 7 ? .dateTime.weekday(.abbreviated).appLanguage : .dateTime.day().month(.narrow).appLanguage) } }
                .frame(height: 170)
                Text(L("Reconstructed from drive and charge boundaries — dots mark charging sessions."))
                    .font(.caption2).foregroundStyle(Brand.textTertiary)
            }
        }
        .card()
        .task(id: sampleKey) { await rebuildSamples() }
    }
}
