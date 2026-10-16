import Foundation
#if os(iOS)
import ActivityKit
#endif

/// App Group shared between the app and the widget/Live-Activity extension (separate process).
enum AppGroup {
    static let identifier = "group.com.tesstats.app"
}

/// Minimal, self-contained snapshot the widgets render. Written by the app on every live
/// update and read by the widget timeline provider. Kept separate from the rich `VehicleState`
/// so the widget target needs none of the app's MQTT / model layer.
struct WidgetSnapshot: Codable, Sendable, Equatable {
    /// Selected vehicle identifier. Optional for snapshots written before the Watch dashboard.
    var carID: Int?
    var carName = "Tesla"
    var stateRaw = "offline"            // online / charging / driving / asleep / offline …
    var batteryLevel = 0
    var usableLevel: Int?
    var rangeKm: Double?
    var isCharging = false
    var chargerPowerKw: Double?
    var chargeLimitSoc: Int?
    var timeToFullHours: Double?
    var odometerKm: Double?
    /// Projected range at 100% for the current pack, preferably from TeslaMateApi battery health.
    var fullRangeKm: Double?
    var locked: Bool?
    var sentryMode: Bool?
    var occupied: Bool?
    var tpmsPressureFL: Double?
    var tpmsPressureFR: Double?
    var tpmsPressureRL: Double?
    var tpmsPressureRR: Double?
    var tpmsSoftWarningFL: Bool?
    var tpmsSoftWarningFR: Bool?
    var tpmsSoftWarningRL: Bool?
    var tpmsSoftWarningRR: Bool?
    var insideTempC: Double?
    var outsideTempC: Double?
    var isClimateOn: Bool?
    var isPreconditioning: Bool?
    var climateKeeperMode: String?
    var batteryHealthPercent: Double?
    var currentCapacityKwh: Double?
    var originalCapacityKwh: Double?
    var originalRangeKm: Double?
    var isImperial = false
    /// Tire-pressure preference is independent from distance units in the iPhone app.
    var pressureIsPsi: Bool?
    /// Effective app language ("es" or "en"). Optional so snapshots written by older
    /// versions remain decodable after upgrading.
    var languageCode: String?
    /// App-selected accent. Optional so snapshots from releases before 5.2.7 still decode.
    var accentColorHex: String?
    var lastUpdated = Date.distantPast
    var lastTripTitle: String?
    var lastTripDistanceKm: Double?
    var lastTripDate: Date?

    static let placeholder: WidgetSnapshot = {
        var s = WidgetSnapshot()
        s.carID = 1
        s.carName = "Tesla"
        s.stateRaw = "charging"
        s.batteryLevel = 72
        s.usableLevel = 71
        s.rangeKm = 358
        s.isCharging = true
        s.chargerPowerKw = 11
        s.chargeLimitSoc = 80
        s.timeToFullHours = 1.2
        s.odometerKm = 28_450
        s.fullRangeKm = 497
        s.locked = true
        s.sentryMode = true
        s.occupied = false
        s.tpmsPressureFL = 2.9
        s.tpmsPressureFR = 2.9
        s.tpmsPressureRL = 3.0
        s.tpmsPressureRR = 2.9
        s.tpmsSoftWarningFL = false
        s.tpmsSoftWarningFR = false
        s.tpmsSoftWarningRL = false
        s.tpmsSoftWarningRR = false
        s.insideTempC = 21.5
        s.outsideTempC = 18
        s.isClimateOn = true
        s.isPreconditioning = false
        s.climateKeeperMode = "off"
        s.batteryHealthPercent = 94
        s.currentCapacityKwh = 70.5
        s.originalCapacityKwh = 75
        s.originalRangeKm = 528
        s.pressureIsPsi = false
        s.languageCode = WidgetLanguage.resolvedCode(nil)
        s.accentColorHex = "3E6AE1"
        s.lastUpdated = Date()
        s.lastTripTitle = WidgetLanguage.localized("Home → Work", code: s.languageCode)
        s.lastTripDistanceKm = 14.2
        s.lastTripDate = Date()
        return s
    }()
}

// MARK: - Unit-aware formatting (no app dependencies)

extension WidgetSnapshot {
    private static let kmPerMile = 1.609344
    var distanceUnit: String { isImperial ? "mi" : "km" }
    var interfaceLocale: Locale { WidgetLanguage.locale(for: languageCode) }

    func rangeString() -> String {
        guard let rangeKm, rangeKm.isFinite else { return "—" }
        let v = isImperial ? rangeKm / Self.kmPerMile : rangeKm
        return "\(WidgetLanguage.number(v, fractionDigits: 0, code: languageCode)) \(distanceUnit)"
    }

    func fullRangeString() -> String {
        distanceString(fullRangeKm, digits: 0)
    }

    func distanceString(_ km: Double?, digits: Int = 1) -> String {
        guard let km, km.isFinite else { return "—" }
        let v = isImperial ? km / Self.kmPerMile : km
        return "\(WidgetLanguage.number(v, fractionDigits: digits, code: languageCode)) \(distanceUnit)"
    }

    var powerString: String {
        guard let chargerPowerKw, chargerPowerKw.isFinite, chargerPowerKw > 0 else { return "—" }
        return "\(WidgetLanguage.number(chargerPowerKw, fractionDigits: 0, code: languageCode)) kW"
    }

    var batteryString: String { "\(batteryLevel)%" }

    func pressureString(_ bar: Double?) -> String {
        guard let bar, bar.isFinite, bar > 0 else { return "—" }
        if pressureIsPsi ?? isImperial {
            return "\(WidgetLanguage.number(bar * 14.5037738, fractionDigits: 0, code: languageCode)) psi"
        }
        return "\(WidgetLanguage.number(bar, fractionDigits: 1, code: languageCode)) bar"
    }

    func temperatureString(_ celsius: Double?) -> String {
        guard let celsius, celsius.isFinite else { return "—" }
        let value = isImperial ? celsius * 9 / 5 + 32 : celsius
        return "\(WidgetLanguage.number(value, fractionDigits: 0, code: languageCode))°\(isImperial ? "F" : "C")"
    }

    static func timeString(hours: Double?, languageCode: String? = nil) -> String {
        guard let hours, hours.isFinite, hours > 0,
              hours <= Double(Int.max) / 60 else { return "—" }
        let mins = Int((hours * 60).rounded())
        return mins >= 60 ? "\(mins / 60)h \(mins % 60)m" : "\(mins)m"
    }
}

/// Language resolution shared by the app extensions. The selected app language travels in
/// each snapshot; older snapshots and first-run placeholders follow the same es/otherwise-en
/// policy as the main application.
enum WidgetLanguage {
    static func resolvedCode(_ code: String?, preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        if let code, !code.isEmpty {
            let normalized = code.lowercased()
            return normalized == "es" || normalized.hasPrefix("es-") ? "es" : "en"
        }
        let system = preferredLanguages.first?.lowercased() ?? "en"
        return system == "es" || system.hasPrefix("es-") ? "es" : "en"
    }

    static func locale(for code: String?) -> Locale {
        Locale(identifier: resolvedCode(code))
    }

    static func localized(_ key: String.LocalizationValue, code: String?) -> String {
        let resolved = resolvedCode(code)
        let bundle = Bundle.main.path(forResource: resolved, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        return String(localized: key, bundle: bundle)
    }

    static func number(_ value: Double, fractionDigits: Int, code: String?) -> String {
        guard value.isFinite else { return "—" }
        let formatter = NumberFormatter()
        formatter.locale = locale(for: code)
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

// MARK: - App Group store

struct WidgetSharedStore {
    private let defaults: UserDefaults?
    private let key = "tesstats.widget.snapshot"

    init() { defaults = UserDefaults(suiteName: AppGroup.identifier) }

    func save(_ snapshot: WidgetSnapshot) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    func load() -> WidgetSnapshot? {
        guard let defaults, let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func clear() { defaults?.removeObject(forKey: key) }
}

// MARK: - Live Activity attributes

#if os(iOS)
/// Live Activity describing an in-progress charging session. Read-only — it only mirrors what
/// TeslaMate reports and never controls the car.
struct ChargingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var batteryLevel: Int
        var chargeLimitSoc: Int
        var chargerPowerKw: Double
        var timeToFullHours: Double
        var rangeKm: Double
        var isImperial: Bool
        var isComplete: Bool
        var languageCode: String?
        /// App-selected accent, transported with every update because the extension runs in
        /// a separate process and cannot rely on the app's in-memory `Brand` palette.
        var accentColorHex: String?

        var rangeString: String {
            let v = isImperial ? rangeKm / 1.609344 : rangeKm
            return "\(WidgetLanguage.number(v, fractionDigits: 0, code: languageCode)) \(isImperial ? "mi" : "km")"
        }
        var powerString: String { chargerPowerKw > 0 ? "\(WidgetLanguage.number(chargerPowerKw, fractionDigits: 0, code: languageCode)) kW" : "—" }
        var etaString: String { WidgetSnapshot.timeString(hours: timeToFullHours, languageCode: languageCode) }
        /// 0…1 progress of the current charge toward the target limit.
        var progress: Double {
            let target = max(chargeLimitSoc, batteryLevel, 1)
            return min(1, Double(batteryLevel) / Double(target))
        }
    }

    var carName: String
    /// TeslaMate car id lets the push bridge route updates when an account has several cars.
    /// Optional for compatibility with activities created by earlier builds.
    var carID: Int?
}
#endif
