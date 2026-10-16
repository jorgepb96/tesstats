import SwiftUI
import Charts

private struct ParkingViewData: Sendable {
    var sessions: [ParkingSession] = []
    var groups: [DailyHistoryGroup<ParkingSession>] = []
}

struct ParkingView: View {
    var area: Binding<TripsArea>?

    init(area: Binding<TripsArea>? = nil) {
        self.area = area
    }

    @Environment(AppEnvironment.self) private var env
    @State private var range = StatsRange(preset: .month)
    @State private var refreshing = false
    @State private var showSettings = false
    @State private var visibleCount = 40
    @State private var view = ParkingViewData()
    @State private var viewReady = false

    private let pageSize = 40

    private var units: Units { Units(config: env.settings.config) }
    private var carID: Int { env.live.resolvedCarID ?? 1 }
    private var sessions: [ParkingSession] { view.sessions }
    private var groups: [DailyHistoryGroup<ParkingSession>] { view.groups }

    private struct ViewKey: Equatable {
        var revision: Int
        var range: StatsRange
        var liveSince: Date?
        var liveBattery: Int?
        var liveRange: Double?
        var liveCoordinate: Coordinate?
        var liveLocation: String?
        var liveIsDriving: Bool
        var liveIsCharging: Bool
        var pricePerKwh: Double
        var efficiencyKwhPerKm: Double?
        var unitsSignature: String
        var visibleCount: Int
    }

    private var viewKey: ViewKey {
        let live = env.live.currentState
        return ViewKey(revision: env.history.revision, range: range,
                liveSince: live?.since, liveBattery: live?.batteryLevel,
                liveRange: live?.range(for: .rated), liveCoordinate: live?.coordinate,
                liveLocation: live?.geofence ?? live?.displayName,
                liveIsDriving: live?.isDriving ?? false,
                liveIsCharging: live?.isCharging ?? false,
                pricePerKwh: env.settings.config.chargePricePerKwh,
                efficiencyKwhPerKm: env.history.carInfo?.efficiencyKwhPerKm,
                unitsSignature: env.settings.config.unitsSignature,
                visibleCount: visibleCount)
    }

    private func rebuild() async {
        let drives = env.history.drives
        let charges = env.history.charges
        let currentState = env.live.currentState
        let price = env.settings.config.chargePricePerKwh
        let efficiency = env.history.carInfo?.efficiencyKwhPerKm
        let capacity = env.history.batteryHealthSummary?.currentCapacityKwh
        let range = range
        let visibleCount = visibleCount
        let units = units
        let fresh = await Task.detached(priority: .userInitiated) {
            let all = ParkingSessionEngine.derive(
                drives: drives, charges: charges, currentState: currentState,
                pricePerKwh: price, efficiencyKwhPerKm: efficiency, usableCapacityKwh: capacity)
            let sessions = all.filter { range.contains($0.startDate) }
            let groups = DailyHistoryGrouper.group(Array(sessions.prefix(visibleCount)), date: \.startDate) { day in
                if Calendar.current.isDateInToday(day) { return L("Today") }
                if Calendar.current.isDateInYesterday(day) { return L("Yesterday") }
                return units.shortDate(day)
            } detail: { bucket in
                let energy = bucket.reduce(0) { $0 + $1.energyLostKwh }
                return L("\(bucket.count) idles · -\(units.number(energy, digits: 1)) kWh")
            }
            return ParkingViewData(sessions: sessions, groups: groups)
        }.value
        guard !Task.isCancelled else { return }
        view = fresh
        viewReady = true
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.background.ignoresSafeArea()
                content
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let area { TripsAreaPicker(selection: area) }
            }
            .navigationTitle(L("Parking"))
            .toolbarTitleDisplayModeInline()
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .leadingBar) { ConnectionStatusMenu() }
                ToolbarItem(placement: .principal) { ToolbarLogo() }
                #endif
                ToolbarItemGroup(placement: .trailingBar) {
                    ArrangeSectionButton(section: .parking, blockType: ParkingBlock.self)
                    RefreshButton(isRefreshing: refreshing) { Task { await refresh() } }
                    #if os(iOS)
                    SettingsGearButton(isPresented: $showSettings)
                    #endif
                }
            }
            .navigationDestination(for: ParkingSession.self) { session in
                ParkingDetailView(session: session, units: units)
            }
            .settingsSheet(isPresented: $showSettings)
        }
        .task(id: carID) { await env.history.loadIfNeeded(carID: carID) }
        .task(id: viewKey) { await rebuild() }
        .onChange(of: range) { _, _ in visibleCount = pageSize }
    }

    @ViewBuilder
    private var content: some View {
        if env.history.hasData {
            loaded.refreshingBadge(env.history.isRefreshing)
        } else {
            switch env.history.phase {
            case .idle, .loading:
                LoadingStateView(label: L("Deriving parking sessions…"))
            case .failed(let message):
                ErrorStateView(message: message) { Task { await refresh() } }
            case .empty(let message):
                EmptyStateView(systemImage: "parkingsign", title: L("No parking history"), message: message)
            case .loaded:
                EmptyStateView(systemImage: "parkingsign", title: L("No parking history"), message: nil)
            }
        }
    }

    private var loaded: some View {
        ScrollView {
            VStack(spacing: Metrics.cardSpacing) {
                ForEach(SectionLayout.visible(ParkingBlock.self, layout: env.settings.config.layout(for: .parking))) { block in
                    if viewReady || block == .filters {
                        blockView(block)
                    } else {
                        LoadingCard(title: block.title, systemImage: block.icon)
                    }
                }
                Color.clear.frame(height: 8)
            }
            .padding(.horizontal, Metrics.screenPadding)
        }
        .refreshable { await refresh() }
        .scrollContentBackground(.hidden)
        .bottomScrollClearance()
    }

    @ViewBuilder
    private func blockView(_ block: ParkingBlock) -> some View {
        switch block {
        case .filters:
            RangeFilterBar(range: $range)
                .padding(.top, 4)
        case .map:
            HistoryMapHeader(
                title: L("Parking"),
                subtitle: L("Last \(range.summaryLabel) · \(sessions.count) idles · \(uniquePlaces) places"),
                metric: energyMetric,
                content: .parking(sessions),
                identifier: "parking"
            )
        case .totals:
            summaryCard
        case .live:
            if let live = sessions.first(where: \.isLive) {
                NavigationLink(value: live) { liveCard(live) }.buttonStyle(.plain)
            }
        case .list:
            LazyVStack(spacing: 10) {
                ForEach(groups) { group in
                    HistoryDayHeader(title: group.title, detail: group.detail)
                    ForEach(group.items) { session in
                        NavigationLink(value: session) {
                            ParkingRow(session: session, units: units)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if sessions.isEmpty {
                    EmptyStateView(systemImage: "parkingsign", title: L("No parking sessions in this period"), message: nil)
                        .frame(height: 260)
                }
                if sessions.count > visibleCount {
                    LoadMoreButton(remaining: sessions.count - visibleCount) {
                        withAnimation { visibleCount += pageSize }
                    }
                }
            }
        }
    }

    private var summaryCard: some View {
        let minutes = sessions.reduce(0) { $0 + $1.durationMinutes }
        let energy = sessions.reduce(0) { $0 + $1.energyLostKwh }
        let cost = sessions.reduce(0) { $0 + $1.cost }
        let rangeLost = sessions.reduce(0) { $0 + $1.rangeLostKm }
        return TileGrid(columns: 4) {
            StatTile(title: L("Time"), value: units.duration(minutes: minutes), systemImage: "clock", tint: Brand.driving)
            StatTile(title: L("Energy"), value: "-\(units.energy(kwh: energy, digits: 1))", systemImage: "bolt.fill", tint: Brand.warning)
            StatTile(title: L("Range"), value: "-\(units.distance(km: rangeLost, digits: 1))", systemImage: "road.lanes")
            StatTile(title: L("Cost"), value: units.money(cost), systemImage: "creditcard")
        }
        .card()
    }

    private func liveCard(_ session: ParkingSession) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Chip(text: L("Live now"), systemImage: "circle.fill", color: Brand.online)
                Text(session.locationName).font(.title3.weight(.bold)).foregroundStyle(Brand.textPrimary)
                Text(session.startBattery.map { "\($0)%" } ?? "—")
                    .font(.subheadline).foregroundStyle(Brand.textSecondary)
            }
            Spacer()
            Text(units.duration(minutes: session.durationMinutes))
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Brand.textPrimary)
            Image(systemName: "chevron.right").foregroundStyle(Brand.textTertiary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.online.opacity(0.16), in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Brand.online.opacity(0.45), lineWidth: 1))
    }

    private var uniquePlaces: Int { Set(sessions.map(\.locationName)).count }
    private var energyMetric: String { "-\(units.number(sessions.reduce(0) { $0 + $1.energyLostKwh }, digits: 1)) kWh" }

    private func refresh() async {
        refreshing = true
        await env.history.refresh(carID: carID)
        refreshing = false
    }
}

struct HistoryDayHeader: View {
    let title: String
    let detail: String

    var body: some View {
        HStack {
            Text(title).font(.title2.weight(.bold)).foregroundStyle(Brand.textPrimary)
            Spacer()
            Text(detail).font(.subheadline.weight(.medium)).foregroundStyle(Brand.textTertiary)
        }
        .padding(.top, 8)
    }
}

private struct ParkingRow: View {
    let session: ParkingSession
    let units: Units

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.locationName)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Brand.textPrimary)
                        .lineLimit(1)
                    Text(timeRange)
                        .font(.subheadline)
                        .foregroundStyle(Brand.textSecondary)
                }
                Spacer()
                Text(units.duration(minutes: session.durationMinutes))
                    .font(.title.weight(.bold))
                    .foregroundStyle(Brand.textPrimary)
                ScoreRing(value: min(1, (session.whPerHour ?? 0) / 250), color: whColor, caption: L("Drain"))
            }
            Divider().overlay(Brand.hairline)
            HStack(spacing: 12) {
                metric("bolt.fill", "-\(units.energy(kwh: session.energyLostKwh, digits: 1))", Brand.warning)
                metric("creditcard", units.money(session.cost), Brand.warning)
                metric("road.lanes", "-\(units.distance(km: session.rangeLostKm, digits: 1))", Brand.textSecondary)
                metric("moon.zzz", whRate, Brand.textSecondary)
            }
        }
        .card()
    }

    private func metric(_ icon: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption).foregroundStyle(color)
            Text(value).font(.caption.weight(.medium)).foregroundStyle(color)
        }
    }

    private var whRate: String {
        session.whPerHour.map { "\(Int($0)) Wh/h" } ?? "—"
    }

    private var whColor: Color {
        guard let wh = session.whPerHour else { return Brand.textTertiary }
        return wh > 180 ? Brand.warning : Brand.driving
    }

    private var timeRange: String {
        let start = units.time(session.startDate)
        guard let end = session.endDate else { return "\(start) → \(L("now"))" }
        return "\(start) → \(units.time(end))"
    }
}

private struct ParkingDetailView: View {
    let session: ParkingSession
    let units: Units

    var body: some View {
        ZStack {
            Brand.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: Metrics.cardSpacing) {
                    header
                    metricGrid
                    chartCard
                    details
                    Color.clear.frame(height: 8)
                }
                .padding(.horizontal, Metrics.screenPadding)
                .padding(.top, 4)
            }
        }
        .navigationTitle(L("Parking"))
        .navigationBarTitleDisplayModeInlineIfAvailable()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline) {
                Text(hoursPart).font(.system(size: 62, weight: .bold, design: .rounded))
                Text(minutesPart).font(.system(size: 38, weight: .bold, design: .rounded)).foregroundStyle(Brand.textSecondary)
                Spacer()
                ScoreRing(value: min(1, (session.whPerHour ?? 0) / 250), color: Brand.driving, caption: L("Drain"))
            }
            Text(session.locationName).font(.title.weight(.bold)).foregroundStyle(Brand.textPrimary)
            Text(dateLine).font(.caption.weight(.semibold)).foregroundStyle(Brand.textTertiary).textCase(.uppercase)
        }
        .card()
    }

    private var metricGrid: some View {
        TileGrid(columns: 3) {
            StatTile(title: L("Energy used"), value: units.energy(kwh: session.energyLostKwh, digits: 1), systemImage: "bolt.fill", tint: Brand.driving)
            StatTile(title: L("Range lost"), value: units.distance(km: session.rangeLostKm, digits: 1), systemImage: "road.lanes", tint: Brand.driving)
            StatTile(title: L("Rate"), value: session.whPerHour.map { "\(Int($0)) Wh/h" } ?? "—", systemImage: "drop.fill", tint: Brand.driving)
            StatTile(title: L("Parked cost"), value: units.money(session.cost), systemImage: "creditcard", tint: Brand.warning)
            StatTile(title: L("Start"), value: session.startBattery.map { "\($0)%" } ?? "—")
            StatTile(title: L("End"), value: session.endBattery.map { "\($0)%" } ?? "—")
        }
        .card()
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeader(L("Battery level"), systemImage: "battery.50percent", accent: Brand.driving)
                FullScreenChartButton(title: L("Battery level")) { batteryChart.frame(height: 320) }
            }
            batteryChart.frame(height: 170)
        }
        .card()
    }

    private var batteryChart: some View {
        let points = chartPoints
        return Chart(points, id: \.0) { p in
            AreaMark(x: .value("Time", p.0), y: .value("Battery", p.1))
                .foregroundStyle(Brand.driving.opacity(0.24))
            LineMark(x: .value("Time", p.0), y: .value("Battery", p.1))
                .foregroundStyle(Brand.driving)
        }
        .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Brand.hairline); AxisValueLabel() } }
    }

    private var details: some View {
        VStack(spacing: 12) {
            SectionHeader(L("Details"), systemImage: "list.bullet")
            KeyValueRow(label: L("Started"), value: units.shortDateTime(session.startDate))
            KeyValueRow(label: L("Ended"), value: session.endDate.map(units.shortDateTime) ?? L("Now"))
            KeyValueRow(label: L("Span"), value: units.duration(minutes: session.durationMinutes))
            if let delta = session.socDelta {
                KeyValueRow(label: L("SoC change"), value: "\(delta)%", valueColor: delta < 0 ? Brand.driving : Brand.textPrimary)
            }
        }
        .card()
    }

    private var chartPoints: [(Date, Double)] {
        let start = Double(session.startBattery ?? session.endBattery ?? 0)
        let end = Double(session.endBattery ?? session.startBattery ?? 0)
        return [(session.startDate, start), (session.endDate ?? Date(), end)]
    }

    private var hoursPart: String { "\(session.durationMinutes / 60)h" }
    private var minutesPart: String { " \(session.durationMinutes % 60)m" }
    private var dateLine: String {
        let start = units.shortDateTime(session.startDate)
        let end = session.endDate.map(units.shortDateTime) ?? L("Now")
        return "\(start) → \(end)"
    }
}
