import SwiftUI

/// Five compact, read-only vehicle pages. Horizontal paging keeps each glance focused while
/// preserving the same accent and live data used by the iPhone dashboard.
struct WatchStatusView: View {
    @Environment(WatchSnapshotStore.self) private var store
    @State private var selectedPage = Int(ProcessInfo.processInfo.environment["TESSTATS_WATCH_PAGE"] ?? "0") ?? 0

    var body: some View {
        Group {
            if let snap = store.snapshot {
                dashboard(snap)
            } else {
                waiting
            }
        }
        .background(Color.black)
        .environment(\.locale, store.snapshot?.interfaceLocale ?? WidgetLanguage.locale(for: nil))
    }

    private var waiting: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.white.opacity(0.08)).frame(width: 58, height: 58)
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.blue)
            }
            Text("Tesstats").font(.headline)
            Text("Open Tesstats on your iPhone to sync.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Refresh") { store.refresh() }
                .buttonStyle(.bordered)
                .tint(.blue)
        }
        .padding()
    }

    private func dashboard(_ snap: WidgetSnapshot) -> some View {
        GeometryReader { proxy in
            TabView(selection: $selectedPage) {
                batteryPage(snap).tag(0)
                securityPage(snap).tag(1)
                tirePage(snap).tag(2)
                climatePage(snap).tag(3)
                healthPage(snap).tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .tint(accent(snap))
    }

    // MARK: - Battery

    private func batteryPage(_ snap: WidgetSnapshot) -> some View {
        page(snap, title: snap.carName, icon: snap.isCharging ? "bolt.fill" : "battery.75percent") {
            VStack(spacing: 7) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.10), lineWidth: 9)
                    Circle()
                        .trim(from: 0, to: min(1, max(0, Double(snap.batteryLevel) / 100)))
                        .stroke(batteryTint(snap), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: batteryTint(snap).opacity(0.45), radius: 5)
                    VStack(spacing: -1) {
                        if snap.isCharging {
                            Image(systemName: "bolt.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.green)
                        }
                        Text("\(snap.batteryLevel)%")
                            .font(.system(size: 25, weight: .bold, design: .rounded))
                    }
                }
                .frame(width: 78, height: 78)
                .accessibilityLabel("Battery \(snap.batteryLevel)%")

                HStack(spacing: 3) {
                    Image(systemName: "road.lanes").foregroundStyle(accent(snap))
                    Text(snap.rangeString()).fontWeight(.semibold)
                    Text("/").foregroundStyle(.tertiary)
                    Text(snap.fullRangeString()).foregroundStyle(.secondary)
                }
                .font(.caption)

                if snap.isCharging {
                    HStack(spacing: 6) {
                        miniMetric(snap.powerString, icon: "bolt.fill", tint: .green)
                        miniMetric(WidgetSnapshot.timeString(hours: snap.timeToFullHours,
                                                             languageCode: snap.languageCode),
                                   icon: "clock.fill", tint: accent(snap))
                        if let limit = snap.chargeLimitSoc {
                            miniMetric("\(limit)%", icon: "flag.fill", tint: accent(snap))
                        }
                    }
                } else {
                    stateChip(snap)
                }
            }
        }
    }

    // MARK: - Security

    private func securityPage(_ snap: WidgetSnapshot) -> some View {
        page(snap, title: tr(snap, "Security", "Seguridad"), icon: "shield.checkered") {
            HStack(spacing: 5) {
                statusTile(icon: snap.locked == false ? "lock.open.fill" : "lock.fill",
                           title: snap.locked == false ? tr(snap, "Unlocked", "Abierto") : tr(snap, "Locked", "Cerrado"),
                           active: snap.locked == true, warning: snap.locked == false, accent: accent(snap))
                statusTile(icon: "video.fill", title: tr(snap, "Sentry", "Centinela"),
                           active: snap.sentryMode == true, warning: false, accent: accent(snap))
                statusTile(icon: "person.fill",
                           title: snap.occupied == true ? tr(snap, "Occupied", "Ocupado") : tr(snap, "Empty", "Vacío"),
                           active: snap.occupied == true, warning: false, accent: accent(snap))
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Tires

    private func tirePage(_ snap: WidgetSnapshot) -> some View {
        page(snap, title: tr(snap, "Tire pressure", "Neumáticos"), icon: "tirepressure") {
            VStack(spacing: 2) {
                HStack(spacing: 28) {
                    tireValue(snap, label: "FL", value: snap.tpmsPressureFL, warning: snap.tpmsSoftWarningFL)
                    tireValue(snap, label: "FR", value: snap.tpmsPressureFR, warning: snap.tpmsSoftWarningFR)
                }
                ZStack {
                    Capsule().fill(accent(snap).opacity(0.16)).frame(width: 84, height: 38)
                    Image(systemName: "car.top.radiowaves.rear.left.and.rear.right")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(accent(snap))
                }
                HStack(spacing: 28) {
                    tireValue(snap, label: "RL", value: snap.tpmsPressureRL, warning: snap.tpmsSoftWarningRL)
                    tireValue(snap, label: "RR", value: snap.tpmsPressureRR, warning: snap.tpmsSoftWarningRR)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Climate

    private func climatePage(_ snap: WidgetSnapshot) -> some View {
        page(snap, title: tr(snap, "Climate", "Clima"), icon: "thermometer.medium") {
            VStack(spacing: 8) {
                HStack(spacing: 7) {
                    temperatureTile(snap, title: tr(snap, "Inside", "Interior"), value: snap.insideTempC, icon: "car.fill")
                    temperatureTile(snap, title: tr(snap, "Outside", "Exterior"), value: snap.outsideTempC, icon: "cloud.sun.fill")
                }
                HStack(spacing: 7) {
                    Image(systemName: snap.isClimateOn == true ? "fan.fill" : "fan")
                        .symbolEffect(.rotate, options: .repeating, isActive: snap.isClimateOn == true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snap.isClimateOn == true ? tr(snap, "A/C on", "Clima activo") : tr(snap, "A/C off", "Clima apagado"))
                            .font(.caption.weight(.semibold))
                        if snap.isPreconditioning == true {
                            Text(tr(snap, "Preconditioning", "Preacondicionando"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Circle()
                        .fill(snap.isClimateOn == true ? accent(snap) : Color.secondary.opacity(0.5))
                        .frame(width: 8, height: 8)
                }
                .padding(.horizontal, 10)
                .frame(height: 42)
                .background(cardBackground, in: RoundedRectangle(cornerRadius: 13))
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Battery health

    private func healthPage(_ snap: WidgetSnapshot) -> some View {
        page(snap, title: tr(snap, "Battery health", "Salud de batería"), icon: "heart.text.square.fill") {
            VStack(spacing: 7) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.10), lineWidth: 6)
                        Circle()
                            .trim(from: 0, to: healthProgress(snap))
                            .stroke(accent(snap), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text(healthText(snap))
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                    }
                    .frame(width: 58, height: 58)
                    VStack(alignment: .leading, spacing: 5) {
                        compactStat(tr(snap, "Capacity", "Capacidad"), currentCapacity(snap), originalCapacity(snap))
                        compactStat(tr(snap, "Full range", "Autonomía total"),
                                    snap.fullRangeString(), snap.distanceString(snap.originalRangeKm, digits: 0))
                    }
                }
                HStack(spacing: 6) {
                    statCard(tr(snap, "Odometer", "Odómetro"), snap.distanceString(snap.odometerKm, digits: 0), "gauge.with.dots.needle.50percent")
                    statCard(tr(snap, "Last trip", "Último viaje"), snap.distanceString(snap.lastTripDistanceKm), "point.bottomleft.forward.to.point.topright.scurvepath")
                }
            }
        }
    }

    // MARK: - Components

    private func page<Content: View>(_ snap: WidgetSnapshot, title: String, icon: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption.weight(.bold)).foregroundStyle(accent(snap))
                Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 2)
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    Circle().fill(freshnessColor(snap)).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 3)
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .padding(.bottom, 17)
        .background(RadialGradient(colors: [accent(snap).opacity(0.13), .black],
                                   center: .topTrailing, startRadius: 1, endRadius: 170))
    }

    private func statusTile(icon: String, title: String, active: Bool, warning: Bool, accent: Color) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(warning ? Color.red.opacity(0.20) : active ? accent.opacity(0.22) : Color.white.opacity(0.07))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(warning ? Color.red : active ? accent : Color.secondary)
            }
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 16))
    }

    private func tireValue(_ snap: WidgetSnapshot, label: String, value: Double?, warning: Bool?) -> some View {
        VStack(spacing: 1) {
            Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            Text(snap.pressureString(value))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(warning == true ? Color.red : Color.primary)
                .minimumScaleFactor(0.75)
        }
        .frame(width: 66, height: 34)
        .background(warning == true ? Color.red.opacity(0.14) : cardBackground,
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private func temperatureTile(_ snap: WidgetSnapshot, title: String, value: Double?, icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.caption).foregroundStyle(accent(snap))
            Text(snap.temperatureString(value)).font(.system(size: 19, weight: .bold, design: .rounded))
            Text(title).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 74)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 15))
    }

    private func miniMetric(_ value: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(value).foregroundStyle(.primary)
        }
        .font(.system(size: 9, weight: .semibold))
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(cardBackground, in: Capsule())
    }

    private func compactStat(_ title: String, _ current: String, _ original: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased()).font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                Text(current).font(.system(size: 11, weight: .semibold, design: .rounded))
                if original != "—" {
                    Text("/ \(original)").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
    }

    private func statCard(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(title.uppercased()).font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 10, weight: .semibold, design: .rounded)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 10))
    }

    private func stateChip(_ snap: WidgetSnapshot) -> some View {
        HStack(spacing: 5) {
            Circle().fill(stateColor(snap)).frame(width: 6, height: 6)
            Text(stateLabel(snap)).font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(cardBackground, in: Capsule())
    }

    private var cardBackground: Color { Color.white.opacity(0.07) }

    private func accent(_ snap: WidgetSnapshot) -> Color {
        Color.watchHex(snap.accentColorHex ?? "3E6AE1")
    }

    private func batteryTint(_ snap: WidgetSnapshot) -> Color {
        if snap.isCharging { return .green }
        if snap.batteryLevel <= 20 { return .red }
        return accent(snap)
    }

    private func freshnessColor(_ snap: WidgetSnapshot) -> Color {
        guard snap.lastUpdated > .distantPast else { return .secondary }
        let age = Date().timeIntervalSince(snap.lastUpdated)
        if age < 60, store.isPhoneReachable { return .green }
        if age < 300 { return accent(snap) }
        return .orange
    }

    private func stateColor(_ snap: WidgetSnapshot) -> Color {
        switch snap.stateRaw {
        case "charging": .green
        case "driving", "online": accent(snap)
        case "offline": .red
        default: .secondary
        }
    }

    private func stateLabel(_ snap: WidgetSnapshot) -> String {
        switch snap.stateRaw {
        case "online": tr(snap, "Online", "En línea")
        case "asleep", "suspended": tr(snap, "Asleep", "Dormido")
        case "charging": tr(snap, "Charging", "Cargando")
        case "driving": tr(snap, "Driving", "Conduciendo")
        case "offline": tr(snap, "Offline", "Sin conexión")
        case "updating": tr(snap, "Updating", "Actualizando")
        default: tr(snap, "Unknown", "Desconocido")
        }
    }

    private func healthProgress(_ snap: WidgetSnapshot) -> Double {
        guard let health = snap.batteryHealthPercent, health.isFinite else { return 0 }
        return min(1, max(0, health / 100))
    }

    private func healthText(_ snap: WidgetSnapshot) -> String {
        guard let health = snap.batteryHealthPercent, health.isFinite,
              health > 0, health <= Double(Int.max) else { return "—" }
        return "\(Int(health.rounded()))%"
    }

    private func currentCapacity(_ snap: WidgetSnapshot) -> String {
        guard let value = snap.currentCapacityKwh, value.isFinite, value > 0 else { return "—" }
        return "\(WidgetLanguage.number(value, fractionDigits: 1, code: snap.languageCode)) kWh"
    }

    private func originalCapacity(_ snap: WidgetSnapshot) -> String {
        guard let value = snap.originalCapacityKwh, value.isFinite, value > 0 else { return "—" }
        return "\(WidgetLanguage.number(value, fractionDigits: 1, code: snap.languageCode)) kWh"
    }

    private func tr(_ snap: WidgetSnapshot, _ english: String, _ spanish: String) -> String {
        WidgetLanguage.resolvedCode(snap.languageCode) == "es" ? spanish : english
    }
}

private extension Color {
    static func watchHex(_ value: String) -> Color {
        let cleaned = value.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let rgb = UInt64(cleaned, radix: 16) else {
            return Color(red: 0.243, green: 0.416, blue: 0.882)
        }
        return Color(red: Double((rgb >> 16) & 0xFF) / 255,
                     green: Double((rgb >> 8) & 0xFF) / 255,
                     blue: Double(rgb & 0xFF) / 255)
    }
}
