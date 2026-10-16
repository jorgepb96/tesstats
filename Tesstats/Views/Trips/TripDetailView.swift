import SwiftUI
import MapKit
import Charts
import CoreLocation

struct TripDetailView: View {
    @Environment(AppEnvironment.self) private var env
    let drive: DriveRecord
    let units: Units
    let cost: TripCost?

    /// The drive's real recorded GPS positions (from TeslaMateApi's drive-details endpoint,
    /// or the demo record's own path). The route is drawn straight from these — no geocoding.
    @State private var path: [Coordinate] = []
    @State private var elevation: [Double] = []
    @State private var routeState: RouteState = .loading

    enum RouteState { case loading, ready, unavailable }

    /// Prefer the elevation fetched alongside the trace; fall back to whatever the record carries.
    private var elevationProfile: [Double] { elevation.isEmpty ? drive.elevationProfile : elevation }

    var body: some View {
        ZStack {
            Brand.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: Metrics.cardSpacing) {
                    routeCard
                    tagCard
                    statsCard
                    tripCostCard
                    telemetryCard
                    if elevationProfile.count > 1 { elevationCard }
                    rangeEfficiencyCard
                    Color.clear.frame(height: 8)
                }
                .padding(.horizontal, Metrics.screenPadding)
                .padding(.top, 4)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(L("Trip"))
        .navigationBarTitleDisplayModeInlineIfAvailable()
        .toolbar {
            if let url = ExportService.driveGPXFile(drive) {
                ToolbarItem(placement: .trailingBar) {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                        .tint(Brand.action)
                }
            }
        }
        .task { await loadTrace() }
    }

    // MARK: - Route map

    @ViewBuilder
    private var routeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(drive.originName).font(.headline).foregroundStyle(Brand.textPrimary).lineLimit(1)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(Brand.crimson)
                Text(drive.destinationName).font(.headline).foregroundStyle(Brand.textPrimary).lineLimit(1)
            }
            Text(units.shortDateTime(drive.startDate)).font(.caption).foregroundStyle(Brand.textTertiary)

            switch routeState {
            case .loading:
                ZStack {
                    RoundedRectangle(cornerRadius: Metrics.tightRadius).fill(Brand.elevatedSurface)
                    BrandLoader(size: .card)
                }
                .frame(height: 240)
            case .ready:
                ExpandableMapPreview(title: L("Trip"), identifier: "trip-route") {
                    routeMap
                } expanded: {
                    routeMap
                }
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.tightRadius))
                Text(L("Route drawn from the trip's recorded GPS positions."))
                    .font(.caption2).foregroundStyle(Brand.textTertiary)
            case .unavailable:
                EmptyStateView(systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                               title: L("Map unavailable"),
                               message: L("No recorded GPS positions for this trip."))
                    .frame(height: 130)
            }
        }
        .card()
    }

    @ViewBuilder
    private var routeMap: some View {
        FittingMap(coordinates: path) {
            MapPolyline(coordinates: path.map(\.clLocationCoordinate))
                .stroke(Brand.crimson, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            if let s = path.first {
                Annotation(L("Start"), coordinate: s.clLocationCoordinate) { endpointDot(Brand.online) }
            }
            if let e = path.last {
                Annotation(L("End"), coordinate: e.clLocationCoordinate) { endpointDot(Brand.crimson) }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }

    private func endpointDot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 14, height: 14).overlay(Circle().stroke(.white, lineWidth: 2))
    }

    /// Draw the route from the drive's real recorded GPS positions. Demo records already carry
    /// their own path; live records fetch the per-point trace from TeslaMateApi on demand. No
    /// text geocoding is involved, so an ambiguous city name can never resolve to the wrong place.
    private func loadTrace() async {
        if drive.path.count >= 2 {
            path = MapGeometry.sampled(drive.path, maximumCount: 800)
            elevation = sampledElevations(drive.elevationProfile)
            routeState = .ready
            return
        }
        let carID = env.live.resolvedCarID ?? 1
        if let trace = await env.history.driveTrace(carID: carID, driveID: drive.id), trace.isUsable {
            path = MapGeometry.sampled(trace.path, maximumCount: 800)
            elevation = sampledElevations(trace.elevationProfile)
            routeState = .ready
        } else {
            routeState = .unavailable
        }
    }

    private func sampledElevations(_ values: [Double]) -> [Double] {
        let maximumCount = 600
        guard values.count > maximumCount else { return values }
        let last = values.count - 1
        return (0..<maximumCount).map { values[$0 * last / (maximumCount - 1)] }
    }

    // MARK: - Trip tag (local, device-only)

    private var tagCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(L("Tag"), systemImage: "tag")
            Picker("", selection: Binding(
                get: { env.tripTags.tag(for: drive.id) },
                set: { env.tripTags.setTag($0, for: drive.id) })) {
                Text(L("None")).tag(TripTag?.none)
                ForEach(TripTag.allCases) { tag in
                    Label(tag.label, systemImage: tag.icon).tag(TripTag?.some(tag))
                }
            }
            .pickerStyle(.segmented)
            Text(L("Stored only on this device — useful to separate business mileage. Included in CSV/JSON exports."))
                .font(.caption2).foregroundStyle(Brand.textTertiary)
        }
        .card()
    }

    // MARK: - Stats

    private var energyUsedKwh: Double? {
        // Prefer TeslaMate's recorded net energy; fall back to consumption × distance.
        if let e = drive.energyConsumedKwh, e > 0 { return e }
        guard let c = drive.consumptionWhPerKm, c > 0, drive.distanceKm > 0 else { return nil }
        return c * drive.distanceKm / 1000.0
    }

    /// Start → end SoC, surfacing the usable level in parentheses when it differs.
    private var socLine: String {
        func fmt(_ level: Int?, _ usable: Int?) -> String {
            guard let level else { return "—" }
            if let usable, usable != level { return "\(level)% (\(usable)%)" }
            return "\(level)%"
        }
        return "\(fmt(drive.startBattery, drive.startUsableBattery)) → \(fmt(drive.endBattery, drive.endUsableBattery))"
    }

    private var rangeUsedKm: Double? {
        guard let s = drive.startRangeKm, let e = drive.endRangeKm else { return nil }
        return max(0, s - e)
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(L("Summary"), systemImage: "list.bullet.clipboard")
            TileGrid(columns: 3) {
                StatTile(title: L("Distance"), value: units.distance(km: drive.distanceKm), tint: Brand.crimson)
                StatTile(title: L("Duration"), value: units.duration(minutes: drive.durationMin))
                ConsumptionStat(title: L("Consumption"), whPerKm: drive.consumptionWhPerKm, units: units)
                StatTile(title: L("Avg speed"), value: units.speed(kmh: drive.avgSpeedKmh))
                StatTile(title: L("Max speed"), value: units.speed(kmh: drive.maxSpeedKmh))
                StatTile(title: L("Max power"), value: units.power(kw: drive.maxPowerKw))
                if let regen = drive.maxRegenKw {
                    StatTile(title: L("Max regen"), value: units.power(kw: regen))
                }
                StatTile(title: L("Energy used"), value: units.energy(kwh: energyUsedKwh))
                StatTile(title: L("Range used"), value: units.range(km: rangeUsedKm))
                StatTile(title: L("Elev. gain"), value: elevationGain)
            }
            Divider().overlay(Brand.hairline)
            VStack(spacing: 10) {
                KeyValueRow(label: L("Battery"),
                            value: socLine,
                            systemImage: "battery.50percent")
                KeyValueRow(label: L("Temperature"),
                            value: "\(units.temperature(c: drive.insideTempAvg)) · \(units.temperature(c: drive.outsideTempAvg))",
                            systemImage: "thermometer.medium")
                KeyValueRow(label: L("When"), value: units.shortDateTime(drive.startDate), systemImage: "calendar")
            }
        }
        .card()
    }

    private var tripCostCard: some View {
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(L("Trip cost"), systemImage: "creditcard")
            if let cost {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        KeyValueRow(label: L("Electric"), value: units.money(cost.electricCost), valueColor: Brand.online, systemImage: "bolt.fill")
                        KeyValueRow(label: L("Fuel equivalent"), value: units.money(cost.fuelEquivalentCost), valueColor: Brand.warning, systemImage: "fuelpump")
                        KeyValueRow(label: L("Savings"), value: units.money(max(0, cost.savings)), valueColor: Brand.online, systemImage: "leaf.fill")
                    }
                    Spacer()
                    ScoreRing(value: cost.fuelEquivalentCost > 0 ? min(1, cost.electricCost / cost.fuelEquivalentCost) : 0,
                              color: Brand.online, caption: L("vs petrol"))
                }
                Text(L("Electric cost follows the weighted value of the energy stored by your latest charges, including charging losses when available. Fuel comparison uses your configured values."))
                    .font(.caption2)
                    .foregroundStyle(Brand.textTertiary)
            } else {
                Text(L("No energy data available for this trip."))
                    .font(.subheadline).foregroundStyle(Brand.textSecondary)
            }
        }
        .card()
    }

    private var telemetryCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionHeader(L("Telemetry"), systemImage: "waveform.path.ecg")
                FullScreenChartButton(title: L("Trip telemetry")) {
                    ScrollView {
                        VStack(spacing: 28) {
                            batteryChart.frame(height: 240)
                            energyChart.frame(height: 240)
                            speedChart.frame(height: 240)
                        }
                    }
                }
            }
            Text(L("Battery"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.textTertiary)
            batteryChart.frame(height: 130)
            if !energySeries.isEmpty {
                Text(L("Energy remaining"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.textTertiary)
                energyChart.frame(height: 130)
            }
            Text(L("Avg speed"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.textTertiary)
            speedChart.frame(height: 130)
            Text(L("Charts use session summaries; intermediate telemetry was not returned."))
                .font(.caption2).foregroundStyle(Brand.textTertiary)
        }
        .card()
    }

    private var batteryChart: some View {
        Chart(batterySeries, id: \.0) { point in
            AreaMark(x: .value("Minute", point.0), y: .value("SoC", point.1))
                .foregroundStyle(Brand.driving.opacity(0.24))
            LineMark(x: .value("Minute", point.0), y: .value("SoC", point.1))
                .foregroundStyle(Brand.driving)
        }
        .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Brand.hairline); AxisValueLabel() } }
    }

    private var energyChart: some View {
        Chart(energySeries, id: \.0) { point in
            AreaMark(x: .value("Minute", point.0), y: .value("kWh", point.1))
                .foregroundStyle(Brand.online.opacity(0.22))
            LineMark(x: .value("Minute", point.0), y: .value("kWh", point.1))
                .foregroundStyle(Brand.online)
        }
        .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Brand.hairline); AxisValueLabel() } }
    }

    private var speedChart: some View {
        Chart(speedSeries, id: \.0) { point in
            LineMark(x: .value("Minute", point.0), y: .value("Speed", point.1))
                .foregroundStyle(Brand.warning)
                .interpolationMethod(.catmullRom)
            AreaMark(x: .value("Minute", point.0), y: .value("Speed", point.1))
                .foregroundStyle(Brand.warning.opacity(0.18))
        }
        .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Brand.hairline); AxisValueLabel() } }
    }

    private var rangeEfficiencyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeader(L("Range efficiency"), systemImage: "gauge.with.dots.needle.67percent")
                Spacer()
                Text(rangeEfficiency.map { "\(Int($0 * 100))%" } ?? "—")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Brand.warning)
            }
            Chart(rangeSeries, id: \.0) { point in
                LineMark(x: .value("Minute", point.0), y: .value("Range", point.1))
                    .foregroundStyle(point.2 ? Brand.warning : Brand.textTertiary)
                    .lineStyle(StrokeStyle(lineWidth: point.2 ? 3 : 2, dash: point.2 ? [] : [5]))
            }
            .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Brand.hairline); AxisValueLabel() } }
            .frame(height: 170)
            HStack(spacing: 14) {
                Chip(text: L("Real"), color: Brand.warning)
                Chip(text: L("Ideal"), color: Brand.textTertiary)
            }
        }
        .card()
    }

    private var elevationGain: String {
        let profile = elevationProfile
        guard profile.count > 1 else { return "—" }
        var gain = 0.0
        for i in 1..<profile.count {
            let d = profile[i] - profile[i - 1]
            if d > 0 { gain += d }
        }
        return "\(Int(gain)) m"
    }

    private var elevationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(L("Elevation"), systemImage: "mountain.2")
            Chart(Array(elevationProfile.enumerated()), id: \.offset) { index, value in
                AreaMark(x: .value("Point", index), y: .value("m", value))
                    .foregroundStyle(LinearGradient(colors: [Brand.crimson.opacity(0.4), .clear],
                                                     startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Point", index), y: .value("m", value))
                    .foregroundStyle(Brand.crimson)
                    .interpolationMethod(.catmullRom)
            }
            .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Brand.hairline); AxisValueLabel() } }
            .chartXAxis(.hidden)
            .frame(height: 150)
        }
        .card()
    }

    private var batterySeries: [(Double, Double)] {
        let start = Double(drive.startBattery ?? drive.endBattery ?? 0)
        let end = Double(drive.endBattery ?? drive.startBattery ?? 0)
        return [(0, start), (Double(max(drive.durationMin, 1)), end)]
    }

    private var energySeries: [(Double, Double)] {
        let capacity = env.history.batteryHealthSummary?.currentCapacityKwh
            ?? env.history.battery.last?.usableCapacityKwh
        guard let capacity, capacity.isFinite, capacity > 0,
              let soc = drive.startBattery, (0...100).contains(soc), let used = energyUsedKwh else { return [] }
        let start = Double(soc) / 100 * capacity
        let end = max(0, start - used)
        return [(0, start), (Double(max(drive.durationMin, 1)), end)]
    }

    private var speedSeries: [(Double, Double)] {
        let duration = max(drive.durationMin, 1)
        let avg = drive.avgSpeedKmh ?? (drive.distanceKm / (Double(duration) / 60))
        let value = units.distance == .imperial ? avg / 1.609344 : avg
        return [(0, value), (Double(duration), value)]
    }

    private var rangeSeries: [(Double, Double, Bool)] {
        let duration = Double(max(drive.durationMin, 1))
        let start = drive.startRangeKm ?? 0
        let end = drive.endRangeKm ?? max(0, start - drive.distanceKm)
        let idealEnd = max(0, start - drive.distanceKm)
        let factor = units.distance == .imperial ? 1.609344 : 1
        return [(0, start / factor, true), (duration, end / factor, true),
                (0, start / factor, false), (duration, idealEnd / factor, false)]
    }

    private var rangeEfficiency: Double? {
        guard let used = rangeUsedKm, used > 0, drive.distanceKm > 0 else { return nil }
        return min(1.5, drive.distanceKm / used)
    }
}
