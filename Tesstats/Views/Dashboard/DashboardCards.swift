import SwiftUI
import MapKit

// MARK: - Layout helper

struct TileGrid<Content: View>: View {
    var columns: Int = 3
    @ViewBuilder var content: Content
    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .leading), count: columns),
            alignment: .leading, spacing: 16) {
            content
        }
    }
}

// MARK: - Header

struct HeaderSummaryCard: View {
    let state: VehicleState
    let status: ConnectionStatus
    let units: Units

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(state.displayName ?? "Tesla")
                    .font(.title.weight(.bold))
                    .foregroundStyle(Brand.textPrimary)
                Text(state.modelLine.isEmpty ? "Tesla" : state.modelLine)
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
                HStack(spacing: 8) {
                    if let st = state.state {
                        Chip(text: st.label, systemImage: st.symbol, color: st.color, filled: true)
                    }
                    if let since = state.since {
                        Text(units.relative(since)).font(.caption).foregroundStyle(Brand.textTertiary)
                    }
                }
            }
            Spacer()
            if let healthy = state.healthy {
                VStack(spacing: 3) {
                    Image(systemName: healthy ? "heart.fill" : "heart.slash")
                        .foregroundStyle(healthy ? Brand.online : Brand.danger)
                    Text(healthy ? L("Healthy") : L("Check"))
                        .font(.caption2).foregroundStyle(Brand.textTertiary)
                }
            }
        }
        .card()
    }
}

struct VehicleInfoCard: View {
    let info: CarInfo?
    let state: VehicleState
    let units: Units
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(L("Vehicle"), systemImage: "car.fill")
            TileGrid(columns: 3) {
                if let eff = info?.efficiencyKwhPerKm, eff > 0 {
                    UnitStatTile(title: L("Efficiency"), value: units.consumption(whPerKm: eff * 1000),
                                 tint: Brand.crimson) { UnitToggle.consumption(env) }
                }
                if let color = info?.exteriorColor ?? state.exteriorColor {
                    StatTile(title: L("Color"), value: prettyColor(color))
                }
                if let wheels = info?.wheelType ?? state.wheelType {
                    StatTile(title: L("Wheels"), value: wheels)
                }
                if let drives = info?.totalDrives {
                    StatTile(title: L("Total drives"), value: "\(drives)", systemImage: "road.lanes")
                }
                if let charges = info?.totalCharges {
                    StatTile(title: L("Total charges"), value: "\(charges)", systemImage: "bolt")
                }
                if let updates = info?.totalUpdates {
                    StatTile(title: L("Updates"), value: "\(updates)", systemImage: "arrow.down.circle")
                }
            }
            if let vin = info?.vin, !vin.isEmpty {
                Divider().overlay(Brand.hairline)
                KeyValueRow(label: "VIN", value: vin, systemImage: "number", copyValue: vin)
            }
        }
        .card()
    }

    private func prettyColor(_ raw: String) -> String {
        // TeslaMate color codes → readable (best-effort).
        let map = ["DeepBlue": L("Deep Blue"), "StealthGrey": L("Stealth Grey"),
                   "PearlWhite": L("Pearl White"), "SolidBlack": L("Black"),
                   "RedMulticoat": L("Red"), "MidnightSilver": L("Midnight Silver"),
                   "SilverMetallic": L("Silver")]
        return map[raw] ?? raw
    }
}

// MARK: - Battery

struct BatterySummaryCard: View {
    let state: VehicleState
    let units: Units

    private var level: Int { state.batteryLevel ?? state.usableBatteryLevel ?? 0 }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            BatteryRing(
                level: level,
                usableLevel: state.usableBatteryLevel,
                charging: state.isCharging,
                limitSoc: state.chargeLimitSoc,
                centerTitle: "\(level)%",
                centerSubtitle: units.range(km: state.range(for: units.range)),
                size: 168)

            VStack(alignment: .leading, spacing: 14) {
                miniStat(L("Range"), units.range(km: state.range(for: units.range)), "road.lanes")
                if let usable = state.usableBatteryLevel {
                    miniStat(L("Usable"), "\(usable)%", "bolt.badge.checkmark")
                }
                if let limit = state.chargeLimitSoc {
                    miniStat(L("Charge limit"), "\(limit)%", "target")
                }
                if let odo = state.odometer {
                    miniStat(L("Odometer"), units.distance(km: odo, digits: 0), "gauge")
                }
            }
            Spacer(minLength: 0)
        }
        .card()
    }

    private func miniStat(_ label: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.caption).foregroundStyle(Brand.crimson).frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.caption2).foregroundStyle(Brand.textTertiary)
                Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.textPrimary)
            }
        }
    }
}

// MARK: - Charging

struct ChargingCard: View {
    let state: VehicleState
    let units: Units

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(L("Charging"), systemImage: "bolt.fill")
            TileGrid(columns: 3) {
                StatTile(title: L("Power"), value: units.power(kw: state.chargerPower), tint: Brand.crimson)
                StatTile(title: L("Voltage"), value: units.volts(state.chargerVoltage))
                StatTile(title: L("Current"), value: units.amps(state.chargerActualCurrent))
                StatTile(title: L("Added"), value: units.energy(kwh: state.chargeEnergyAdded))
                StatTile(title: L("Phases"), value: state.chargerPhases.map(String.init) ?? "—")
                StatTile(title: L("Time to full"), value: units.duration(hours: state.timeToFullCharge))
            }
            Divider().overlay(Brand.hairline)
            VStack(spacing: 10) {
                if let cs = state.chargingState {
                    KeyValueRow(label: L("State"), value: cs.label, valueColor: Brand.crimson, systemImage: "bolt.circle")
                }
                KeyValueRow(label: L("Plugged in"), value: boolText(state.pluggedIn), systemImage: "powerplug")
                KeyValueRow(label: L("Charge port"), value: state.chargePortDoorOpen == true ? L("Open") : L("Closed"), systemImage: "door.left.hand.open")
                if let sched = state.scheduledChargingStartTime {
                    KeyValueRow(label: L("Scheduled start"), value: units.shortDateTime(sched), systemImage: "clock")
                }
            }
        }
        .card()
    }

    private func boolText(_ b: Bool?) -> String {
        b == true ? L("Yes") : (b == false ? L("No") : "—")
    }
}

// MARK: - Driving

struct DrivingCard: View {
    let state: VehicleState
    let units: Units

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(L("Driving"), systemImage: "steeringwheel")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(units.speed(kmh: state.speed).replacingOccurrences(of: " \(units.speedUnit)", with: ""))
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.textPrimary)
                    .contentTransition(.numericText())
                Text(units.speedUnit).font(.headline).foregroundStyle(Brand.textTertiary)
                Spacer()
                if let heading = state.heading {
                    Image(systemName: "location.north.fill")
                        .font(.title2)
                        .foregroundStyle(Brand.crimson)
                        .rotationEffect(.degrees(Double(heading)))
                }
            }
            TileGrid(columns: 3) {
                StatTile(title: L("Power"), value: units.power(kw: state.power), tint: Brand.crimson)
                StatTile(title: L("Gear"), value: state.shiftState?.label ?? "—")
                StatTile(title: L("Elevation"), value: state.elevation.map { "\($0) m" } ?? "—")
            }
        }
        .card()
    }
}

// MARK: - Sentry (inferred)

struct SentryInferredCard: View {
    let state: VehicleState
    let units: Units

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "video.badge.waveform").foregroundStyle(Brand.crimson)
                Text(L("Possible Sentry event")).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.textPrimary)
                Spacer()
                Chip(text: L("Inferred"), color: Brand.warning)
            }
            Text(L("The car is showing the Sentry banner (center display state 7) near \(state.geofence ?? L("its location")). This is inferred — any clip is on the car's USB and isn't available via TeslaMate."))
                .font(.caption).foregroundStyle(Brand.textSecondary)
        }
        .card()
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Brand.crimson.opacity(0.5), lineWidth: 1))
    }
}

// MARK: - Climate

struct ClimateCard: View {
    let state: VehicleState
    let units: Units

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(L("Climate"), systemImage: "thermometer.medium")
            TileGrid(columns: 3) {
                StatTile(title: L("Inside"), value: units.temperature(c: state.insideTemp), systemImage: "car.side")
                StatTile(title: L("Outside"), value: units.temperature(c: state.outsideTemp), systemImage: "cloud.sun")
                StatTile(title: L("A/C"), value: onOff(state.isClimateOn),
                         systemImage: "fan", tint: state.isClimateOn == true ? Brand.crimson : Brand.textPrimary)
            }
            if state.isPreconditioning == true || state.climateKeeperMode != nil {
                HStack(spacing: 8) {
                    if state.isPreconditioning == true { Chip(text: L("Preconditioning"), systemImage: "snowflake") }
                    if let mode = state.climateKeeperMode, mode != "off", !mode.isEmpty {
                        Chip(text: climateModeLabel(mode), systemImage: "shield", color: Brand.driving)
                    }
                }
            }
        }
        .card()
    }

    private func onOff(_ b: Bool?) -> String {
        b == true ? L("On") : (b == false ? L("Off") : "—")
    }

    private func climateModeLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "dog": L("Dog mode")
        case "camp": L("Camp mode")
        case "keep", "on": L("Keep climate on")
        case "cool": L("Cooling")
        case "heat": L("Heating")
        case "auto": L("Automatic")
        default: L("Climate active")
        }
    }
}

// MARK: - Security

struct SecurityCard: View {
    let state: VehicleState

    private struct SecurityIndicator: Identifiable {
        let id: String
        let title: String
        let icon: String
        let isActive: Bool
        let activeColor: Color
        let accessibilityValue: String
    }

    private var indicators: [SecurityIndicator] {
        [
            SecurityIndicator(
                id: "lock", title: L("Lock"),
                icon: state.locked == false ? "lock.open.fill" : "lock.fill",
                isActive: state.locked == true, activeColor: Brand.online,
                accessibilityValue: state.locked.map { $0 ? L("Locked") : L("Unlocked") } ?? "—"
            ),
            SecurityIndicator(
                id: "sentry", title: L("Sentry"), icon: "video.fill",
                isActive: state.sentryMode == true, activeColor: Brand.crimson,
                accessibilityValue: onOff(state.sentryMode)
            ),
            SecurityIndicator(
                id: "occupied", title: L("Occupied"), icon: "person.fill",
                isActive: state.isUserPresent == true, activeColor: Brand.driving,
                accessibilityValue: onOff(state.isUserPresent)
            ),
            openingIndicator(id: "frunk", title: L("Frunk"), icon: "car.side.front.open", value: state.frunkOpen),
            openingIndicator(id: "trunk", title: L("Trunk"), icon: "car.side.rear.open", value: state.trunkOpen),
            openingIndicator(id: "windows", title: L("Windows"), icon: "rectangle.split.3x1", value: state.windowsOpen),
            openingIndicator(id: "driver-front", title: L("Driver front"), icon: "door.left.hand.open", value: state.driverFrontDoorOpen),
            openingIndicator(id: "passenger-front", title: L("Passenger front"), icon: "door.right.hand.open", value: state.passengerFrontDoorOpen),
            openingIndicator(id: "driver-rear", title: L("Driver rear"), icon: "door.left.hand.open", value: state.driverRearDoorOpen),
            openingIndicator(id: "passenger-rear", title: L("Passenger rear"), icon: "door.right.hand.open", value: state.passengerRearDoorOpen)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(L("Security"), systemImage: "lock.shield")
            ViewThatFits(in: .horizontal) {
                statusGrid(spacing: 12)
                    .frame(minWidth: 500, maxWidth: 620)
                statusGrid(spacing: 8)
                    .frame(maxWidth: 400)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .card()
    }

    private func statusGrid(spacing: CGFloat) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: 5),
            alignment: .center,
            spacing: spacing
        ) {
            ForEach(indicators) { indicator in
                statusTile(indicator)
            }
        }
    }

    private func statusTile(_ indicator: SecurityIndicator) -> some View {
        let color = indicator.isActive ? indicator.activeColor : Brand.textTertiary
        return VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(color.opacity(indicator.isActive ? 0.16 : 0.08))
                Image(systemName: indicator.icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(maxWidth: 28, maxHeight: 21)
            }
            .frame(width: 40, height: 32)

            Text(indicator.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(indicator.isActive ? Brand.textPrimary : Brand.textTertiary)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .center)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 78, maxHeight: 78)
        .background(
            indicator.isActive ? color.opacity(0.12) : Brand.elevatedSurface,
            in: RoundedRectangle(cornerRadius: Metrics.tightRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.tightRadius, style: .continuous)
                .strokeBorder(indicator.isActive ? color.opacity(0.42) : Brand.hairline)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(indicator.title)
        .accessibilityValue(indicator.accessibilityValue)
        .accessibilityIdentifier("security-\(indicator.id)")
    }

    private func openingIndicator(id: String, title: String, icon: String, value: Bool?) -> SecurityIndicator {
        SecurityIndicator(
            id: id, title: title, icon: icon,
            isActive: value == true, activeColor: Brand.warning,
            accessibilityValue: value.map { $0 ? L("Open") : L("Closed") } ?? "—"
        )
    }

    private func onOff(_ value: Bool?) -> String {
        value.map { $0 ? L("On") : L("Off") } ?? "—"
    }
}

// MARK: - TPMS

struct TPMSCard: View {
    let state: VehicleState
    let units: Units
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(L("Tire pressure"), systemImage: "gauge.with.dots.needle.bottom.50percent")
            HStack(spacing: 12) {
                tire(L("FL"), state.tpmsPressureFL, state.tpmsSoftWarningFL == true)
                tire(L("FR"), state.tpmsPressureFR, state.tpmsSoftWarningFR == true)
                tire(L("RL"), state.tpmsPressureRL, state.tpmsSoftWarningRL == true)
                tire(L("RR"), state.tpmsPressureRR, state.tpmsSoftWarningRR == true)
            }
            if state.anyTpmsSoftWarning {
                Label(L("Low pressure: \(state.tiresWithSoftWarning.joined(separator: ", "))"),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(Brand.warning)
            }
        }
        .card()
    }

    /// Tapping any tyre flips every pressure in the app between bar and psi.
    private func tire(_ label: String, _ bar: Double?, _ warn: Bool) -> some View {
        Button {
            withAnimation(.snappy) { UnitToggle.pressure(env) }
        } label: {
            VStack(spacing: 6) {
                Text(label).font(.caption2.weight(.bold)).foregroundStyle(warn ? Brand.warning : Brand.textTertiary)
                Text(units.pressure(bar: bar))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(warn ? Brand.warning : Brand.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(warn ? Brand.warning.opacity(0.12) : Brand.elevatedSurface,
                        in: RoundedRectangle(cornerRadius: Metrics.tightRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("\(label): \(units.pressure(bar: bar)). Tap to change unit."))
    }
}

// MARK: - Location

struct LocationCard: View {
    let state: VehicleState
    let units: Units

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(L("Location"), systemImage: "mappin.and.ellipse")
                if let geofence = state.geofence, !geofence.isEmpty {
                    Chip(text: geofence, systemImage: "mappin", color: Brand.crimson)
                }
            }
            if let coord = state.coordinate {
                MiniMap(coordinate: coord)
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.tightRadius))
            } else {
                EmptyStateView(systemImage: "mappin.slash", title: L("No position"), message: nil)
                    .frame(height: 120)
            }
        }
        .card()
    }
}

struct MiniMap: View {
    let coordinate: Coordinate

    var body: some View {
        ExpandableMapPreview(title: L("Location"), identifier: "location") {
            locationMap
        } expanded: {
            locationMap
        }
    }

    private var locationMap: some View {
        FollowingMap(coordinate: coordinate, span: 0.01) {
            locationMarker
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }

    private var locationMarker: some View {
        ZStack {
            Circle().fill(Brand.crimson.opacity(0.25)).frame(width: 34, height: 34)
            Circle().fill(Brand.crimson).frame(width: 16, height: 16)
                .overlay(Circle().stroke(.white, lineWidth: 2))
        }
    }
}

// MARK: - Active route

struct RouteCard: View {
    let state: VehicleState
    let units: Units

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(L("Active route"), systemImage: "arrow.triangle.turn.up.right.diamond")
            Text(state.activeRouteDestination ?? "—")
                .font(.headline).foregroundStyle(Brand.textPrimary).lineLimit(2)
            TileGrid(columns: 2) {
                StatTile(title: L("Distance"),
                         value: units.distance(km: state.activeRouteMilesToArrival.map { $0 * 1.609344 }, digits: 1))
                StatTile(title: L("ETA"),
                         value: state.activeRouteMinutesToArrival.map { units.time(Date().addingTimeInterval($0 * 60)) } ?? "—",
                         tint: Brand.action)
                StatTile(title: L("Traffic delay"),
                         value: state.activeRouteTrafficMinutesDelay.map { "\(Int($0)) min" } ?? "—",
                         tint: (state.activeRouteTrafficMinutesDelay ?? 0) > 0 ? Brand.warning : Brand.textPrimary)
                StatTile(title: L("Battery at arrival"),
                         value: state.activeRouteEnergyAtArrival.map { "\($0)%" } ?? "—", tint: Brand.crimson)
            }
        }
        .card()
    }
}

// MARK: - Software

struct SoftwareCard: View {
    let state: VehicleState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(L("Software"), systemImage: "cpu")
            KeyValueRow(label: L("Installed"), value: state.version ?? "—", systemImage: "checkmark.seal")
            if state.updateAvailable == true {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Brand.crimson)
                    Text(L("Update available\(state.updateVersion.map { ": \($0)" } ?? "")"))
                        .font(.subheadline.weight(.medium)).foregroundStyle(Brand.crimson)
                    Spacer()
                }
            } else {
                Label(L("Up to date"), systemImage: "checkmark.circle")
                    .font(.subheadline).foregroundStyle(Brand.online)
            }
        }
        .card()
    }
}
