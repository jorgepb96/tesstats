import Foundation

/// Persisted, read-only instrument-cluster layout. Defaults deliberately favour a
/// low-distraction screen that can be understood with a short glance.
struct DriverDisplayConfiguration: Codable, Equatable, Sendable {
    var appearance: DriverDisplayAppearance = .followApp
    var modules: [DriverDisplayModule] = DriverDisplayModule.allCases
    var hiddenModules: [DriverDisplayModule] = []
    var speedScale: DriverSpeedScale = .large
    /// Determines which real-time source is allowed to drive the speedometer. Map positioning
    /// still follows the mounted iPhone because the read-only BLE protocol exposes no location.
    var telemetryMode: DriverTelemetryMode = .automatic
    /// Optional visual correction applied only to iPhone GPS readings. Vehicle Bluetooth and
    /// TeslaMate values already come from the car and must not be altered.
    var iphoneSpeedAdjustmentEnabled: Bool = true
    var iphoneSpeedAdjustmentKmh: Double = 2
    /// Fraction of a landscape screen assigned to the map. Clamped by the view to 0.45...0.72.
    var landscapeMapFraction: Double = 0.60
    var suggestWhenDriving: Bool = true
    var keepScreenAwake: Bool = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case appearance, modules, hiddenModules, speedScale, telemetryMode
        case iphoneSpeedAdjustmentEnabled, iphoneSpeedAdjustmentKmh
        case landscapeMapFraction, suggestWhenDriving, keepScreenAwake
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        appearance = (try? values.decodeIfPresent(DriverDisplayAppearance.self, forKey: .appearance)) ?? appearance
        modules = Self.unique((try? values.decodeIfPresent([DriverDisplayModule].self, forKey: .modules)) ?? [])
        hiddenModules = Self.unique((try? values.decodeIfPresent([DriverDisplayModule].self, forKey: .hiddenModules)) ?? hiddenModules)
        // Preserve the visibility of formerly grouped items when loading older layouts.
        for (parent, child) in [(DriverDisplayModule.speed, DriverDisplayModule.gear),
                                (.speed, .speedActivity), (.battery, .range),
                                (.environment, .outsideTemperature)] {
            if !modules.contains(child), hiddenModules.contains(parent),
               !hiddenModules.contains(child) { hiddenModules.append(child) }
        }
        modules = Self.unique(modules + DriverDisplayModule.allCases)
        speedScale = (try? values.decodeIfPresent(DriverSpeedScale.self, forKey: .speedScale)) ?? speedScale
        telemetryMode = (try? values.decodeIfPresent(DriverTelemetryMode.self, forKey: .telemetryMode)) ?? telemetryMode
        iphoneSpeedAdjustmentEnabled = (try? values.decodeIfPresent(Bool.self, forKey: .iphoneSpeedAdjustmentEnabled)) ?? iphoneSpeedAdjustmentEnabled
        if let adjustment = try? values.decodeIfPresent(Double.self, forKey: .iphoneSpeedAdjustmentKmh),
           adjustment.isFinite {
            iphoneSpeedAdjustmentKmh = min(10, max(-10, adjustment))
        }
        landscapeMapFraction = (try? values.decodeIfPresent(Double.self, forKey: .landscapeMapFraction)) ?? landscapeMapFraction
        suggestWhenDriving = (try? values.decodeIfPresent(Bool.self, forKey: .suggestWhenDriving)) ?? suggestWhenDriving
        keepScreenAwake = (try? values.decodeIfPresent(Bool.self, forKey: .keepScreenAwake)) ?? keepScreenAwake
    }

    private static func unique(_ values: [DriverDisplayModule]) -> [DriverDisplayModule] {
        var seen = Set<DriverDisplayModule>()
        return values.filter { seen.insert($0).inserted }
    }

    var visibleModules: [DriverDisplayModule] {
        let hidden = Set(hiddenModules)
        let saved = modules.filter { !hidden.contains($0) }
        let missing = DriverDisplayModule.allCases.filter { !modules.contains($0) && !hidden.contains($0) }
        return saved + missing
    }

}

enum DriverTelemetryMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case bluetooth
    case iphoneAndTeslaMate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: L("Auto")
        case .bluetooth: L("Bluetooth")
        case .iphoneAndTeslaMate: L("iPhone + Tesstats")
        }
    }

    var icon: String {
        switch self {
        case .automatic: "wand.and.stars"
        case .bluetooth: "antenna.radiowaves.left.and.right"
        case .iphoneAndTeslaMate: "iphone.gen3"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            L("Uses stable Bluetooth telemetry when available, then changes to iPhone GPS and TeslaMate without rapid source switching.")
        case .bluetooth:
            L("Uses the vehicle Bluetooth speed only. The map still follows this iPhone because Bluetooth does not provide vehicle location.")
        case .iphoneAndTeslaMate:
            L("Uses iPhone GPS for live speed and position, with TeslaMate as the vehicle-data fallback. Direct Bluetooth stays disconnected.")
        }
    }
}

enum DriverDisplayModule: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case speed, battery, power, motion, averageConsumption, lastTripConsumption, tripCost
    case route, map, environment, alerts
    case gear, speedActivity, range, outsideTemperature, odometer, tripDistance, logo, clock, connection, mapZoom
    var id: String { rawValue }

    var label: String {
        switch self {
        case .speed: L("Speedometer")
        case .battery: L("Battery")
        case .power: L("Power & regeneration")
        case .motion: L("Estimated motion")
        case .averageConsumption: L("Avg consumption")
        case .lastTripConsumption: L("This trip consumption")
        case .tripCost: L("Trip cost")
        case .route: L("Active route")
        case .map: L("Map")
        case .environment: L("Inside")
        case .alerts: L("Alerts")
        case .gear: L("Gear")
        case .speedActivity: L("Speed activity")
        case .range: L("Range")
        case .outsideTemperature: L("Outside")
        case .odometer: L("Odometer")
        case .tripDistance: L("This trip")
        case .logo: L("Logo")
        case .clock: L("Time")
        case .connection: L("Connection")
        case .mapZoom: L("Map zoom")
        }
    }

    var icon: String {
        switch self {
        case .speed: "speedometer"
        case .battery: "battery.75percent"
        case .power: "bolt.fill"
        case .motion: "gauge.with.dots.needle.50percent"
        case .averageConsumption: "leaf.fill"
        case .lastTripConsumption: "bolt.fill"
        case .tripCost: "creditcard.fill"
        case .route: "point.topleft.down.to.point.bottomright.curvepath"
        case .map: "map.fill"
        case .environment: "thermometer.medium"
        case .alerts: "exclamationmark.triangle.fill"
        case .gear: "gearshape"
        case .speedActivity: "waveform.path"
        case .range: "gauge.with.dots.needle.50percent"
        case .outsideTemperature: "thermometer.medium"
        case .odometer: "gauge.with.dots.needle.50percent"
        case .tripDistance: "road.lanes"
        case .logo: "car.side"
        case .clock: "clock"
        case .connection: "antenna.radiowaves.left.and.right"
        case .mapZoom: "plus.magnifyingglass"
        }
    }
}

enum DriverDisplayAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case followApp, light, dark, highContrast
    var id: String { rawValue }
    var label: String {
        switch self {
        case .followApp: L("Follow app")
        case .light: L("Light")
        case .dark: L("Dark")
        case .highContrast: L("High contrast")
        }
    }
}

enum DriverSpeedScale: String, Codable, CaseIterable, Identifiable, Sendable {
    case medium, large, extraLarge
    var id: String { rawValue }
    var label: String {
        switch self {
        case .medium: L("Medium")
        case .large: L("Large")
        case .extraLarge: L("Extra large")
        }
    }
    var points: Double {
        switch self {
        case .medium: 76
        case .large: 104
        case .extraLarge: 132
        }
    }
}
