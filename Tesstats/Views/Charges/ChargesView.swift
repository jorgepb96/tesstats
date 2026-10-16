import SwiftUI
import Charts

/// Pre-computed contents of the Charging screen for one combination of filters.
struct ChargesViewData: Sendable {
    var filtered: [ChargeRecord] = []
    var groups: [DailyHistoryGroup<ChargeRecord>] = []
    var aggregates: ChargeAggregates = .init()
    var electricityCost: Double = 0
    var costIsEstimated = false
    var locations: [ChargingLocation] = []
    var fuelComparison: (evCost: Double, fuelCost: Double)?
}

struct ChargesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var search = ""
    @State private var typeFilter: ChargeTypeFilter = .all
    @State private var range = StatsRange()
    @State private var visibleCount = 25
    @State private var refreshing = false
    @State private var showExport = false
    @State private var showSettings = false
    @State private var editingPrice: ChargeRecord?
    @State private var priceText = ""

    private let pageSize = 25
    private var units: Units { Units(config: env.settings.config) }
    private var carID: Int { env.live.resolvedCarID ?? 1 }

    /// Filtering, grouping and cost aggregation ran on every redraw and were read a dozen
    /// times per body pass. Computed once per real change, off the main actor, and held here.
    @State private var view = ChargesViewData()
    @State private var viewReady = false

    private var filtered: [ChargeRecord] { view.filtered }
    private var groups: [DailyHistoryGroup<ChargeRecord>] { view.groups }

    private struct ViewKey: Equatable {
        var revision: Int
        var search: String
        var range: StatsRange
        var typeFilter: ChargeTypeFilter
        var visibleCount: Int
        var pricing: ChargePricing
        var unitsSignature: String
        var efficiencyWhPerKm: Double
        var fuelPricePerLiter: Double
        var fuelConsumptionLPer100km: Double
    }

    private var viewKey: ViewKey {
        ViewKey(revision: env.history.revision,
                search: search,
                range: range,
                typeFilter: typeFilter,
                visibleCount: visibleCount,
                pricing: ChargePricing(config: env.settings.config),
                unitsSignature: env.settings.config.unitsSignature,
                efficiencyWhPerKm: env.history.efficiency.avgWhPerKm,
                fuelPricePerLiter: env.settings.config.fuelPricePerLiter,
                fuelConsumptionLPer100km: env.settings.config.fuelConsumptionLPer100km)
    }

    /// Filtering, grouping and per-location cost aggregation over a multi-year history is far
    /// too much work for the main actor, which is also servicing the live MQTT feed. It runs on
    /// a background task and lands in one assignment.
    private func rebuild() async {
        let pricing = ChargePricing(config: env.settings.config)
        let units = units
        let charges = env.history.charges
        let search = search
        let range = range
        let typeFilter = typeFilter
        let visibleCount = visibleCount
        let avgWhPerKm = env.history.efficiency.avgWhPerKm
        let fuelConsumption = env.settings.config.fuelConsumptionLPer100km
        let fuelPrice = env.settings.config.fuelPricePerLiter

        let fresh = await Task.detached(priority: .userInitiated) {
            let filtered = charges.filter { c in
                typeFilter.matches(c) && range.contains(c.startDate) &&
                (search.isEmpty || c.locationName.localizedCaseInsensitiveContains(search))
            }
            let groups = DailyHistoryGrouper.group(Array(filtered.prefix(visibleCount)), date: \.startDate) { day in
                if Calendar.current.isDateInToday(day) { return L("Today") }
                if Calendar.current.isDateInYesterday(day) { return L("Yesterday") }
                return units.shortDate(day)
            } detail: { bucket in
                let energy = bucket.reduce(0) { $0 + $1.energyAddedKwh }
                let cost = bucket.reduce(0) { $0 + pricing.cost(for: $1) }
                return L("\(bucket.count) sessions · +\(units.number(energy, digits: 1)) kWh · \(units.money(cost))")
            }
            let aggregates = ChargeAggregates.from(filtered)
            let resolutions = filtered.map { pricing.resolution(for: $0) }
            let electricityCost = resolutions.reduce(0) { $0 + $1.cost }
            let costIsEstimated = resolutions.contains { $0.isEstimated }

            // What the same kWh would have cost as petrol, using the fleet's real efficiency.
            var fuelComparison: (evCost: Double, fuelCost: Double)?
            if avgWhPerKm > 0, aggregates.totalEnergyKwh > 0 {
                let km = (aggregates.totalEnergyKwh * 1000) / avgWhPerKm
                let liters = km / 100 * fuelConsumption
                fuelComparison = (electricityCost, liters * fuelPrice)
            }

            return ChargesViewData(filtered: filtered, groups: groups, aggregates: aggregates,
                                   electricityCost: electricityCost,
                                   costIsEstimated: costIsEstimated,
                                   locations: StatsEngine.chargingLocations(filtered, pricing: pricing),
                                   fuelComparison: fuelComparison)
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
            .navigationTitle(L("Charging"))
            .toolbarTitleDisplayModeInline()
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .leadingBar) { ConnectionStatusMenu() }
                ToolbarItem(placement: .principal) { ToolbarLogo() }
                #endif
                ToolbarItemGroup(placement: .trailingBar) {
                    if !filtered.isEmpty {
                        Button { showExport = true } label: { Image(systemName: "square.and.arrow.up") }
                            .tint(Brand.action)
                    }
                    ArrangeSectionButton(section: .charging, blockType: ChargingBlock.self)
                    RefreshButton(isRefreshing: refreshing) { Task { await refresh() } }
                    #if os(iOS)
                    SettingsGearButton(isPresented: $showSettings)
                    #endif
                }
            }
            .navigationDestination(for: ChargeRecord.self) { charge in
                ChargeDetailView(charge: charge, units: units)
            }
            .sheet(isPresented: $showExport) {
                ExportSheet(drives: [], charges: filtered)
            }
            .settingsSheet(isPresented: $showSettings)
            .alert(L("Price per kWh"), isPresented: editingBinding, presenting: editingPrice) { charge in
                TextField("0.20", text: $priceText)
                    .keyboardTypeDecimal()
                Button(L("Save")) { savePrice(for: charge) }
                Button(L("Cancel"), role: .cancel) {}
            } message: { charge in
                Text(L("Set the price for \(charge.locationName). It will be reused for future sessions at this location."))
            }
        }
        .task(id: carID) { await env.history.loadIfNeeded(carID: carID) }
        .task(id: viewKey) { await rebuild() }
        .onChange(of: search) { _, _ in visibleCount = pageSize }
        .onChange(of: typeFilter) { _, _ in visibleCount = pageSize }
        .onChange(of: range) { _, _ in visibleCount = pageSize }
    }

    /// Sessions already downloaded stay on screen and stay scrollable; a load still in flight
    /// only adds a badge on top.
    @ViewBuilder
    private var content: some View {
        if !env.history.charges.isEmpty {
            // The filter bar is one of the reorderable blocks inside `list`; it used to be
            // drawn here as well, so the screen carried two identical copies of it.
            list.refreshingBadge(env.history.isRefreshing)
        } else {
            switch env.history.phase {
            case .idle, .loading:
                LoadingStateView(label: L("Loading charges…"))
            case .failed(let message):
                ErrorStateView(message: message) { Task { await refresh() } }
            case .empty(let message):
                EmptyStateView(systemImage: "bolt.slash", title: L("No charges"), message: message)
            case .loaded:
                EmptyStateView(systemImage: "bolt.slash", title: L("No charging sessions yet"), message: nil)
            }
        }
    }

    private var filterBar: some View {
        VStack(spacing: 10) {
            SearchField(placeholder: L("Search location"), text: $search)
            SegmentedFilter(selection: $typeFilter)
            RangeFilterBar(range: $range)
        }
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.top, 6)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: Metrics.cardSpacing) {
                ForEach(SectionLayout.visible(ChargingBlock.self, layout: env.settings.config.layout(for: .charging))) { block in
                    // Each block shows the loader in its own centre until its data is ready.
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
    private func blockView(_ block: ChargingBlock) -> some View {
        switch block {
        case .filters:
            filterBar
        case .monthlyCost:
            ChargingCostHistoryCard()
        case .map:
            HistoryMapHeader(
                title: L("Charging"),
                subtitle: "\(range.summaryLabel) · \(filtered.count) \(L("sessions"))",
                metric: "+\(units.number(view.aggregates.totalEnergyKwh)) kWh",
                content: .charges(filtered),
                identifier: "charging"
            )
        case .places:
            quickLinks
        case .totals:
            ChargeAggregatesCard(aggregates: view.aggregates,
                                 electricityCost: electricityCost,
                                 costIsEstimated: costIsEstimated,
                                 fuelComparison: fuelComparison, units: units)
        case .list:
            LazyVStack(spacing: 10) {
                ForEach(groups) { group in
                    HistoryDayHeader(title: group.title, detail: group.detail)
                    ForEach(group.items) { charge in
                        NavigationLink(value: charge) {
                            ChargeRow(charge: charge, units: units, effectiveCost: effectiveCost(charge)) {
                                beginEditing(charge)
                            }
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
                    Text(L("No charges match your filters."))
                        .font(.subheadline).foregroundStyle(Brand.textSecondary).padding(.top, 30)
                }
            }
        }
    }

    private var quickLinks: some View {
        NavigationLink {
            ChargingLocationsModuleView(locations: chargingLocations, units: units)
        } label: {
            Label(L("Costs & places"), systemImage: "eurosign")
                .frame(maxWidth: .infinity)
        }
        .glassButtonStyle()
    }

    private var electricityCost: Double { view.electricityCost }
    private var chargingLocations: [ChargingLocation] { view.locations }
    private var costIsEstimated: Bool { view.costIsEstimated }
    private var fuelComparison: (evCost: Double, fuelCost: Double)? { view.fuelComparison }

    /// Effective cost of one session — recorded where present, otherwise the location's custom
    /// price, the time-of-use tariff, or the global default.
    private func effectiveCost(_ charge: ChargeRecord) -> Double {
        ChargePricing(config: env.settings.config).cost(for: charge)
    }

    private func refresh() async {
        refreshing = true
        await env.history.refresh(carID: carID)
        refreshing = false
    }

    private var editingBinding: Binding<Bool> {
        Binding(get: { editingPrice != nil }, set: { if !$0 { editingPrice = nil } })
    }

    private func beginEditing(_ charge: ChargeRecord) {
        editingPrice = charge
        priceText = env.settings.config.chargePricePerKwhByLocation[charge.locationName].map { String(format: "%g", $0) } ?? ""
    }

    private func savePrice(for charge: ChargeRecord) {
        if let value = ChargePriceInput.value(from: priceText) {
            env.settings.config.chargePricePerKwhByLocation[charge.locationName] = value
            env.settings.save()
        }
        editingPrice = nil
    }
}

struct ChargeAggregatesCard: View {
    let aggregates: ChargeAggregates
    var electricityCost: Double = 0
    var costIsEstimated: Bool = false
    let fuelComparison: (evCost: Double, fuelCost: Double)?
    let units: Units

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(L("Totals"), systemImage: "sum")
            TileGrid(columns: 2) {
                StatTile(title: L("Energy"), value: units.energy(kwh: aggregates.totalEnergyKwh, digits: 0), systemImage: "bolt.fill", tint: Brand.crimson)
                StatTile(title: costIsEstimated ? L("Cost (est.)") : L("Cost"),
                         value: units.money(electricityCost), systemImage: "creditcard")
                StatTile(title: L("Sessions"), value: "\(aggregates.sessionCount)", systemImage: "number")
                if let eff = aggregates.chargingEfficiency {
                    StatTile(title: L("Charging efficiency"), value: units.percent(eff * 100),
                             systemImage: "bolt.badge.checkmark", tint: Brand.online)
                }
                if let loss = aggregates.lossKwh {
                    StatTile(title: L("Charging losses"), value: units.energy(kwh: loss, digits: 1),
                             systemImage: "arrow.down.right")
                }
            }
            if aggregates.homeEnergyKwh + aggregates.publicEnergyKwh > 0 {
                Divider().overlay(Brand.hairline)
                ChargeTypeDonut(aggregates: aggregates, units: units)
            }
            if let cmp = fuelComparison {
                Divider().overlay(Brand.hairline)
                let saved = cmp.fuelCost - cmp.evCost
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(L("Electricity"), systemImage: "bolt").font(.caption).foregroundStyle(Brand.textSecondary)
                        Spacer()
                        Text(units.money(cmp.evCost)).font(.caption.weight(.medium)).foregroundStyle(Brand.textPrimary)
                    }
                    HStack {
                        Label(L("Equivalent petrol"), systemImage: "fuelpump").font(.caption).foregroundStyle(Brand.textSecondary)
                        Spacer()
                        Text(units.money(cmp.fuelCost)).font(.caption.weight(.medium)).foregroundStyle(Brand.textPrimary)
                    }
                    HStack {
                        Text(saved >= 0 ? L("You saved") : L("Extra cost"))
                            .font(.caption.weight(.semibold)).foregroundStyle(saved >= 0 ? Brand.online : Brand.warning)
                        Spacer()
                        Text(units.money(abs(saved)))
                            .font(.caption.weight(.bold)).foregroundStyle(saved >= 0 ? Brand.online : Brand.warning)
                    }
                }
            }
        }
        .card()
    }
}

private struct ChargeTypeDonut: View {
    let aggregates: ChargeAggregates
    let units: Units

    private struct Slice: Identifiable {
        let id: String
        let energy: Double
        let color: Color
    }

    private var total: Double { aggregates.homeEnergyKwh + aggregates.publicEnergyKwh }
    private var slices: [Slice] {
        [
            Slice(id: "AC", energy: aggregates.homeEnergyKwh, color: Brand.action),
            Slice(id: "DC", energy: aggregates.publicEnergyKwh, color: Brand.warning)
        ].filter { $0.energy > 0 }
    }

    var body: some View {
        HStack(spacing: 20) {
            Chart(slices) { slice in
                SectorMark(
                    angle: .value("Energy", slice.energy),
                    innerRadius: .ratio(0.62),
                    angularInset: 2
                )
                .cornerRadius(4)
                .foregroundStyle(slice.color)
            }
            .chartLegend(.hidden)
            .frame(width: 132, height: 132)
            .overlay {
                VStack(spacing: 1) {
                    Text(L("AC / DC"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Brand.textTertiary)
                    Text(units.energy(kwh: total, digits: 0))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Brand.textPrimary)
                        .minimumScaleFactor(0.7)
                }
            }

            VStack(spacing: 14) {
                splitRow("AC", energy: aggregates.homeEnergyKwh, color: Brand.action)
                splitRow("DC", energy: aggregates.publicEnergyKwh, color: Brand.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(L("AC / DC")): AC \(units.energy(kwh: aggregates.homeEnergyKwh)), DC \(units.energy(kwh: aggregates.publicEnergyKwh))")
        .accessibilityIdentifier("charging-ac-dc-chart")
    }

    private func splitRow(_ label: String, energy: Double, color: Color) -> some View {
        HStack(spacing: 9) {
            Circle().fill(color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.textPrimary)
                Text(units.percent(total > 0 ? energy / total * 100 : 0, digits: 0))
                    .font(.caption2)
                    .foregroundStyle(Brand.textTertiary)
            }
            Spacer(minLength: 8)
            Text(units.energy(kwh: energy, digits: 1))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.textSecondary)
        }
    }
}

struct ChargeRow: View {
    let charge: ChargeRecord
    let units: Units
    let effectiveCost: Double
    var addPrice: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: charge.isFastCharger ? "bolt.car" : "house")
                    .font(.subheadline).foregroundStyle(Brand.crimson)
                Text(charge.locationName).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.textPrimary).lineLimit(1)
                Spacer()
                Text(units.relative(charge.startDate)).font(.caption2).foregroundStyle(Brand.textTertiary)
            }
            HStack(spacing: 10) {
                Text("+\(units.energy(kwh: charge.energyAddedKwh))")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(charge.isFastCharger ? Brand.crimson : Brand.online)
                Spacer()
                Text(timeRange)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Brand.textSecondary)
            }
            ProgressView(value: Double(charge.endBattery ?? 0), total: 100)
                .tint(Brand.online)
            HStack(spacing: 14) {
                metric("battery.50percent", "\(charge.startBattery.map { "\($0)" } ?? "—")→\(charge.endBattery.map { "\($0)%" } ?? "—")")
                metric("clock", units.duration(minutes: charge.durationMin))
                metric("creditcard", units.money(effectiveCost))
                Spacer()
                if charge.isFastCharger { Chip(text: "DC", color: Brand.crimson) }
                if charge.cost == nil {
                    Button {
                        addPrice()
                    } label: {
                        Label(L("Add price"), systemImage: "plus")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Brand.driving)
                }
            }
        }
        .card(padding: 14)
    }

    private var timeRange: String {
        let start = units.time(charge.startDate)
        guard let end = charge.endDate else { return start }
        return "\(start) → \(units.time(end))"
    }

    private func metric(_ icon: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2).foregroundStyle(Brand.textTertiary)
            Text(value).font(.caption).foregroundStyle(Brand.textSecondary)
        }
    }
}

private struct ChargingLocationsModuleView: View {
    let locations: [ChargingLocation]
    let units: Units

    var body: some View {
        ZStack {
            Brand.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(locations) { loc in
                        HStack {
                            Image(systemName: loc.isFast ? "bolt.car.fill" : "house.fill")
                                .foregroundStyle(Brand.crimson)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(loc.name).font(.headline).foregroundStyle(Brand.textPrimary)
                                Text(L("\(loc.sessions) sessions · \(units.energy(kwh: loc.energyKwh, digits: 0))"))
                                    .font(.caption).foregroundStyle(Brand.textTertiary)
                            }
                            Spacer()
                            Text(loc.cost > 0 ? units.money(loc.cost) : units.power(kw: loc.avgPowerKw > 0 ? loc.avgPowerKw : nil))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Brand.textSecondary)
                        }
                        .card()
                    }
                    if locations.isEmpty {
                        EmptyStateView(systemImage: "mappin.circle", title: L("No charging places"), message: nil)
                    }
                }
                .padding()
            }
        }
        .navigationTitle(L("Costs & places"))
        .navigationBarTitleDisplayModeInlineIfAvailable()
    }
}
