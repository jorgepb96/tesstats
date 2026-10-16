import SwiftUI
import MapKit
#if os(iOS)
import UIKit
#endif

/// A supplemental, glanceable display for a mounted iPhone or iPad. It never sends vehicle
/// commands and deliberately omits data TeslaMate cannot guarantee.
struct DriverDisplayView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var now = Date()
    @State private var phoneTelemetry = DriverPhoneTelemetry()
    @State private var showDriverSettings = false
    @State private var currentTripConsumption = DriverTripConsumptionEstimator()
    @State private var mapZoomFactor = 1.0
    @State private var currentBatteryPricePerKwh: Double?
    @ScaledMetric(relativeTo: .caption) private var metricValueSize: CGFloat = 16
    @ScaledMetric(relativeTo: .caption2) private var temperatureValueSize: CGFloat = 15

    private var config: DriverDisplayConfiguration { env.settings.config.driverDisplay }
    private var units: Units { Units(config: env.settings.config) }
    private var modules: Set<DriverDisplayModule> { Set(config.visibleModules) }
    private var forcesPhoneFallback: Bool {
        ProcessInfo.processInfo.environment["TESSTATS_FORCE_PHONE_FALLBACK"] == "1"
    }
    private var shouldRunBluetooth: Bool {
        config.telemetryMode != .iphoneAndTeslaMate
    }
    private var bluetoothRunID: String {
        "\(env.live.resolvedCarID ?? -1)|\(config.telemetryMode.rawValue)"
    }
    private var usesPhoneFallback: Bool {
        if forcesPhoneFallback { return true }
        if config.telemetryMode == .bluetooth { return false }
        if hasFreshBluetoothSnapshot { return false }
        return switch env.live.status {
        case .connected, .demo: false
        default: true
        }
    }
    private var allowsPhoneTelemetry: Bool { env.live.status != .demo || forcesPhoneFallback }
    private var bluetoothSnapshot: DriverBluetoothTelemetrySnapshot? {
        guard config.telemetryMode != .iphoneAndTeslaMate else { return nil }
        if config.telemetryMode == .automatic, !env.driverBluetooth.isTelemetryStable { return nil }
        guard let snapshot = env.driverBluetooth.snapshot,
              snapshot.vehicleID == env.driverBluetooth.identity?.vehicleID,
              snapshot.isFresh(at: now, maximumAge: DriverSpeedFusion.bluetoothMaximumAge) else { return nil }
        return snapshot
    }
    private var hasFreshBluetoothSnapshot: Bool { bluetoothSnapshot != nil }
    private var isScreenshotMode: Bool {
        ProcessInfo.processInfo.environment["TESSTATS_SCREENSHOT_MODE"] == "1"
    }
    private var state: VehicleState {
        var value = env.live.currentState ?? VehicleState(carID: -1)
        if let bluetooth = bluetoothSnapshot {
            value.speed = bluetooth.speedKmh ?? value.speed
            value.power = bluetooth.powerKw ?? value.power
            value.shiftState = bluetooth.shiftState ?? value.shiftState
            value.odometer = bluetooth.odometerKm ?? value.odometer
            if bluetooth.shiftState == .drive || bluetooth.shiftState == .reverse {
                value.state = .driving
            }
            value.lastUpdated = max(value.lastUpdated, bluetooth.date)
        }
        // Once Core Location has supplied a valid sample, retain that phone position between
        // updates. Falling back to TeslaMate after an arbitrary three-second gap made the map
        // jump hundreds of kilometres when the user was away from the parked vehicle.
        if allowsPhoneTelemetry,
           let coordinate = DriverMapPositionPolicy.resolve(phone: phoneTelemetry.coordinate,
                                                             teslaMate: value.coordinate) {
            value.heading = phoneTelemetry.heading ?? value.heading
            value.latitude = coordinate.latitude
            value.longitude = coordinate.longitude
        }
        if usesPhoneFallback {
            let fallbackSpeed = phoneTelemetry.speedSample(at: now)?.speedKmh
            value.state = (fallbackSpeed ?? 0) > 2 ? .driving : .online
            value.speed = fallbackSpeed
            value.power = nil
            value.shiftState = (fallbackSpeed ?? 0) > 2 ? .drive : .park
            value.outsideTemp = phoneTelemetry.outsideTemperatureC ?? value.outsideTemp
            value.activeRouteDestination = nil
            value.activeRouteLatitude = nil
            value.activeRouteLongitude = nil
            value.activeRouteMilesToArrival = nil
            value.activeRouteMinutesToArrival = nil
            value.activeRouteEnergyAtArrival = nil
        }
        return value
    }
    private var tripDistanceKm: Double? {
        if hasFreshBluetoothSnapshot, let bluetoothTrip = env.driverBluetooth.tripDistanceKm {
            return bluetoothTrip
        }
        return usesPhoneFallback ? phoneTelemetry.tripDistanceKm : env.live.currentTripDistanceKm
    }
    private var averageConsumptionWhPerKm: Double? {
        let value = env.history.efficiency.avgWhPerKm
        return value > 0 ? value : nil
    }
    private var currentTripConsumptionWhPerKm: Double? { currentTripConsumption.averageWhPerKm }
    private var currentTripCost: Double? {
        guard let price = currentBatteryPricePerKwh, price.isFinite, price >= 0,
              currentTripConsumption.energyKWh > 0.000_001 else { return nil }
        return currentTripConsumption.energyKWh * price
    }
    private var tripPricingRunID: String {
        "\(env.history.revision)|\(env.settings.config.tripPricingSignature)|\(env.live.currentState?.batteryLevel ?? -1)"
    }
    private var forcedScheme: ColorScheme? {
        switch config.appearance {
        case .followApp: nil
        case .light: .light
        case .dark, .highContrast: .dark
        }
    }
    private var isDayMode: Bool { (forcedScheme ?? colorScheme) == .light }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                driverBackground.ignoresSafeArea()
                if proxy.size.width > proxy.size.height {
                    landscape(state, size: proxy.size)
                } else {
                    portrait(state, size: proxy.size)
                }
            }
        }
        .preferredColorScheme(forcedScheme)
        .driverSystemChromeHidden()
        .transaction { transaction in
            if isScreenshotMode {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .onAppear {
            setAwake(config.keepScreenAwake)
            if allowsPhoneTelemetry { phoneTelemetry.start() }
        }
        .onChange(of: allowsPhoneTelemetry) { _, enabled in
            if enabled { phoneTelemetry.start() }
            else { phoneTelemetry.stop() }
        }
        .onDisappear {
            setAwake(false)
            phoneTelemetry.stop()
            env.driverBluetooth.stop()
        }
        .task(id: bluetoothRunID) {
            if shouldRunBluetooth {
                await env.driverBluetooth.start(carID: env.live.resolvedCarID)
            } else {
                env.driverBluetooth.stop()
                await env.driverBluetooth.prepare(carID: env.live.resolvedCarID)
            }
        }
        .task(id: env.live.resolvedCarID) {
            currentTripConsumption = env.live.driverConsumption.estimator(for: env.live.resolvedCarID)
            if let carID = env.live.resolvedCarID {
                await env.history.loadIfNeeded(carID: carID)
            }
        }
        .task(id: tripPricingRunID) {
            let drives = env.history.drives
            let charges = env.history.charges
            let pricing = ChargePricing(config: env.settings.config)
            let fuelPrice = env.settings.config.fuelPricePerLiter
            let fuelConsumption = env.settings.config.fuelConsumptionLPer100km
            let capacity = env.history.battery.last?.usableCapacityKwh
            let currentSoc = env.live.currentState?.batteryLevel
            let allocation = await Task.detached(priority: .utility) {
                TripEnergyCostLedger.allocation(
                    drives: drives,
                    charges: charges,
                    pricing: pricing,
                    fuelPricePerLiter: fuelPrice,
                    fuelConsumptionLPer100km: fuelConsumption,
                    usableCapacityKwh: capacity,
                    currentSoc: currentSoc
                )
            }.value
            guard !Task.isCancelled else { return }
            currentBatteryPricePerKwh = allocation.currentBatteryPricePerKwh
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { env.driverBluetooth.stop() }
            else if phase == .active {
                Task {
                    if shouldRunBluetooth {
                        await env.driverBluetooth.start(carID: env.live.resolvedCarID)
                    } else {
                        await env.driverBluetooth.prepare(carID: env.live.resolvedCarID)
                    }
                }
            }
        }
        .sheet(isPresented: $showDriverSettings) {
            DriverBluetoothSettingsSheet()
                .environment(env)
        }
        .task {
            while !Task.isCancelled {
                now = Date()
                updateCurrentTripConsumption(at: now)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private var driverBackground: Color {
        if config.appearance == .highContrast { return .black }
        return Brand.background
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.subheadline.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial, in: Circle())
        .overlay(Circle().strokeBorder(Brand.hairline).allowsHitTesting(false))
        .contentShape(Circle())
        .foregroundStyle(Brand.textPrimary)
        .accessibilityLabel(L("Close driver display"))
        .accessibilityIdentifier("driver-close")
    }

    private var bluetoothSettingsButton: some View {
        Button { showDriverSettings = true } label: {
            Image(systemName: "square.grid.2x2")
                .font(.subheadline.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial, in: Circle())
        .overlay(Circle().strokeBorder(Brand.hairline).allowsHitTesting(false))
        .contentShape(Circle())
        // The main icon remains stable while an unobtrusive dot communicates the actual radio
        // state. This avoids making a healthy automatic reconnect look like a flashing button.
        .foregroundStyle(env.driverBluetooth.isEnabled ? Brand.action : Brand.textPrimary)
        .overlay(alignment: .bottomTrailing) {
            if env.driverBluetooth.isEnabled {
                Circle()
                    .fill(bluetoothStatusColor)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(driverBackground, lineWidth: 1.5))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel("\(L("Driver display settings")), \(bluetoothStatusLabel)")
        .accessibilityIdentifier("driver-display-settings")
    }

    private var appearanceButton: some View {
        Button {
            env.settings.config.driverDisplay.appearance = isDayMode ? .dark : .light
            env.settings.save()
        } label: {
            Image(systemName: isDayMode ? "moon.fill" : "sun.max.fill")
                .font(.subheadline.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Brand.textPrimary)
        .background(.ultraThinMaterial, in: Circle())
        .overlay(Circle().strokeBorder(Brand.hairline).allowsHitTesting(false))
        .accessibilityLabel(L(isDayMode ? "Switch to night mode" : "Switch to day mode"))
        .accessibilityIdentifier("driver-appearance-toggle")
    }

    private var headerIdentity: some View {
        VStack(spacing: 3) {
            if modules.contains(.logo) { logo(width: 48) }
            if modules.contains(.clock) {
                Text(AppDate.shortTime(now))
                    .font(.caption2.weight(.bold)).monospacedDigit()
                    .foregroundStyle(Brand.textSecondary)
                    .lineLimit(1).fixedSize()
            }
        }
    }

    private var bluetoothStatusColor: Color {
        guard env.driverBluetooth.isEnabled,
              config.telemetryMode != .iphoneAndTeslaMate else { return Brand.textTertiary }
        return switch env.driverBluetooth.connectionState {
        case .failed: Brand.danger
        case .scanning, .connecting, .authenticating: Brand.warning
        case .connected: Brand.online
        case .idle: Brand.textTertiary
        }
    }

    private var bluetoothStatusLabel: String {
        guard env.driverBluetooth.isEnabled else { return L("Disabled") }
        if config.telemetryMode == .iphoneAndTeslaMate { return L("Bluetooth on standby") }
        return switch env.driverBluetooth.connectionState {
        case .failed: L("Error")
        case .scanning, .connecting, .authenticating: L("Reconnecting…")
        case .connected: L("Connected")
        case .idle: L("Paired")
        }
    }

    private func portrait(_ state: VehicleState, size: CGSize) -> some View {
        let mapBleed = min(76, max(44, size.width * 0.15))
        return ZStack {
            if modules.contains(.map) {
                Color.clear
                    .overlay {
                        DriverFollowingMap(state: state,
                                           usesPhoneFallback: usesPhoneFallback,
                                           weatherAttribution: phoneTelemetry.weatherAttribution,
                                           layout: .portrait,
                                           zoomFactor: mapZoomFactor,
                                           overlayTrailingInset: mapBleed + 14,
                                           overlayBottomInset: mapBleed + 155)
                            .frame(width: size.width + (mapBleed * 2),
                                   height: size.height + (mapBleed * 2))
                            .overlay {
                                LinearGradient(
                                    stops: [
                                        .init(color: driverBackground.opacity(0.60), location: 0),
                                        .init(color: driverBackground.opacity(0.22), location: 0.25),
                                        .init(color: driverBackground.opacity(0.08), location: 0.55),
                                        .init(color: driverBackground.opacity(0.52), location: 1)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .allowsHitTesting(false)
                            }
                            .overlay {
                                LinearGradient(colors: [driverBackground.opacity(0.32), .clear,
                                                        driverBackground.opacity(0.22)],
                                               startPoint: .leading, endPoint: .trailing)
                                    .allowsHitTesting(false)
                            }
                    }
            } else {
                RadialGradient(colors: [Brand.action.opacity(0.15), .clear],
                               center: .center, startRadius: 0, endRadius: size.width * 0.64)
            }

            if modules.contains(.speed) || modules.contains(.gear) {
                portraitSpeedFocus(state, size: size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, min(174, max(136, size.height * 0.18)))
            }

            VStack(spacing: 9) {
                Spacer()
                if modules.contains(.route), state.activeRouteDestination != nil {
                    portraitRouteSummary(state)
                }
                if (modules.contains(.power) && !usesPhoneFallback) || modules.contains(.motion) {
                    portraitDynamicsSummary(state)
                }
                portraitDistanceSummary(state)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 13)

            if modules.contains(.map) && modules.contains(.mapZoom) {
                mapZoomControls
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 5)
                    .padding(.bottom, 7)
                    .zIndex(50)
            }
        }
        .overlay(alignment: .top) {
            portraitTopRail(state)
        }
        .animation(.smooth(duration: 0.35), value: modules)
    }

    private func portraitTopRail(_ state: VehicleState) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 9) {
                headerIdentity
                if modules.contains(.connection) {
                    Circle()
                        .fill(usesPhoneFallback ? Brand.warning : env.live.status.color)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel(usesPhoneFallback ? L("Data delayed") : env.live.status.label)
                        .accessibilityIdentifier("driver-connection-indicator")
                }
                Spacer(minLength: 8)
                if modules.contains(.alerts) { landscapeAlerts(state) }
                appearanceButton
                bluetoothSettingsButton
                closeButton
                    .offset(x: 5)
            }

            HStack(spacing: 7) {
                if modules.contains(.environment) || modules.contains(.outsideTemperature) {
                    temperatureMetric(state)
                }
                if modules.contains(.battery) {
                    landscapeMetric(state.batteryLevel.map { "\($0)%" } ?? "—", icon: "battery.75percent",
                                    tint: Brand.online, identifier: "driver-battery")
                }
                if modules.contains(.range), let rangeCounter = landscapeRangeCounter(state) {
                    landscapeMetric(rangeCounter, icon: "gauge.with.dots.needle.50percent",
                                    tint: Brand.action, identifier: "driver-range-counter")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private func portraitSpeedFocus(_ state: VehicleState, size: CGSize) -> some View {
        let reading = resolvedSpeed(for: state)
        let raw = units.speed(kmh: reading?.speedKmh)
        let number = raw.replacingOccurrences(of: " \(units.speedUnit)", with: "")
        let diameter = min(size.width * 0.80, size.height * 0.38, 330)
        let points = min(max(config.speedScale.points + 5, 88), diameter * 0.37)
        return ZStack {
            if !isDayMode { Circle()
                .fill(
                    RadialGradient(colors: [Color.black.opacity(0.40), Color.black.opacity(0.23),
                                            driverBackground.opacity(0.10)],
                                   center: .center, startRadius: 16, endRadius: diameter * 0.50)
                )
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.36), radius: 22)
                .accessibilityIdentifier("driver-speed-dial")
            }

            if modules.contains(.speed) {
                VStack(spacing: -6) {
                    Text(number)
                        .font(.system(size: points, weight: .medium, design: .rounded))
                        .monospacedDigit().contentTransition(.numericText())
                        .minimumScaleFactor(0.62).lineLimit(1)
                        .frame(width: diameter * 0.60, alignment: .center)
                        .accessibilityIdentifier("driver-speed-value")
                    Text(units.speedUnit)
                        .font(.headline.weight(.medium))
                        .foregroundStyle(Brand.textTertiary)
                        .padding(.top, 7)
                    if modules.contains(.speedActivity) {
                        DriverSpeedActivityLine(speedKmh: reading?.speedKmh ?? 0, compact: false)
                            .frame(width: diameter * 0.44)
                            .padding(.top, 11)
                    }
                    speedHealthIndicator(reading)
                        .padding(.top, 7)
                }
            }
            if modules.contains(.gear) {
                DriverCircularTransmissionRail(value: state.shiftState?.rawValue, diameter: diameter)
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private func portraitRouteSummary(_ state: VehicleState) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "location.fill")
                .font(.headline.weight(.bold))
                .foregroundStyle(Brand.action)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.activeRouteDestination ?? "")
                    .font(.subheadline.weight(.bold)).lineLimit(1)
                HStack(spacing: 9) {
                    Text(units.distance(km: state.activeRouteMilesToArrival.map { $0 * 1.609344 }, digits: 1))
                    if let minutes = state.activeRouteMinutesToArrival { Text("\(Int(minutes.rounded())) min") }
                    if let soc = state.activeRouteEnergyAtArrival { Text("\(soc)%") }
                }
                .font(.system(size: metricValueSize, weight: .semibold)).monospacedDigit().foregroundStyle(Brand.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Brand.textPrimary)
        .padding(.horizontal, 13).padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.88), in: Capsule())
        .overlay(Capsule().strokeBorder(Brand.action.opacity(0.34)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("driver-route-summary")
    }

    private func portraitDynamicsSummary(_ state: VehicleState) -> some View {
        let motion = env.live.motion.snapshot
        let usePhoneMotion = allowsPhoneTelemetry && phoneTelemetry.isSpeedFresh(at: now)
        let acceleration = usePhoneMotion
            ? phoneTelemetry.accelerationMetersPerSecondSquared
            : (motion.isFresh(at: now) ? motion.accelerationMetersPerSecondSquared : nil)
        return HStack(spacing: 10) {
            if modules.contains(.power) && !usesPhoneFallback {
                Image(systemName: (motion.powerKw ?? state.power ?? 0) < 0 ? "arrow.down.left" : "bolt.fill")
                    .foregroundStyle((motion.powerKw ?? state.power ?? 0) < 0 ? Brand.online : Brand.action)
                Text(units.power(kw: motion.powerKw ?? state.power, digits: 0))
                    .font(.system(size: metricValueSize, weight: .bold)).monospacedDigit()
                DriverBipolarBar(value: motion.powerKw ?? state.power ?? 0, range: -80...180,
                                 leadingColor: Brand.online, trailingColor: Brand.action)
                    .frame(maxWidth: 118)
            }
            if modules.contains(.motion) {
                if modules.contains(.power) && !usesPhoneFallback {
                    Divider().frame(height: 22)
                }
                Image(systemName: acceleration == nil ? "waveform.slash" : "waveform.path.ecg")
                    .foregroundStyle(acceleration == nil ? Brand.warning : Brand.online)
                Text(acceleration.map { "\(units.number($0, digits: 2, signed: true)) m/s²" } ?? "—")
                    .font(.system(size: metricValueSize, weight: .bold)).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Brand.textPrimary)
        .padding(.horizontal, 13).padding(.vertical, 9)
        .background(.ultraThinMaterial.opacity(0.86), in: Capsule())
        .overlay(Capsule().strokeBorder(Brand.hairline))
        .accessibilityIdentifier("driver-dynamics-summary")
    }

    private func portraitDistanceSummary(_ state: VehicleState) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if modules.contains(.odometer) {
                landscapeDistanceChip(title: L("Odometer"),
                                      value: units.distance(km: state.odometer, digits: 0),
                                      icon: "gauge.with.dots.needle.50percent",
                                      tint: Brand.action,
                                      identifier: "driver-odometer")
                }
                if modules.contains(.tripDistance) {
                landscapeDistanceChip(title: L("This trip"),
                                      value: units.distance(km: tripDistanceKm ?? 0, digits: 1),
                                      icon: "road.lanes",
                                      tint: Brand.signature,
                                      identifier: "driver-trip-distance")
                }
            }
            if modules.contains(.averageConsumption) || modules.contains(.lastTripConsumption)
                || modules.contains(.tripCost) {
                HStack(spacing: 8) {
                    consumptionChips
                    if modules.contains(.tripCost) {
                        landscapeDistanceChip(title: L("Trip cost"),
                                              value: units.money(currentTripCost),
                                              icon: "creditcard.fill",
                                              tint: Brand.warning,
                                              identifier: "driver-current-trip-cost")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func landscape(_ state: VehicleState, size: CGSize) -> some View {
        let mapBleed = min(72, max(40, size.height * 0.16))
        return ZStack {
            if modules.contains(.map) {
                Color.clear
                    .overlay {
                        DriverFollowingMap(state: state,
                                           usesPhoneFallback: usesPhoneFallback,
                                           weatherAttribution: phoneTelemetry.weatherAttribution,
                                           layout: .landscape,
                                           zoomFactor: mapZoomFactor,
                                           overlayTrailingInset: mapBleed + 14,
                                           overlayBottomInset: mapBleed
                                               + (modules.contains(.route)
                                                  && state.activeRouteDestination != nil ? 94 : 14))
                            .frame(width: size.width + (mapBleed * 2),
                                   height: size.height + (mapBleed * 2))
                            .overlay {
                                LinearGradient(
                                    stops: [
                                        .init(color: driverBackground.opacity(0.58), location: 0),
                                        .init(color: driverBackground.opacity(0.34), location: 0.38),
                                        .init(color: driverBackground.opacity(0.10), location: 0.70),
                                        .init(color: driverBackground.opacity(0.18), location: 1)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .allowsHitTesting(false)
                            }
                            .overlay {
                                LinearGradient(colors: [driverBackground.opacity(0.50), .clear,
                                                        driverBackground.opacity(0.36)],
                                               startPoint: .top, endPoint: .bottom)
                                    .allowsHitTesting(false)
                            }
                    }
            } else {
                RadialGradient(colors: [Brand.action.opacity(0.14), .clear],
                               center: .center, startRadius: 0, endRadius: size.width * 0.48)
            }

            if modules.contains(.speed) || modules.contains(.gear) {
                landscapeSpeedFocus(state, size: size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            if modules.contains(.route), state.activeRouteDestination != nil {
                landscapeRouteSummary(state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }

            landscapeDistanceSummary(state)
                .frame(width: min(384, size.width * 0.47))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

            VStack(spacing: 6) {
                consumptionChips
                landscapeDynamicsChips(state)
                if modules.contains(.tripCost) {
                    landscapeDistanceChip(title: L("Trip cost"),
                                          value: units.money(currentTripCost),
                                          icon: "creditcard.fill", tint: Brand.warning,
                                          identifier: "driver-current-trip-cost")
                }
            }
            .frame(width: (min(384, size.width * 0.47) - 22) / 2)
            .padding(.leading, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            if modules.contains(.map) && modules.contains(.mapZoom) {
                mapZoomControls
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 5)
                    .padding(.bottom, 7)
                    .zIndex(50)
            }
        }
        .overlay(alignment: .top) {
            landscapeTopRail(state)
        }
        .animation(.smooth(duration: 0.35), value: modules)
    }

    @ViewBuilder
    private func landscapeDynamicsChips(_ state: VehicleState) -> some View {
        let motion = env.live.motion.snapshot
        if modules.contains(.power) && !usesPhoneFallback {
            landscapeDistanceChip(title: L("Power & regeneration"),
                                  value: units.power(kw: motion.powerKw ?? state.power, digits: 0),
                                  icon: "bolt.fill", tint: Brand.action,
                                  identifier: "driver-power")
        }
        if modules.contains(.motion) {
            let acceleration = allowsPhoneTelemetry && phoneTelemetry.isSpeedFresh(at: now)
                ? phoneTelemetry.accelerationMetersPerSecondSquared
                : (motion.isFresh(at: now) ? motion.accelerationMetersPerSecondSquared : nil)
            landscapeDistanceChip(title: L("Estimated motion"),
                                  value: acceleration.map { "\(units.number($0, digits: 2, signed: true)) m/s²" } ?? "—",
                                  icon: "waveform.path.ecg", tint: Brand.action,
                                  identifier: "driver-motion")
        }
    }

    private func landscapeTopRail(_ state: VehicleState) -> some View {
        HStack(spacing: 9) {
            headerIdentity
            if modules.contains(.connection) {
                Circle()
                    .fill(usesPhoneFallback ? Brand.warning : env.live.status.color)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(usesPhoneFallback ? L("Data delayed") : env.live.status.label)
                    .accessibilityIdentifier("driver-connection-indicator")
            }

            if modules.contains(.environment) || modules.contains(.outsideTemperature) {
                temperatureMetric(state)
            }
            if modules.contains(.battery) {
                landscapeMetric(state.batteryLevel.map { "\($0)%" } ?? "—", icon: "battery.75percent",
                                tint: Brand.online, identifier: "driver-battery")
            }
            if modules.contains(.range), let rangeCounter = landscapeRangeCounter(state) {
                landscapeMetric(rangeCounter, icon: "gauge.with.dots.needle.50percent",
                                tint: Brand.action, identifier: "driver-range-counter")
            }
            Spacer(minLength: 8)

            if modules.contains(.alerts) {
                landscapeAlerts(state)
            }
            appearanceButton
            bluetoothSettingsButton
                .padding(.leading, 7)
            closeButton
                .padding(.leading, 2)
                .offset(x: 9)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private func landscapeMetric(_ value: String, icon: String, tint: Color, identifier: String) -> some View {
        Label {
            Text(value).font(.system(size: metricValueSize, weight: .semibold))
        } icon: {
            Image(systemName: icon)
        }
            .font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1)
            .foregroundStyle(Brand.textPrimary)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(.ultraThinMaterial.opacity(0.82), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.34)))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier)
    }

    private func temperatureMetric(_ state: VehicleState) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "thermometer.medium")
                .foregroundStyle(Brand.textPrimary)
            if modules.contains(.environment) {
                temperatureValue("Int.", value: state.insideTemp)
            }
            if modules.contains(.environment) && modules.contains(.outsideTemperature) {
                Divider().frame(height: 19)
            }
            if modules.contains(.outsideTemperature) {
                temperatureValue("Ext.", value: state.outsideTemp)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(.ultraThinMaterial.opacity(0.82), in: Capsule())
        .overlay(Capsule().strokeBorder(Brand.textPrimary.opacity(0.34)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([
            modules.contains(.environment) ? "\(L("Inside")) \(units.temperature(c: state.insideTemp))" : nil,
            modules.contains(.outsideTemperature) ? "\(L("Outside")) \(units.temperature(c: state.outsideTemp))" : nil
        ].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("driver-temperature")
    }

    private func temperatureValue(_ title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: -1) {
            Text(title)
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .lineLimit(1)
                .tracking(0.5)
                .foregroundStyle(Brand.textTertiary)
            Text(units.temperature(c: value))
                .font(.system(size: temperatureValueSize, weight: .bold)).monospacedDigit().lineLimit(1)
                .foregroundStyle(Brand.textPrimary)
        }
    }

    /// TeslaMate reports the selected range at the current state of charge, but not the same
    /// range normalized to 100%. Scaling the two readings together produces a useful glanceable
    /// "remaining / full" estimate without inventing a fixed factory-range value.
    private func landscapeRangeCounter(_ state: VehicleState) -> String? {
        guard let remaining = state.range(for: units.range), remaining.isFinite, remaining >= 0,
              let batteryLevel = state.batteryLevel ?? state.usableBatteryLevel,
              batteryLevel > 0, batteryLevel <= 100 else { return nil }
        let maximum = remaining * 100 / Double(batteryLevel)
        guard maximum.isFinite, maximum >= remaining, maximum <= 1_500 else { return nil }

        let unit = units.distanceUnit
        let remainingText = units.range(km: remaining)
            .replacingOccurrences(of: " \(unit)", with: "")
        return "\(remainingText) / \(units.range(km: maximum))"
    }

    @ViewBuilder
    private func landscapeAlerts(_ state: VehicleState) -> some View {
        if state.anyOpeningOpen {
            Label(L("Opening detected"), systemImage: "door.left.hand.open")
                .driverLandscapeAlert()
        } else if state.locked == false {
            Label(L("Unlocked"), systemImage: "lock.open.fill")
                .driverLandscapeAlert()
        } else if let warning = tireWarning(state) {
            Label(warning, systemImage: "exclamationmark.tirepressure")
                .driverLandscapeAlert()
        }
    }

    private func tireWarning(_ state: VehicleState) -> String? {
        let values: [(String, Double?, Bool)] = [
            ("FL", state.tpmsPressureFL, state.tpmsSoftWarningFL == true),
            ("FR", state.tpmsPressureFR, state.tpmsSoftWarningFR == true),
            ("RL", state.tpmsPressureRL, state.tpmsSoftWarningRL == true),
            ("RR", state.tpmsPressureRR, state.tpmsSoftWarningRR == true)
        ]
        guard let warning = values.first(where: { $0.2 }) else { return nil }
        return "\(warning.0) \(units.pressure(bar: warning.1))"
    }

    private func landscapeSpeedFocus(_ state: VehicleState, size: CGSize) -> some View {
        let reading = resolvedSpeed(for: state)
        let raw = units.speed(kmh: reading?.speedKmh)
        let number = raw.replacingOccurrences(of: " \(units.speedUnit)", with: "")
        let points = min(max(config.speedScale.points + 8, 92), min(140, size.height * 0.35))
        let diameter = min(310, size.height - 128)
        return ZStack {
            if !isDayMode { Circle()
                .fill(
                    RadialGradient(colors: [Color.black.opacity(0.43), Color.black.opacity(0.27),
                                            driverBackground.opacity(0.12)],
                                   center: .center, startRadius: 18, endRadius: min(160, size.height * 0.38))
                )
                .overlay(Circle().strokeBorder(Color.white.opacity(0.11), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.38), radius: 20)
                .accessibilityIdentifier("driver-speed-dial")
            }

            if modules.contains(.speed) {
                VStack(spacing: -6) {
                    Text(number)
                        .font(.system(size: points, weight: .medium, design: .rounded))
                        .monospacedDigit().contentTransition(.numericText())
                        .minimumScaleFactor(0.62).lineLimit(1)
                        .frame(width: min(260, size.width * 0.31), alignment: .center)
                        .accessibilityIdentifier("driver-speed-value")
                    Text(units.speedUnit)
                        .font(.headline.weight(.medium))
                        .foregroundStyle(Brand.textTertiary)
                        .padding(.top, 7)
                    if modules.contains(.speedActivity) {
                        DriverSpeedActivityLine(speedKmh: reading?.speedKmh ?? 0, compact: false)
                            .frame(width: 148)
                            .padding(.top, 12)
                    }
                    speedHealthIndicator(reading)
                        .padding(.top, 8)
                }
            }
            if modules.contains(.gear) {
                DriverCircularTransmissionRail(value: state.shiftState?.rawValue, diameter: diameter)
            }
        }
        .frame(width: diameter, height: diameter)
        .offset(y: -4)
    }

    @ViewBuilder
    private func landscapeRouteSummary(_ state: VehicleState) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            Label(state.activeRouteDestination ?? "", systemImage: "location.fill")
                .font(.headline.weight(.bold)).lineLimit(1)
            HStack(spacing: 10) {
                Text(units.distance(km: state.activeRouteMilesToArrival.map { $0 * 1.609344 }, digits: 1))
                if let minutes = state.activeRouteMinutesToArrival { Text("\(Int(minutes.rounded())) min") }
                if let soc = state.activeRouteEnergyAtArrival { Text("\(soc)%") }
            }
            .font(.system(size: metricValueSize, weight: .semibold)).monospacedDigit().foregroundStyle(Brand.textSecondary)
        }
        .foregroundStyle(Brand.textPrimary)
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(.ultraThinMaterial.opacity(0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Brand.hairline))
        .frame(maxWidth: 270, alignment: .trailing)
        .padding(.trailing, modules.contains(.map) ? 62 : 16).padding(.bottom, 13)
        .accessibilityIdentifier("driver-route-summary")
    }

    private func landscapeDistanceSummary(_ state: VehicleState) -> some View {
        HStack(spacing: 6) {
                if modules.contains(.odometer) {
                landscapeDistanceChip(title: L("Odometer"),
                                      value: units.distance(km: state.odometer, digits: 0),
                                      icon: "gauge.with.dots.needle.50percent",
                                      tint: Brand.action,
                                      identifier: "driver-odometer")
                }
                if modules.contains(.tripDistance) {
                landscapeDistanceChip(title: L("This trip"),
                                      value: units.distance(km: tripDistanceKm ?? 0, digits: 1),
                                      icon: "road.lanes",
                                      tint: Brand.signature,
                                      identifier: "driver-trip-distance")
                }
        }
        .padding(.leading, 16)
        .padding(.bottom, 13)
    }

    @ViewBuilder
    private var consumptionChips: some View {
        if modules.contains(.averageConsumption) {
            consumptionChip(title: L("Avg consumption"),
                            value: averageConsumptionWhPerKm,
                            icon: "leaf.fill",
                            identifier: "driver-average-consumption")
        }
        if modules.contains(.lastTripConsumption) {
            consumptionChip(title: L("This trip avg"),
                            value: currentTripConsumptionWhPerKm,
                            icon: "bolt.fill",
                            identifier: "driver-current-trip-consumption")
        }
    }

    private func consumptionChip(title: String, value: Double?, icon: String,
                                 identifier: String) -> some View {
        Button {
            UnitToggle.consumption(env)
        } label: {
            landscapeDistanceChip(title: title,
                                  value: units.consumption(whPerKm: value),
                                  icon: icon,
                                  tint: Brand.action,
                                  identifier: identifier)
        }
        .buttonStyle(.plain)
    }

    private func landscapeDistanceChip(title: String, value: String, icon: String,
                                       tint: Color, identifier: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 27, height: 27)
                .background(tint.opacity(0.92), in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(title.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.7)
                    .lineLimit(1)
                    .foregroundStyle(Brand.textSecondary)
                Text(value)
                    .font(.system(size: metricValueSize, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .monospacedDigit()
                    .foregroundStyle(Brand.textPrimary)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 44)
        .background(.ultraThinMaterial.opacity(0.88), in: Capsule())
        .overlay {
            Capsule().fill(tint.opacity(0.13))
            Capsule().strokeBorder(tint.opacity(0.54), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func statusStrip(_ state: VehicleState, landscape: Bool) -> some View {
        Group {
            if landscape {
                HStack(spacing: 9) {
                    logo(width: 58)
                    temperatureBadge(state)
                    tireBadges(state, compact: true)
                    Spacer(minLength: 2)
                    distanceBadge(title: L("Odometer"), value: units.distance(km: state.odometer, digits: 0),
                                  icon: "gauge.with.dots.needle.50percent", tint: Brand.action,
                                  identifier: "driver-odometer", compact: true)
                    distanceBadge(title: L("This trip"), value: units.distance(km: tripDistanceKm, digits: 1),
                                  icon: "road.lanes", tint: Brand.signature,
                                  identifier: "driver-trip-distance", compact: true)
                    connectionAndTime
                    bluetoothSettingsButton
                    closeButton
                }
            } else {
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        logo(width: 68)
                        Text(state.displayName ?? "Tesla")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Brand.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        temperatureBadge(state)
                        connectionAndTime
                        bluetoothSettingsButton
                        closeButton
                    }
                    tireBadges(state, compact: false)
                    HStack(spacing: 8) {
                        distanceBadge(title: L("Odometer"), value: units.distance(km: state.odometer, digits: 0),
                                      icon: "gauge.with.dots.needle.50percent", tint: Brand.action,
                                      identifier: "driver-odometer", compact: false)
                        distanceBadge(title: L("This trip"), value: units.distance(km: tripDistanceKm, digits: 1),
                                      icon: "road.lanes", tint: Brand.signature,
                                      identifier: "driver-trip-distance", compact: false)
                    }
                }
            }
        }
        .padding(.horizontal, landscape ? 12 : 10).padding(.vertical, landscape ? 7 : 9)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Brand.hairline))
    }

    private func logo(width: CGFloat) -> some View {
        Image("Logo").renderingMode(.template).resizable().scaledToFit()
            .frame(width: width, height: 21).foregroundStyle(Brand.signature)
    }

    private func temperatureBadge(_ state: VehicleState) -> some View {
        Label("\(units.temperature(c: state.insideTemp)) · \(units.temperature(c: state.outsideTemp))",
              systemImage: "thermometer.medium")
            .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(Brand.textPrimary)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Brand.elevatedSurface, in: Capsule())
            .accessibilityLabel("\(L("Inside")) \(units.temperature(c: state.insideTemp)), \(L("Outside")) \(units.temperature(c: state.outsideTemp))")
            .accessibilityIdentifier("driver-temperature")
    }

    private var connectionAndTime: some View {
        HStack(spacing: 7) {
            if usesPhoneFallback {
                Image(systemName: "iphone").accessibilityIdentifier("driver-phone-fallback")
            }
            Circle().fill(usesPhoneFallback ? Brand.danger : env.live.status.color)
                .frame(width: 8, height: 8)
                .accessibilityLabel(usesPhoneFallback ? L("TeslaMate disconnected") : env.live.status.label)
                .accessibilityIdentifier("driver-connection-indicator")
            Text(AppDate.shortTime(now)).monospacedDigit()
        }
        .font(.caption.weight(.semibold)).foregroundStyle(Brand.textSecondary)
    }

    private func tireBadges(_ state: VehicleState, compact: Bool) -> some View {
        HStack(spacing: compact ? 5 : 7) {
            tireBadge("FL", pressure: state.tpmsPressureFL, warning: state.tpmsSoftWarningFL == true,
                      identifier: "driver-tire-fl", compact: compact)
            tireBadge("FR", pressure: state.tpmsPressureFR, warning: state.tpmsSoftWarningFR == true,
                      identifier: "driver-tire-fr", compact: compact)
            tireBadge("RL", pressure: state.tpmsPressureRL, warning: state.tpmsSoftWarningRL == true,
                      identifier: "driver-tire-rl", compact: compact)
            tireBadge("RR", pressure: state.tpmsPressureRR, warning: state.tpmsSoftWarningRR == true,
                      identifier: "driver-tire-rr", compact: compact)
        }
        .frame(maxWidth: compact ? nil : .infinity)
    }

    private func tireBadge(_ label: String, pressure: Double?, warning: Bool,
                           identifier: String, compact: Bool) -> some View {
        VStack(spacing: 0) {
            Text(label).font(.system(size: compact ? 8 : 9, weight: .bold, design: .rounded))
            Text(units.pressure(bar: pressure))
                .font(.system(size: compact ? 9 : 11, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }
        .foregroundStyle(warning ? Brand.warning : Brand.textSecondary)
        .padding(.horizontal, compact ? 5 : 7).padding(.vertical, compact ? 3 : 5)
        .frame(maxWidth: compact ? nil : .infinity)
        .background((warning ? Brand.warning : Brand.elevatedSurface).opacity(warning ? 0.14 : 1), in: Capsule())
        .overlay(Capsule().strokeBorder(warning ? Brand.warning.opacity(0.55) : Brand.hairline))
        .accessibilityLabel("\(label), \(units.pressure(bar: pressure))")
        .accessibilityIdentifier(identifier)
    }

    private func distanceBadge(title: String, value: String, icon: String, tint: Color,
                               identifier: String, compact: Bool) -> some View {
        HStack(spacing: compact ? 5 : 8) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: compact ? 8 : 10, weight: .semibold))
                    .foregroundStyle(Brand.textSecondary)
                Text(value).font(.system(size: compact ? 10 : 13, weight: .bold, design: .rounded))
                    .monospacedDigit().foregroundStyle(Brand.textPrimary).lineLimit(1)
            }
        }
        .padding(.horizontal, compact ? 7 : 10).padding(.vertical, compact ? 4 : 7)
        .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.45)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func speedCluster(_ state: VehicleState, compact: Bool) -> some View {
        let reading = resolvedSpeed(for: state)
        let raw = units.speed(kmh: reading?.speedKmh)
        let number = raw.replacingOccurrences(of: " \(units.speedUnit)", with: "")
        let points = compact ? min(config.speedScale.points, 76) : config.speedScale.points
        return ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Brand.surface)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Brand.action.opacity(0.10), .clear, Brand.signature.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(spacing: compact ? -5 : -8) {
                Text(number)
                    .font(.system(size: points, weight: .medium, design: .rounded))
                    .monospacedDigit().contentTransition(.numericText())
                    .minimumScaleFactor(0.65).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityIdentifier("driver-speed-value")
                Text(units.speedUnit)
                    .font((compact ? Font.subheadline : Font.headline).weight(.medium))
                    .foregroundStyle(Brand.textTertiary)
                    .padding(.top, compact ? 3 : 5)
                DriverSpeedActivityLine(speedKmh: reading?.speedKmh ?? 0, compact: compact)
                    .padding(.top, compact ? 8 : 12)
            }
            .padding(.horizontal, compact ? 46 : 64)

            VStack {
                HStack {
                    Text(L("Speed").uppercased())
                        .font(.system(size: compact ? 8 : 10, weight: .bold, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(Brand.textTertiary)
                    Spacer()
                }
                Spacer()
                HStack {
                    speedHealthIndicator(reading)
                    Spacer()
                }
            }
            .padding(compact ? 10 : 14)

            HStack {
                Spacer()
                DriverCircularTransmissionRail(value: state.shiftState?.rawValue,
                                                diameter: compact ? 120 : 160)
                    .frame(width: compact ? 120 : 160, height: compact ? 120 : 160)
            }
            .padding(.trailing, compact ? 9 : 13)
        }
        .frame(maxWidth: .infinity)
        .frame(height: compact ? 132 : 176)
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Brand.hairline))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder
    private func speedHealthIndicator(_ reading: DriverResolvedSpeed?) -> some View {
        if reading == nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption.weight(.bold)).foregroundStyle(Brand.warning)
                .accessibilityLabel(L("Data delayed"))
                .accessibilityIdentifier("driver-speed-delayed")
        } else if reading?.isReducedAccuracy == true {
            Image(systemName: "location.slash.fill")
                .font(.caption.weight(.bold)).foregroundStyle(Brand.warning)
                .accessibilityLabel(L("GPS accuracy reduced"))
                .accessibilityIdentifier("driver-speed-reduced-accuracy")
        }
    }

    private func dynamicsPanel(_ state: VehicleState, compact: Bool = false) -> some View {
        let motion = env.live.motion.snapshot
        return VStack(spacing: compact ? 6 : 10) {
            if modules.contains(.power) && !usesPhoneFallback {
                DriverBipolarBar(value: motion.powerKw ?? state.power ?? 0, range: -80...180,
                                 leadingColor: Brand.online, trailingColor: Brand.action)
                HStack {
                    Label(L("Regeneration"), systemImage: "arrow.down.left.circle.fill")
                    Spacer()
                    Text(units.power(kw: motion.powerKw ?? state.power, digits: 0)).foregroundStyle(Brand.textPrimary)
                    Spacer()
                    Label(L("Power"), systemImage: "bolt.fill")
                }
                .font((compact ? Font.caption2 : Font.caption).weight(.semibold)).foregroundStyle(Brand.textTertiary)
            }
            if modules.contains(.motion) || (usesPhoneFallback && modules.contains(.power)) {
                let usePhoneMotion = allowsPhoneTelemetry && phoneTelemetry.isSpeedFresh(at: now)
                let acceleration = usePhoneMotion
                    ? phoneTelemetry.accelerationMetersPerSecondSquared
                    : (motion.isFresh(at: now) ? motion.accelerationMetersPerSecondSquared : nil)
                if modules.contains(.power) && !usesPhoneFallback { Divider().overlay(Brand.hairline) }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(acceleration.map { $0 < -0.08 ? L("Estimated deceleration") : L("Estimated acceleration") } ?? L("Estimated motion"))
                            .font(compact ? .caption2 : .caption).foregroundStyle(Brand.textTertiary)
                        Text(acceleration.map { "\(units.number($0, digits: 2, signed: true)) m/s²" } ?? "—")
                            .font((compact ? Font.headline : Font.title3).weight(.semibold)).monospacedDigit()
                    }
                    Spacer()
                    Image(systemName: acceleration == nil ? "waveform.slash" : "waveform.path.ecg")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(acceleration == nil ? Brand.warning : Brand.online)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(compact ? 10 : 14)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Brand.hairline))
    }

    private func routePanel(_ state: VehicleState, compact: Bool = false) -> some View {
        HStack(spacing: 14) {
            if modules.contains(.battery) {
                VStack(spacing: 2) {
                    Image(systemName: "battery.75percent").foregroundStyle(Brand.online)
                    Text(state.batteryLevel.map { "\($0)%" } ?? "—").font(.title2.weight(.semibold)).monospacedDigit()
                    Text(units.range(km: state.range(for: units.range))).font(.caption).foregroundStyle(Brand.textTertiary)
                }
                .frame(minWidth: 76)
            }
            if modules.contains(.battery) && modules.contains(.route) {
                Divider().frame(height: compact ? 64 : 96)
            }
            if modules.contains(.route) {
                VStack(alignment: .leading, spacing: 5) {
                    if let destination = state.activeRouteDestination, !usesPhoneFallback {
                        Label(destination, systemImage: "location.fill")
                            .font(.headline.weight(.semibold)).lineLimit(1)
                        if compact {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 9) {
                                    Text(units.distance(km: state.activeRouteMilesToArrival.map { $0 * 1.609344 }, digits: 1))
                                    if let minutes = state.activeRouteMinutesToArrival { Text("\(Int(minutes.rounded())) min") }
                                    if let arrival = state.activeRouteMinutesToArrival.map({ Date().addingTimeInterval($0 * 60) }) {
                                        Text(units.time(arrival))
                                    }
                                }
                                if let soc = state.activeRouteEnergyAtArrival { Text("\(soc)% \(L("on arrival"))") }
                            }
                            .font(.caption.weight(.medium)).foregroundStyle(Brand.textSecondary)
                        } else {
                            HStack(spacing: 12) {
                                Text(units.distance(km: state.activeRouteMilesToArrival.map { $0 * 1.609344 }, digits: 1))
                                if let minutes = state.activeRouteMinutesToArrival { Text("\(Int(minutes.rounded())) min") }
                                if let arrival = state.activeRouteMinutesToArrival.map({ Date().addingTimeInterval($0 * 60) }) {
                                    Text(units.time(arrival))
                                }
                                if let soc = state.activeRouteEnergyAtArrival { Text("\(soc)% \(L("on arrival"))") }
                            }
                            .font(.caption.weight(.medium)).foregroundStyle(Brand.textSecondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Brand.hairline))
    }

    private func footer(_ state: VehicleState) -> some View {
        HStack(spacing: 10) {
            if modules.contains(.environment) {
                Label("\(units.temperature(c: state.insideTemp)) · \(units.temperature(c: state.outsideTemp))",
                      systemImage: "thermometer.medium")
                Label(state.heading.map { "\($0)°" } ?? "—", systemImage: "location.north.fill")
            }
            if modules.contains(.alerts) {
                if state.locked == false { Label(L("Unlocked"), systemImage: "lock.open.fill").foregroundStyle(Brand.warning) }
                if state.anyOpeningOpen { Label(L("Opening detected"), systemImage: "door.left.hand.open").foregroundStyle(Brand.warning) }
            }
            Spacer()
        }
        .font(.caption.weight(.semibold)).foregroundStyle(Brand.textSecondary)
        .padding(.horizontal, 12)
    }

    private func setAwake(_ enabled: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = enabled
        #endif
    }

    private func resolvedSpeed(for state: VehicleState, applyDisplayAdjustment: Bool = true) -> DriverResolvedSpeed? {
        let bluetooth = bluetoothSnapshot?.speedKmh.map {
            DriverSpeedSample(speedKmh: $0,
                              date: bluetoothSnapshot?.date ?? now,
                              source: .vehicleBluetooth,
                              accuracyKmh: nil)
        }
        let phone = allowsPhoneTelemetry ? phoneTelemetry.speedSample(at: now) : nil
        let teslaMate = env.live.currentSpeedSample
        let resolved = DriverSpeedFusion.resolve(bluetooth: bluetooth, phone: phone, teslaMate: teslaMate, at: now,
                                                 mode: config.telemetryMode,
                                                 allowStationaryTeslaMate: !state.isDriving)
        guard applyDisplayAdjustment else { return resolved }
        return DriverSpeedFusion.applyingDisplayAdjustment(
            to: resolved,
            enabled: config.iphoneSpeedAdjustmentEnabled,
            adjustmentKmh: config.iphoneSpeedAdjustmentKmh
        )
    }

    private func updateCurrentTripConsumption(at date: Date) {
        let visibleState = state
        let speed = resolvedSpeed(for: visibleState, applyDisplayAdjustment: false)?.speedKmh
        let power = bluetoothSnapshot?.powerKw
            ?? (usesPhoneFallback ? nil : env.live.currentPowerKw(at: date))
        let moving = visibleState.shiftState == .drive
            || visibleState.shiftState == .reverse
            || (speed ?? 0) > 2
        currentTripConsumption.ingest(isDriving: moving,
                                      speedKmh: speed,
                                      powerKw: power,
                                      at: date)
    }

    private var mapZoomControls: some View {
        VStack(spacing: 0) {
            driverMapZoomButton(systemName: "plus", identifier: "driver-map-zoom-in") {
                mapZoomFactor = DriverMapCameraPolicy.zoomIn(mapZoomFactor)
            }
            Divider().overlay(Color.white.opacity(0.22)).frame(width: 32)
            driverMapZoomButton(systemName: "minus", identifier: "driver-map-zoom-out") {
                mapZoomFactor = DriverMapCameraPolicy.zoomOut(mapZoomFactor)
            }
        }
        .background(Color.black.opacity(0.80), in: Capsule())
        .overlay(Capsule().strokeBorder(Brand.action.opacity(0.68), lineWidth: 1.3))
        .shadow(color: .black.opacity(0.38), radius: 9, y: 3)
    }

    private func driverMapZoomButton(systemName: String,
                                     identifier: String,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

private struct DriverCircularTransmissionRail: View {
    private let positions = ["P", "R", "N", "D"]
    let value: String?
    let diameter: CGFloat

    private var selectedValue: String { value?.uppercased() ?? "" }
    // Keep the whole selector above the activity bar while preserving one shared arc.
    private let angles = [-82.0, -46.0, -10.0, 26.0]

    var body: some View {
        GeometryReader { proxy in
            let outerRadius = min(proxy.size.width, proxy.size.height) * 0.5
            let selectedDiameter = min(34, max(28, diameter * 0.105))
            let trackRadius = max(0, outerRadius - (selectedDiameter * 0.5) - 9)
            let center = CGPoint(x: proxy.size.width * 0.5, y: proxy.size.height * 0.5)

            ZStack {
                ForEach(positions.indices, id: \.self) { index in
                    gear(position: positions[index], angle: angles[index], center: center,
                         trackRadius: trackRadius, badgeDiameter: selectedDiameter)
                }
            }
            .clipShape(Circle())
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.76), value: selectedValue)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(L("Gear")) \(selectedValue.isEmpty ? "—" : selectedValue)")
        .accessibilityIdentifier("driver-gear-badge")
    }

    private func gear(position: String, angle: Double, center: CGPoint,
                      trackRadius: CGFloat, badgeDiameter: CGFloat) -> some View {
        let isSelected = position == selectedValue
        let radians = CGFloat(angle * .pi / 180)
        let point = CGPoint(x: center.x + (cos(radians) * trackRadius),
                            y: center.y + (sin(radians) * trackRadius))
        return ZStack {
            if isSelected {
                Circle()
                    .fill(LinearGradient(colors: [Brand.signature, Brand.action],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: Brand.action.opacity(0.58), radius: 5)
            }
            Text(position)
                .font(.system(size: isSelected ? 16 : 13,
                              weight: isSelected ? .heavy : .semibold,
                              design: .rounded))
                .foregroundStyle(isSelected ? Color.white : Brand.textTertiary)
        }
        .frame(width: badgeDiameter, height: badgeDiameter)
        .position(point)
        .accessibilityIdentifier("driver-gear-\(position.lowercased())")
    }
}

private struct DriverSpeedActivityLine: View {
    let speedKmh: Double
    let compact: Bool

    private var progress: Double { min(max(speedKmh / 160, 0), 1) }

    var body: some View {
        GeometryReader { proxy in
            let activeWidth = max(5, proxy.size.width * progress)
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.elevatedSurface)
                Capsule()
                    .fill(LinearGradient(colors: [Brand.signature, Brand.action],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: activeWidth)
                Circle()
                    .fill(Color.white)
                    .frame(width: compact ? 5 : 6, height: compact ? 5 : 6)
                    .shadow(color: Brand.action.opacity(0.8), radius: 5)
                    .offset(x: max(0, activeWidth - (compact ? 5 : 6)))
            }
        }
        .frame(maxWidth: compact ? 96 : 132)
        .frame(height: compact ? 4 : 5)
        .animation(.linear(duration: 0.22), value: progress)
        .accessibilityHidden(true)
    }
}

private struct DriverBipolarBar: View {
    let value: Double
    let range: ClosedRange<Double>
    let leadingColor: Color
    let trailingColor: Color

    var body: some View {
        GeometryReader { proxy in
            let zero = proxy.size.width * abs(range.lowerBound) / (range.upperBound - range.lowerBound)
            let amount = value >= 0
                ? min(proxy.size.width - zero, value / range.upperBound * (proxy.size.width - zero))
                : min(zero, abs(value / range.lowerBound) * zero)
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.elevatedSurface)
                Capsule().fill(value >= 0 ? trailingColor : leadingColor)
                    .frame(width: max(3, amount))
                    .offset(x: value >= 0 ? zero : zero - amount)
                Rectangle().fill(Brand.textTertiary).frame(width: 2).offset(x: zero)
            }
        }
        .frame(height: 10)
        .animation(.linear(duration: 0.18), value: value)
    }
}

private struct DriverFollowingMap: View {
    enum Layout {
        case portrait
        case landscape
    }

    let state: VehicleState
    let usesPhoneFallback: Bool
    let weatherAttribution: DriverWeatherAttribution?
    let layout: Layout
    let zoomFactor: Double
    let overlayTrailingInset: CGFloat
    let overlayBottomInset: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @State private var camera: MapCameraPosition = .automatic
    @State private var displayedCoordinate: Coordinate?
    @State private var displayedHeading: Double?
    @State private var displayedZoom = 1.0

    var body: some View {
        Map(position: $camera, interactionModes: []) {
            if let coordinate = displayedCoordinate ?? state.coordinate {
                Annotation("", coordinate: coordinate.clLocationCoordinate) {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 30, weight: .black))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(Brand.action)
                        .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 1)
                        .shadow(color: Brand.action.opacity(0.90), radius: 5)
                        .accessibilityLabel(L("Vehicle location"))
                        .accessibilityIdentifier("driver-map-vehicle")
                }
            }
            if let destination = state.routeCoordinate {
                Marker(state.activeRouteDestination ?? L("Destination"), systemImage: "flag.checkered",
                       coordinate: destination.clLocationCoordinate).tint(Brand.signature)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: true))
        .accessibilityIdentifier("driver-map")
        .onAppear { initializePosition() }
        .task(id: CameraKey(state)) {
            await animateToLatestPosition()
        }
        .task(id: zoomFactor) { await animateZoom() }
        .overlay(alignment: .bottomTrailing) {
            if usesPhoneFallback, let weatherAttribution {
                Link(destination: weatherAttribution.legalPageURL) {
                    AsyncImage(url: colorScheme == .dark
                               ? weatherAttribution.darkMarkURL
                               : weatherAttribution.lightMarkURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit()
                        } else {
                            Image(systemName: "cloud.sun.fill").foregroundStyle(.white)
                        }
                    }
                    .frame(width: 86, height: 16)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.black.opacity(0.68), in: Capsule())
                }
                .accessibilityLabel(L("Apple Weather attribution"))
                .padding(.trailing, overlayTrailingInset)
                .padding(.bottom, overlayBottomInset)
            }
        }
    }

    private func initializePosition() {
        displayedZoom = zoomFactor
        displayedCoordinate = state.coordinate
        displayedHeading = Double(state.heading ?? 0)
        updateCamera()
    }

    private func animateZoom() async {
        let start = displayedZoom
        for step in 1...30 {
            do { try await Task.sleep(for: .milliseconds(16)) }
            catch { return }
            let t = Double(step) / 30
            let eased = t * t * (3 - 2 * t)
            displayedZoom = start + (zoomFactor - start) * eased
            updateCamera()
        }
    }

    private func animateToLatestPosition() async {
        guard let target = state.coordinate else {
            displayedCoordinate = nil
            camera = .automatic
            return
        }
        guard let start = displayedCoordinate else {
            displayedCoordinate = target
            displayedHeading = Double(state.heading ?? 0)
            updateCamera()
            return
        }

        let targetHeading = Double(state.heading ?? Int(displayedHeading ?? 0))
        let startHeading = displayedHeading ?? targetHeading
        let headingDelta = ((targetHeading - startHeading + 540).truncatingRemainder(dividingBy: 360)) - 180
        let steps = 24
        for step in 1...steps {
            do { try await Task.sleep(for: .milliseconds(35)) }
            catch { return }
            let fraction = Double(step) / Double(steps)
            displayedCoordinate = DriverMapInterpolation.coordinate(from: start,
                                                                     to: target,
                                                                     fraction: fraction)
            displayedHeading = startHeading + headingDelta * fraction
            updateCamera()
        }
    }

    private func updateCamera() {
        guard let coordinate = displayedCoordinate ?? state.coordinate else {
            camera = .automatic
            return
        }
        let heading = displayedHeading ?? Double(state.heading ?? 0)
        let cameraCenter: CLLocationCoordinate2D
        let distance: CLLocationDistance
        switch layout {
        case .portrait:
            // Keep the vehicle below the raised speed dial in portrait. Moving the camera centre
            // ahead of the vehicle makes the annotation sit in the lower, unobstructed map area.
            cameraCenter = offset(coordinate.clLocationCoordinate,
                                  meters: DriverMapCameraPolicy.offsetMeters(layout: .portrait,
                                                                             zoomFactor: displayedZoom),
                                  bearingDegrees: heading)
            distance = 820 * displayedZoom
        case .landscape:
            cameraCenter = offset(coordinate.clLocationCoordinate,
                                  meters: DriverMapCameraPolicy.offsetMeters(layout: .landscape,
                                                                             zoomFactor: displayedZoom),
                                  bearingDegrees: heading - 90)
            distance = 850 * displayedZoom
        }
        camera = .camera(MapCamera(centerCoordinate: cameraCenter,
                                   distance: distance,
                                   heading: heading,
                                   pitch: 18))
    }

    private func offset(_ coordinate: CLLocationCoordinate2D,
                        meters: CLLocationDistance,
                        bearingDegrees: CLLocationDirection) -> CLLocationCoordinate2D {
        let angularDistance = meters / 6_378_137
        let bearing = bearingDegrees * .pi / 180
        let latitude = coordinate.latitude * .pi / 180
        let longitude = coordinate.longitude * .pi / 180
        let shiftedLatitude = asin(sin(latitude) * cos(angularDistance)
                                   + cos(latitude) * sin(angularDistance) * cos(bearing))
        let shiftedLongitude = longitude + atan2(sin(bearing) * sin(angularDistance) * cos(latitude),
                                                 cos(angularDistance) - sin(latitude) * sin(shiftedLatitude))
        return CLLocationCoordinate2D(latitude: shiftedLatitude * 180 / .pi,
                                      longitude: shiftedLongitude * 180 / .pi)
    }

    private struct CameraKey: Equatable {
        var coordinate: Coordinate?
        var heading: Int?
        init(_ state: VehicleState) { coordinate = state.coordinate; heading = state.heading }
    }
}

enum DriverMapCameraPolicy {
    enum Layout { case portrait, landscape }
    static let minimumZoom = 0.46 * 0.72 * 0.72
    static func zoomIn(_ value: Double) -> Double { max(minimumZoom, value * 0.72) }
    static func zoomOut(_ value: Double) -> Double { min(2.6, value / 0.72) }

    /// Scaling the offset with camera distance keeps the vehicle annotation at the same screen
    /// reference point while zooming. Portrait uses a smaller ratio so the arrow sits higher.
    static func offsetMeters(layout: Layout, zoomFactor: Double) -> CLLocationDistance {
        let safeZoom = min(2.6, max(minimumZoom, zoomFactor.isFinite ? zoomFactor : 1))
        switch layout {
        case .portrait: return 68 * safeZoom
        case .landscape: return 220 * safeZoom
        }
    }
}

enum DriverMapInterpolation {
    static func coordinate(from start: Coordinate,
                           to end: Coordinate,
                           fraction: Double) -> Coordinate {
        let amount = min(1, max(0, fraction))
        return Coordinate(latitude: start.latitude + (end.latitude - start.latitude) * amount,
                          longitude: start.longitude + (end.longitude - start.longitude) * amount)
    }
}

private extension View {
    func driverLandscapeAlert() -> some View {
        font(.caption.weight(.bold))
            .foregroundStyle(Brand.warning)
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Brand.warning.opacity(0.15), in: Capsule())
            .overlay(Capsule().strokeBorder(Brand.warning.opacity(0.46)))
    }
}
