import SwiftUI
import MapKit
import Charts

struct ChargeDetailView: View {
    let charge: ChargeRecord
    let units: Units
    var explicitCarID: Int? = nil
    var promptForPrice = false

    @Environment(AppEnvironment.self) private var env
    @State private var realCurve: [ChargeCurvePoint] = []
    @State private var rawCurveSampleCount = 0
    @State private var selectedSoc: Int?
    @State private var editingPrice = false
    @State private var priceText = ""

    private var carID: Int { explicitCarID ?? env.live.resolvedCarID ?? 1 }
    private var displayCurve: [ChargeCurvePoint] {
        ChargeCurve.displayPoints(from: realCurve, isFast: charge.isFastCharger,
                                  avgPowerKw: charge.avgPowerKw)
    }
    private var hasRealCurve: Bool { displayCurve.count >= 2 }
    /// Real peak power from the per-point curve, when available.
    private var realPeakPoint: ChargeCurvePoint? { displayCurve.max { $0.powerKw < $1.powerKw } }
    private var realPeakKw: Double? { realPeakPoint?.powerKw }

    var body: some View {
        content
            .onAppear {
                if promptForPrice {
                    priceText = env.settings.config.chargePricePerKwhByLocation[charge.locationName]
                        .map { String(format: "%.2f", $0) } ?? ""
                    editingPrice = true
                }
            }
            .alert(L("Price per kWh"), isPresented: $editingPrice) {
                TextField("0.20", text: $priceText).keyboardTypeDecimal()
                Button(L("Save")) { savePrice() }
                Button(L("Use default price"), role: .destructive) { priceText = ""; savePrice() }
                Button(L("Cancel"), role: .cancel) { priceText = "" }
            } message: {
                Text(L("Set the price for \(charge.locationName). It will be reused for future sessions at this location."))
            }
    }

    private var content: some View {
        ZStack {
            Brand.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: Metrics.cardSpacing) {
                    headerCard
                    statsCard
                    if hasRealCurve {
                        realCurveCard
                    } else if !curvePoints.isEmpty {
                        curveCard
                    }
                    if let coord = charge.coord { mapCard(coord) }
                    Color.clear.frame(height: 8)
                }
                .padding(.horizontal, Metrics.screenPadding)
                .padding(.top, 4)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(L("Charge"))
        .navigationBarTitleDisplayModeInlineIfAvailable()
        .task(id: charge.id) { await loadRealCurve() }
    }

    // MARK: - Real curve (per-point kW vs SoC from the charge-detail endpoint)

    private func loadRealCurve() async {
        realCurve = []
        rawCurveSampleCount = 0
        if env.settings.config.demoMode {
            let raw = DemoDataProvider.chargeCurve(for: charge)
            rawCurveSampleCount = raw.count
            withAnimation {
                realCurve = ChargeCurve.displayPoints(from: raw, isFast: charge.isFastCharger,
                                                       avgPowerKw: charge.avgPowerKw)
            }
            return
        }
        let cfg = env.settings.makeAPIConfig()
        guard !cfg.baseURL.isEmpty else { return }
        let api = HistoryAPIService(config: cfg)
        if let points = try? await api.fetchChargeCurve(carID: carID, chargeID: charge.id), points.count >= 2 {
            rawCurveSampleCount = points.count
            let display = ChargeCurve.displayPoints(from: points, isFast: charge.isFastCharger,
                                                    avgPowerKw: charge.avgPowerKw)
            if display.count >= 2 {
                withAnimation { realCurve = display }
            }
        }
    }

    private var socDomain: ClosedRange<Int> {
        let socs = displayCurve.map(\.soc)
        let lo = max(0, (socs.min() ?? 0) - 2)
        let hi = min(100, (socs.max() ?? 100) + 2)
        return lo...hi
    }

    private var powerDomain: ClosedRange<Double> {
        let upper = max(4, ((realPeakKw ?? 0) * 1.18).rounded(.up))
        return 0...upper
    }

    /// Nearest recorded sample to the scrubbed SoC (samples may skip percentages).
    private var scrubbedPoint: ChargeCurvePoint? {
        guard let selectedSoc else { return nil }
        return displayCurve.min { abs($0.soc - selectedSoc) < abs($1.soc - selectedSoc) }
    }

    private var realCurveCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(L("Charge curve"), systemImage: "chart.xyaxis.line")
            Chart {
                ForEach(displayCurve) { p in
                    AreaMark(x: .value("SoC", p.soc), y: .value("kW", p.powerKw))
                        .foregroundStyle(LinearGradient(colors: [Brand.crimson.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("SoC", p.soc), y: .value("kW", p.powerKw))
                        .foregroundStyle(Brand.crimson)
                        .interpolationMethod(.monotone)
                }
                if scrubbedPoint == nil, let peak = realPeakPoint {
                    PointMark(x: .value("SoC", peak.soc), y: .value("kW", peak.powerKw))
                        .foregroundStyle(Brand.crimsonBright)
                        .symbolSize(40)
                        .annotation(position: .top,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            Text(units.power(kw: peak.powerKw, digits: 0))
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Brand.crimsonBright)
                        }
                }
                if let p = scrubbedPoint {
                    RuleMark(x: .value("SoC", p.soc))
                        .foregroundStyle(Brand.textTertiary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    PointMark(x: .value("SoC", p.soc), y: .value("kW", p.powerKw))
                        .foregroundStyle(Brand.crimsonBright)
                        .symbolSize(50)
                        .annotation(position: .top,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            Text("\(p.soc)% · \(units.power(kw: p.powerKw, digits: 0))")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Brand.textPrimary)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Brand.elevatedSurface, in: Capsule())
                        }
                }
            }
            .chartXSelection(value: $selectedSoc)
            .chartXScale(domain: socDomain)
            .chartYScale(domain: powerDomain)
            .chartXAxis { AxisMarks { v in AxisGridLine().foregroundStyle(Brand.hairline); AxisValueLabel { if let s = v.as(Int.self) { Text("\(s)%") } } } }
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine().foregroundStyle(Brand.hairline); AxisValueLabel() } }
            .frame(height: 180)
            Text(L("Real per-point data from TeslaMate · \(rawCurveSampleCount) samples. Touch and drag to inspect."))
                .font(.caption2).foregroundStyle(Brand.textTertiary)
        }
        .card()
    }

    // MARK: - Modeled charge curve (fallback when the detail endpoint isn't available)

    private var curvePoints: [ChargeCurve.Point] {
        ChargeCurve.model(start: charge.startBattery, end: charge.endBattery,
                          isFast: charge.isFastCharger, avgPowerKw: charge.avgPowerKw)
    }

    private var curveCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(L("Charge curve"), systemImage: "chart.xyaxis.line")
            Chart(curvePoints) { p in
                AreaMark(x: .value("SoC", p.soc), y: .value("kW", p.kw))
                    .foregroundStyle(LinearGradient(colors: [Brand.crimson.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("SoC", p.soc), y: .value("kW", p.kw))
                    .foregroundStyle(Brand.crimson)
                    .interpolationMethod(.catmullRom)
            }
            .chartXScale(domain: 0...100)
            .chartXAxis { AxisMarks(values: [0, 25, 50, 75, 100]) { v in AxisGridLine().foregroundStyle(Brand.hairline); AxisValueLabel { if let s = v.as(Int.self) { Text("\(s)%") } } } }
            .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Brand.hairline); AxisValueLabel() } }
            .frame(height: 170)
            Text(L("Typical shape modeled from this session's average power — your server didn't return per-point data."))
                .font(.caption2).foregroundStyle(Brand.textTertiary)
        }
        .card()
    }

    private var headerCard: some View {
        HStack(spacing: 14) {
            Image(systemName: charge.isFastCharger ? "bolt.car.fill" : "house.fill")
                .font(.title)
                .foregroundStyle(Brand.crimson)
            VStack(alignment: .leading, spacing: 4) {
                Text(charge.locationName).font(.title3.weight(.semibold)).foregroundStyle(Brand.textPrimary)
                Text(units.shortDateTime(charge.startDate)).font(.caption).foregroundStyle(Brand.textTertiary)
            }
            Spacer()
            Chip(text: charge.isFastCharger ? L("DC fast") : L("AC / home"),
                 color: charge.isFastCharger ? Brand.crimson : Brand.driving)
        }
        .card()
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(L("Session"), systemImage: "bolt.fill")
            TileGrid(columns: 2) {
                StatTile(title: L("Energy added"), value: units.energy(kwh: charge.energyAddedKwh), tint: Brand.crimson)
                StatTile(title: L("Cost"), value: units.money(pricing.cost(for: charge)))
                StatTile(title: realPeakKw != nil ? L("Peak power") : L("Avg power"),
                         value: units.power(kw: realPeakKw ?? charge.avgPowerKw),
                         tint: realPeakKw != nil ? Brand.crimson : Brand.textPrimary)
                StatTile(title: L("Duration"), value: units.duration(minutes: charge.durationMin))
            }
            Divider().overlay(Brand.hairline)
            KeyValueRow(label: L("State of charge"),
                        value: "\(charge.startBattery.map { "\($0)%" } ?? "—") → \(charge.endBattery.map { "\($0)%" } ?? "—")",
                        valueColor: Brand.crimson, systemImage: "battery.75percent")
            priceControls
        }
        .card()
    }

    /// Where the displayed cost comes from, and a way to set this location's price. A recorded
    /// cost always wins, so the override is explained as applying to this place's uncosted
    /// sessions rather than to the one on screen.
    @ViewBuilder
    private var priceControls: some View {
        Divider().overlay(Brand.hairline)
        VStack(alignment: .leading, spacing: 8) {
            if let recorded = charge.cost, recorded > 0.01 {
                Label(L("Recorded by TeslaMate"), systemImage: "checkmark.seal")
                    .font(.caption).foregroundStyle(Brand.textTertiary)
                Text(L("This session uses the cost TeslaMate recorded. Your price applies to sessions here that have none."))
                    .font(.caption2).foregroundStyle(Brand.textTertiary)
            } else if let plan = env.settings.config.activeTariff, storedPrice == nil {
                Label(L("Tariff plan: \(plan.name.isEmpty ? L("Untitled plan") : plan.name)"), systemImage: "clock")
                    .font(.caption).foregroundStyle(Brand.textTertiary)
            }
            HStack(spacing: 10) {
                Button {
                    priceText = storedPrice.map { String(format: "%.2f", $0) } ?? ""
                    editingPrice = true
                } label: {
                    Label(storedPrice == nil ? L("Set price per kWh") : L("Edit price per kWh"),
                          systemImage: "eurosign.circle")
                        .font(.caption.weight(.semibold))
                }
                .tint(Brand.action)
                if let stored = storedPrice {
                    Text(L("Your price for this location")).font(.caption2).foregroundStyle(Brand.textTertiary)
                    Text(units.money(stored)).font(.caption.weight(.semibold)).foregroundStyle(Brand.warning)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pricing: ChargePricing { ChargePricing(config: env.settings.config) }
    private var storedPrice: Double? { env.settings.config.chargePricePerKwhByLocation[charge.locationName] }

    private func savePrice() {
        if let value = ChargePriceInput.value(from: priceText) {
            env.settings.config.chargePricePerKwhByLocation[charge.locationName] = value
        } else {
            env.settings.config.chargePricePerKwhByLocation.removeValue(forKey: charge.locationName)
        }
        env.settings.save()
        env.enablePushIfNeeded()
        priceText = ""
    }

    private func mapCard(_ coord: Coordinate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(L("Location"), systemImage: "mappin.and.ellipse")
            MiniMap(coordinate: coord)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.tightRadius))
        }
        .card()
    }
}

/// A *modeled* charge-power curve. TeslaMate keeps only session aggregates, so this renders
/// the characteristic taper shape (DC fast tapers with rising SoC; AC stays roughly flat)
/// scaled to the session's average power. Illustrative, clearly labeled as such in the UI.
enum ChargeCurve {
    struct Point: Identifiable, Sendable {
        var id: Double { soc }
        var soc: Double      // %
        var kw: Double
    }

    static func model(start: Int?, end: Int?, isFast: Bool, avgPowerKw: Double?) -> [Point] {
        guard let start, let end, end > start, end - start >= 2 else { return [] }
        let avg = max(1, avgPowerKw ?? (isFast ? 120 : 11))
        // The average of the modeled taper is ~0.7 of peak (DC) / ~0.95 (AC).
        let peak = isFast ? min(260, avg / 0.7) : avg / 0.95
        return stride(from: Double(start), through: Double(end), by: 2).map { soc in
            Point(soc: soc, kw: peak * fraction(of: soc, isFast: isFast))
        }
    }

    /// Condenses TeslaMate's raw detail stream into one representative point per state of
    /// charge. Median aggregation removes repeated labels and brief telemetry spikes while
    /// retaining the real taper of a DC session.
    static func displayPoints(from raw: [ChargeCurvePoint], isFast: Bool,
                              avgPowerKw: Double?) -> [ChargeCurvePoint] {
        let plausibleCeiling = isFast ? 350.0 : max(30, (avgPowerKw ?? 0) * 3)
        let valid = raw.filter {
            (0...100).contains($0.soc) && $0.powerKw.isFinite &&
            $0.powerKw >= 0 && $0.powerKw <= plausibleCeiling
        }
        let grouped = Dictionary(grouping: valid, by: \.soc)
        return grouped.keys.sorted().compactMap { soc in
            guard let group = grouped[soc], !group.isEmpty else { return nil }
            let sorted = group.sorted { $0.powerKw < $1.powerKw }
            let midpoint = sorted.count / 2
            let power = sorted.count.isMultiple(of: 2)
                ? (sorted[midpoint - 1].powerKw + sorted[midpoint].powerKw) / 2
                : sorted[midpoint].powerKw
            let representative = group.min { $0.date < $1.date } ?? sorted[midpoint]
            return ChargeCurvePoint(date: representative.date, soc: soc, powerKw: power,
                                    voltage: representative.voltage, current: representative.current)
        }
    }

    /// Fraction of peak power at a given SoC.
    private static func fraction(of soc: Double, isFast: Bool) -> Double {
        if !isFast {
            return soc < 88 ? 1.0 : max(0.3, 1.0 - (soc - 88) / 12 * 0.7)
        }
        switch soc {
        case ..<20: return 0.6 + soc / 20 * 0.4          // ramp to peak by ~20%
        case ..<55: return 1.0 - (soc - 20) / 35 * 0.18  // gentle hold 1.0 → 0.82
        default:    return max(0.18, 0.82 - (soc - 55) / 45 * 0.64)  // taper to ~18% by 100%
        }
    }
}
