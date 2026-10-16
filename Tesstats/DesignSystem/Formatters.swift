import Foundation

enum ConsumptionUnit: String, Codable, CaseIterable, Sendable {
    case whPerKm, kwhPer100km
    var next: ConsumptionUnit {
        switch self {
        case .whPerKm: .kwhPer100km
        case .kwhPer100km: .whPerKm
        }
    }
}

/// Formatter cache. `NumberFormatter`/`DateFormatter` cost roughly 15–35 µs to build, which is
/// invisible once and very visible when a scrolling list builds three per row per frame. Keyed
/// by everything that affects output, so a cached instance is always safe to reuse.
private enum FormatterCache {
    nonisolated(unsafe) private static var numbers: [String: NumberFormatter] = [:]
    nonisolated(unsafe) private static var dates: [String: DateFormatter] = [:]
    private static let lock = NSLock()

    static func number(locale: Locale, style: NumberFormatter.Style, currency: String?, fractionDigits: Int) -> NumberFormatter {
        let key = "\(locale.identifier)|\(style.rawValue)|\(currency ?? "")|\(fractionDigits)"
        lock.lock(); defer { lock.unlock() }
        if let cached = numbers[key] { return cached }
        let f = NumberFormatter()
        f.numberStyle = style
        f.locale = locale
        if let currency { f.currencyCode = currency }
        f.maximumFractionDigits = fractionDigits
        f.minimumFractionDigits = 0
        numbers[key] = f
        return f
    }

    static func date(locale: Locale, dateStyle: DateFormatter.Style, timeStyle: DateFormatter.Style) -> DateFormatter {
        let key = "\(locale.identifier)|\(dateStyle.rawValue)|\(timeStyle.rawValue)"
        lock.lock(); defer { lock.unlock() }
        if let cached = dates[key] { return cached }
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = dateStyle
        f.timeStyle = timeStyle
        dates[key] = f
        return f
    }

    static func date(locale: Locale, format: String) -> DateFormatter {
        let key = "\(locale.identifier)|fmt|\(format)"
        lock.lock(); defer { lock.unlock() }
        if let cached = dates[key] { return cached }
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = format
        dates[key] = f
        return f
    }
}

extension Date.FormatStyle {
    /// The same style pinned to the in-app language. Swift Charts formats `AxisValueLabel`
    /// values with the style's own locale rather than the environment's, so chart month and
    /// weekday labels stay on the device language unless the style is pinned explicitly.
    var appLanguage: Date.FormatStyle { locale(LanguageManager.locale) }
}

/// Date formatting for places that have no `Units` at hand (services, standalone rows).
/// Unlike `DateFormatter.localizedString(from:…)` these follow the in-app language override,
/// so day headers and timestamps switch language with the rest of the UI.
enum AppDate {
    static func mediumDate(_ date: Date) -> String {
        FormatterCache.date(locale: LanguageManager.locale, dateStyle: .medium, timeStyle: .none).string(from: date)
    }

    static func shortTime(_ date: Date) -> String {
        FormatterCache.date(locale: LanguageManager.locale, dateStyle: .none, timeStyle: .short).string(from: date)
    }
}

/// Unit-aware, locale-friendly formatting driven by the user's preferences.
struct Units: Sendable {
    let distance: UnitsPreference
    let temp: TempUnit
    let range: RangeKind
    let currency: String
    let locale: Locale
    /// Consumption shown as Wh/km or kWh/100 km — flipped by tapping any consumption value.
    let consumptionUnit: ConsumptionUnit
    /// Tyre pressure in psi rather than bar — flipped by tapping any pressure value.
    let pressureIsPsi: Bool

    init(config: ServerConfig) {
        self.distance = config.units
        self.temp = config.temperatureUnit
        self.range = config.rangeKind
        self.currency = config.currencyCode
        self.locale = LanguageManager.resolvedLocale(config.languageCode)
        self.consumptionUnit = config.consumptionUnit
        self.pressureIsPsi = config.pressureIsPsi
    }

    private static let kmPerMile = 1.609344

    private func num(_ value: Double, _ fractionDigits: Int = 0) -> String {
        guard value.isFinite else { return "—" }
        let f = FormatterCache.number(locale: locale, style: .decimal, currency: nil, fractionDigits: fractionDigits)
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.\(fractionDigits)f", value)
    }

    func number(_ value: Double, digits: Int = 0, signed: Bool = false) -> String {
        let formatted = num(value, digits)
        return signed && value > 0 ? "+\(formatted)" : formatted
    }

    func percent(_ value: Double, digits: Int = 0, signed: Bool = false) -> String {
        "\(number(value, digits: digits, signed: signed))%"
    }

    // Distance
    func distance(km: Double?, digits: Int = 1) -> String {
        guard let km else { return "—" }
        return distance == .imperial
            ? "\(num(km / Self.kmPerMile, digits)) mi"
            : "\(num(km, digits)) km"
    }

    func range(km: Double?) -> String { distance(km: km, digits: 0) }

    func speed(kmh: Double?) -> String {
        guard let kmh else { return "—" }
        return distance == .imperial
            ? "\(num(kmh / Self.kmPerMile, 0)) mph"
            : "\(num(kmh, 0)) km/h"
    }

    var speedUnit: String { distance == .imperial ? "mph" : "km/h" }
    var distanceUnit: String { distance == .imperial ? "mi" : "km" }

    /// Consumption in the unit the user last chose by tapping any consumption value.
    func consumption(whPerKm: Double?) -> String {
        consumption(whPerKm: whPerKm, unit: consumptionUnit)
    }

    /// Consumption in a chosen unit (the value the user cycles through with a tap).
    func consumption(whPerKm: Double?, unit: ConsumptionUnit) -> String {
        guard let whPerKm else { return "—" }
        let perUnit = distance == .imperial ? whPerKm * Self.kmPerMile : whPerKm  // Wh per km or mi
        let d = distance == .imperial ? "mi" : "km"
        switch unit {
        case .whPerKm: return "\(num(perUnit, 0)) Wh/\(d)"
        case .kwhPer100km: return "\(num(perUnit / 10, 1)) kWh/100\(d)"
        }
    }

    // Temperature
    func temperature(c: Double?) -> String {
        guard let c else { return "—" }
        return temp == .fahrenheit
            ? "\(num(c * 9 / 5 + 32, 0))°F"
            : "\(num(c, 0))°C"
    }

    // Energy / power / electrical
    func energy(kwh: Double?, digits: Int = 1) -> String {
        guard let kwh else { return "—" }
        return "\(num(kwh, digits)) kWh"
    }
    func power(kw: Double?, digits: Int = 1) -> String {
        guard let kw else { return "—" }
        return "\(num(kw, digits)) kW"
    }
    func volts(_ v: Int?) -> String { v.map { "\($0) V" } ?? "—" }
    func amps(_ a: Int?) -> String { a.map { "\($0) A" } ?? "—" }
    static let barPerPsi = 0.0689476

    func pressure(bar: Double?) -> String {
        guard let bar else { return "—" }
        return pressureIsPsi
            ? "\(num(bar / Self.barPerPsi, 0)) psi"
            : "\(num(bar, 1)) bar"
    }

    // Money
    func money(_ value: Double?) -> String {
        guard let value else { return "—" }
        let f = FormatterCache.number(locale: locale, style: .currency, currency: currency, fractionDigits: 2)
        return f.string(from: NSNumber(value: value)) ?? "\(num(value, 2)) \(currency)"
    }

    // Durations
    func duration(minutes: Int?) -> String {
        guard let minutes else { return "—" }
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
    func duration(hours: Double?) -> String {
        guard let hours, hours.isFinite, hours > 0,
              hours <= Double(Int.max) / 60 else { return "—" }
        return duration(minutes: Int((hours * 60).rounded()))
    }

    // Dates
    func shortDateTime(_ date: Date?) -> String {
        guard let date else { return "—" }
        return FormatterCache.date(locale: locale, dateStyle: .medium, timeStyle: .short).string(from: date)
    }
    func time(_ date: Date?) -> String {
        guard let date else { return "—" }
        return FormatterCache.date(locale: locale, dateStyle: .none, timeStyle: .short).string(from: date)
    }
    func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = RelativeDateTimeFormatter()
        f.locale = locale
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
    func monthYear(_ date: Date) -> String {
        return FormatterCache.date(locale: locale, format: "MMM yy").string(from: date)
    }
    func shortDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return FormatterCache.date(locale: locale, dateStyle: .medium, timeStyle: .none).string(from: date)
    }
}
