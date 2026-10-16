import SwiftUI

enum TripsArea: String, CaseIterable, Identifiable {
    case trips
    case parking

    var id: String { rawValue }
    var title: String { self == .trips ? L("Trips") : L("Parking") }
    var icon: String { self == .trips ? "map" : "parkingsign" }
}

/// Trips and the idle periods between them form one journey history. Keeping both here makes
/// Parking discoverable without spending a top-level tab or duplicating it in a More screen.
struct TripsView: View {
    #if os(iOS)
    @State private var area: TripsArea = .trips
    #endif

    var body: some View {
        #if os(iOS)
        switch area {
        case .trips:
            TripHistoryView(area: $area)
        case .parking:
            ParkingView(area: $area)
        }
        #else
        TripHistoryView()
        #endif
    }
}

struct TripsAreaPicker: View {
    @Binding var selection: TripsArea

    var body: some View {
        Picker(L("Journey history"), selection: $selection) {
            ForEach(TripsArea.allCases) { area in
                Label(area.title, systemImage: area.icon).tag(area)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityIdentifier("trips-area-picker")
    }
}

/// Pre-computed contents of the Trips screen for one combination of filters.
struct TripsViewData: Sendable {
    var filtered: [DriveRecord] = []
    var groups: [DailyHistoryGroup<DriveRecord>] = []
    var distanceKm: Double = 0
    var energyKwh: Double = 0
    var efficiencyWhPerKm: Double?
    var costsByDriveID: [Int: TripCost] = [:]
}

struct TripHistoryView: View {
    var area: Binding<TripsArea>?

    init(area: Binding<TripsArea>? = nil) {
        self.area = area
    }

    @Environment(AppEnvironment.self) private var env
    @State private var search = ""
    @State private var range = StatsRange()
    @State private var tagFilter: TripTagFilter = .all
    @State private var visibleCount = 25
    @State private var refreshing = false
    @State private var showExport = false
    @State private var showSettings = false

    private let pageSize = 25
    private var units: Units { Units(config: env.settings.config) }
    private var carID: Int { env.live.resolvedCarID ?? 1 }

    /// Filtering + day grouping ran on every redraw and were read a dozen times per body pass.
    /// Computed once per real change, off the main actor, and held here.
    @State private var view = TripsViewData()
    @State private var viewReady = false

    private var filtered: [DriveRecord] { view.filtered }
    private var groups: [DailyHistoryGroup<DriveRecord>] { view.groups }

    private struct ViewKey: Equatable {
        var revision: Int
        var tagRevision: Int
        var search: String
        var range: StatsRange
        var tagFilter: TripTagFilter
        var visibleCount: Int
        var unitsSignature: String
        var pricingSignature: String
    }

    private var viewKey: ViewKey {
        ViewKey(revision: env.history.revision,
                tagRevision: env.tripTags.revision,
                search: search,
                range: range,
                tagFilter: tagFilter,
                visibleCount: visibleCount,
                unitsSignature: env.settings.config.unitsSignature,
                pricingSignature: env.settings.config.tripPricingSignature)
    }

    /// Filtering and grouping a multi-year history is tens of milliseconds of work that used to
    /// land on the main actor while the live MQTT feed was already redrawing the screen. It now
    /// runs on a background task and lands in one assignment.
    private func rebuild() async {
        let units = units
        let drives = env.history.drives
        let tags = env.tripTags.tags
        let search = search
        let range = range
        let tagFilter = tagFilter
        let visibleCount = visibleCount
        let charges = env.history.charges
        let pricing = ChargePricing(config: env.settings.config)
        let fuelPrice = env.settings.config.fuelPricePerLiter
        let fuelConsumption = env.settings.config.fuelConsumptionLPer100km
        let usableCapacity = env.history.battery.last?.usableCapacityKwh
        let fresh = await Task.detached(priority: .userInitiated) {
            let filtered = drives.filter { d in
                range.contains(d.startDate) &&
                tagFilter.matches(tags[d.id]) &&
                (search.isEmpty
                    || d.originName.localizedCaseInsensitiveContains(search)
                    || d.destinationName.localizedCaseInsensitiveContains(search))
            }
            let groups = DailyHistoryGrouper.group(Array(filtered.prefix(visibleCount)), date: \.startDate) { day in
                if Calendar.current.isDateInToday(day) { return L("Today") }
                if Calendar.current.isDateInYesterday(day) { return L("Yesterday") }
                return units.shortDate(day)
            } detail: { bucket in
                L("\(bucket.count) drives · \(units.distance(km: bucket.reduce(0) { $0 + $1.distanceKm }, digits: 1))")
            }
            let distance = filtered.reduce(0) { $0 + $1.distanceKm }
            let energy = filtered.reduce(0) { $0 + TripCostEngine.energyKwh(for: $1) }
            let costs = TripEnergyCostLedger.costs(
                drives: drives,
                charges: charges,
                pricing: pricing,
                fuelPricePerLiter: fuelPrice,
                fuelConsumptionLPer100km: fuelConsumption,
                usableCapacityKwh: usableCapacity
            )
            return TripsViewData(filtered: filtered, groups: groups,
                                 distanceKm: distance, energyKwh: energy,
                                 efficiencyWhPerKm: TripCostEngine.averageConsumptionWhPerKm(for: filtered),
                                 costsByDriveID: costs)
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
            .navigationTitle(L("Trips"))
            .toolbarTitleDisplayModeInline()
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .leadingBar) { ConnectionStatusMenu() }
                ToolbarItem(placement: .principal) { ToolbarLogo() }
                #endif
                ToolbarItemGroup(placement: .trailingBar) {
                    if env.history.usingCache {
                        Chip(text: L("Cached"), systemImage: "internaldrive", color: Brand.asleep)
                    }
                    if !filtered.isEmpty {
                        Button { showExport = true } label: { Image(systemName: "square.and.arrow.up") }
                            .tint(Brand.action)
                    }
                    ArrangeSectionButton(section: .trips, blockType: TripsBlock.self)
                    RefreshButton(isRefreshing: refreshing) { Task { await refresh() } }
                    #if os(iOS)
                    SettingsGearButton(isPresented: $showSettings)
                    #endif
                }
            }
            .navigationDestination(for: DriveRecord.self) { drive in
                TripDetailView(drive: drive, units: units, cost: view.costsByDriveID[drive.id])
            }
            .sheet(isPresented: $showExport) {
                ExportSheet(drives: filtered, charges: [])
            }
            .settingsSheet(isPresented: $showSettings)
        }
        .task(id: carID) { await env.history.loadIfNeeded(carID: carID) }
        .task(id: viewKey) { await rebuild() }
        .onChange(of: search) { _, _ in visibleCount = pageSize }
        .onChange(of: range) { _, _ in visibleCount = pageSize }
        .onChange(of: tagFilter) { _, _ in visibleCount = pageSize }
    }

    /// Whatever is already downloaded stays on screen and stays scrollable; a load still in
    /// flight only adds a badge on top.
    @ViewBuilder
    private var content: some View {
        if !env.history.drives.isEmpty {
            list.refreshingBadge(env.history.isRefreshing)
        } else {
            switch env.history.phase {
            case .idle, .loading:
                LoadingStateView(label: L("Loading trips…"))
            case .failed(let message):
                ErrorStateView(message: message) { Task { await refresh() } }
            case .empty(let message):
                EmptyStateView(systemImage: "map", title: L("No trips"), message: message)
            case .loaded:
                EmptyStateView(systemImage: "map", title: L("No drives recorded yet"), message: nil)
            }
        }
    }

    private var filterBar: some View {
        VStack(spacing: 10) {
            SearchField(placeholder: L("Search origin or destination"), text: $search)
            SegmentedFilter(selection: $tagFilter)
            RangeFilterBar(range: $range)
            HStack {
                Text(L("\(filtered.count) trips · \(units.distance(km: filtered.reduce(0) { $0 + $1.distanceKm }, digits: 0))"))
                    .font(.caption).foregroundStyle(Brand.textTertiary)
                Spacer()
            }
        }
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.top, 6)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: Metrics.cardSpacing) {
                ForEach(SectionLayout.visible(TripsBlock.self, layout: env.settings.config.layout(for: .trips))) { block in
                    // The filter bar must stay usable while the list is being rebuilt; every
                    // other block shows the loader in its own centre until its data is ready.
                    if viewReady || block == .filters {
                        blockView(block)
                    } else {
                        LoadingCard(title: block.title, systemImage: block.icon)
                    }
                }
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.bottom, 8)
        }
        .scrollContentBackground(.hidden)
        .bottomScrollClearance()
        .refreshable { await refresh() }
    }

    @ViewBuilder
    private func blockView(_ block: TripsBlock) -> some View {
        switch block {
        case .filters:
            filterBar
        case .map:
            HistoryMapHeader(
                title: L("Trips"),
                subtitle: "\(range.summaryLabel) · \(filtered.count) \(L("drives"))",
                metric: units.distance(km: view.distanceKm, digits: 0),
                content: .drives(filtered),
                identifier: "trips"
            )
        case .totals:
            tripSummaryCard
        case .list:
            LazyVStack(spacing: 10) {
                ForEach(groups) { group in
                    HistoryDayHeader(title: group.title, detail: group.detail)
                    ForEach(group.items) { drive in
                        NavigationLink(value: drive) {
                            DriveRow(drive: drive, units: units, cost: tripCost(drive),
                                     tag: env.tripTags.tag(for: drive.id))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if filtered.count > visibleCount {
                    LoadMoreButton(remaining: filtered.count - visibleCount) {
                        withAnimation { visibleCount += pageSize }
                    }
                }
                if filtered.isEmpty {
                    Text(L("No trips match your filters."))
                        .font(.subheadline).foregroundStyle(Brand.textSecondary)
                        .padding(.top, 40)
                }
            }
        }
    }

    private func refresh() async {
        refreshing = true
        await env.history.refresh(carID: carID)
        refreshing = false
    }

    private var tripSummaryCard: some View {
        TileGrid(columns: 2) {
            StatTile(title: L("Energy"), value: units.energy(kwh: view.energyKwh, digits: 1), systemImage: "bolt.fill", tint: Brand.online)
            UnitStatTile(title: L("Efficiency"), value: units.consumption(whPerKm: view.efficiencyWhPerKm),
                         systemImage: "leaf.fill", tint: Brand.driving) { UnitToggle.consumption(env) }
            StatTile(title: L("Trips"), value: "\(filtered.count)", systemImage: "road.lanes")
            StatTile(title: L("Distance"), value: units.distance(km: view.distanceKm, digits: 0), systemImage: "map")
            StatTile(title: L("Avg / trip"), value: units.distance(km: averageTripKm, digits: 1), systemImage: "arrow.left.and.right")
            StatTile(title: L("Odometer"), value: units.distance(km: env.live.currentState?.odometer, digits: 0), systemImage: "gauge.with.dots.needle.50percent", tint: Brand.action)
        }
        .card()
    }

    private var averageTripKm: Double? {
        guard !filtered.isEmpty else { return nil }
        return view.distanceKm / Double(filtered.count)
    }

    private func tripCost(_ drive: DriveRecord) -> TripCost? {
        view.costsByDriveID[drive.id]
    }
}

struct DriveRow: View {
    let drive: DriveRecord
    let units: Units
    var cost: TripCost?
    var tag: TripTag?
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(drive.originName, systemImage: "circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.online)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Label(drive.destinationName, systemImage: "circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Brand.danger)
                            .lineLimit(1)
                        if let tag {
                            Chip(text: tag.label, systemImage: tag.icon, color: Brand.driving)
                        }
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(units.distance(km: drive.distanceKm))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Brand.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(timeRange)
                        .font(.caption)
                        .foregroundStyle(Brand.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            // One line, never wrapping: these used to fight the score ring and the route
            // preview for width, which broke "€0.23" across two rows.
            HStack(spacing: 14) {
                metric("clock", units.duration(minutes: drive.durationMin), Brand.textSecondary)
                Button {
                    withAnimation(.snappy) { UnitToggle.consumption(env) }
                } label: {
                    metric("leaf.fill", units.consumption(whPerKm: drive.consumptionWhPerKm),
                           Brand.driving, swappable: true)
                }
                .buttonStyle(.plain)
                if let cost {
                    metric("creditcard", units.money(cost.electricCost), Brand.warning)
                }
                Spacer(minLength: 4)
                if drive.path.count >= 2 {
                    ScoreRing(value: driveScore, color: Brand.driving,
                              caption: L("Efficiency"), diameter: 44)
                }
            }
        }
        // The route sketch moved behind the content: as a sibling column it took 95 pt that
        // the metrics needed, and it reads fine as a watermark.
        .background(alignment: .trailing) {
            if drive.path.count >= 2 {
                TinyRoutePreview(path: drive.path)
                    .frame(width: 120)
                    .opacity(0.28)
                    .allowsHitTesting(false)
            }
        }
        .card(padding: 14)
    }

    private var driveScore: Double {
        guard let wh = drive.consumptionWhPerKm else { return 0.75 }
        return max(0.2, min(1, 1 - max(0, wh - 120) / 180))
    }

    private var timeRange: String {
        let start = units.time(drive.startDate)
        guard let end = drive.endDate else { return start }
        return "\(start) → \(units.time(end))"
    }

    private func metric(_ icon: String, _ value: String, _ color: Color, swappable: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2).foregroundStyle(color)
            Text(value)
                .font(.caption)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .contentTransition(.numericText())
            if swappable { UnitSwapHint() }
        }
    }
}

/// Trip-list filter over the local tags: everything, one tag, or only untagged drives.
enum TripTagFilter: String, FilterOption, Sendable {
    case all, work, personal, untagged

    var id: String { rawValue }
    var filterLabel: String {
        switch self {
        case .all: L("All")
        case .work: L("Work")
        case .personal: L("Personal")
        case .untagged: L("Untagged")
        }
    }

    func matches(_ tag: TripTag?) -> Bool {
        switch self {
        case .all: true
        case .work: tag == .work
        case .personal: tag == .personal
        case .untagged: tag == nil
        }
    }
}
