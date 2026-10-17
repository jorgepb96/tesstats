import Foundation

/// Identifies a vehicle discovered in TeslaMate (`teslamate/cars/<id>/display_name`).
struct CarSummary: Identifiable, Sendable, Codable, Hashable {
    let id: Int            // car_id
    var displayName: String
    var model: String?

    var title: String { displayName.isEmpty ? L("Car \(id)") : displayName }
}

/// Non-secret connection + preference configuration. Passwords are NEVER stored here —
/// they live in the Keychain (`KeychainStore`). This struct is persisted as JSON in
/// UserDefaults; secrets are referenced by account name only.
struct ServerConfig: Codable, Equatable, Sendable {

    // MARK: Server addressing (IP or domain / reverse proxy)
    var serverHost: String = ""          // informational base host (domain or IP)

    // MARK: Live data source
    /// MQTT (real-time push, recommended) or polling TeslaMateApi's `/status` endpoint.
    var liveSource: LiveDataSource = .mqtt
    /// Seconds between `/status` requests in API-only mode.
    var apiPollingSeconds: Int = 15

    // MARK: MQTT
    var mqttHost: String = ""
    var mqttPort: Int = 8883
    var mqttTransport: MQTTTransport = .tls
    var mqttWebsocketPath: String = "/mqtt"
    var mqttUsername: String = ""
    var topicNamespace: String = ""      // optional topic prefix configured in TeslaMate
    var mqttClientID: String = "tesstats-ios"

    // MARK: Reverse proxy Basic Auth (applies to wss handshake and the REST API)
    var usesBasicAuth: Bool = false
    var basicAuthUsername: String = ""

    // MARK: History API (TeslaMateApi)
    var apiBaseURL: String = ""          // e.g. https://teslamate.example.com/api

    // MARK: TLS trust
    /// Trust a self-signed / custom-CA certificate that the user has explicitly accepted.
    var trustCustomCertificate: Bool = false
    /// Optional certificate pinning — base64 SHA-256 of the server cert's public key.
    var pinnedPublicKeySHA256: String = ""
    /// Explicit, user-confirmed opt-in to use a plaintext (non-TLS) channel. Default OFF.
    var allowInsecureTransport: Bool = false

    // MARK: Preferences
    var units: UnitsPreference = .metric
    var temperatureUnit: TempUnit = .celsius
    var rangeKind: RangeKind = .rated
    /// Consumption shown as Wh/km or kWh/100 km. Toggled by tapping any consumption value,
    /// so it is a display preference rather than something buried in Settings.
    var consumptionUnit: ConsumptionUnit = .whPerKm
    /// Tyre pressure shown in psi instead of bar. Toggled by tapping any pressure value.
    var pressureIsPsi: Bool = false
    var currencyCode: String = "EUR"
    var fuelPricePerLiter: Double = 1.70
    var fuelConsumptionLPer100km: Double = 7.0
    /// Average electricity price you pay to charge, per kWh (used when TeslaMate has no cost).
    var chargePricePerKwh: Double = 0.15
    /// Optional per-location price overrides (location name → €/kWh). Applied to sessions at
    /// that place when TeslaMate has no recorded cost, for more accurate cost estimates.
    var chargePricePerKwhByLocation: [String: Double] = [:]
    /// Time-of-use tariff: price bands by time of day (e.g. cheap night rate). When enabled,
    /// unpriced sessions with no location override are costed by time-weighted band prices.
    var tariffEnabled: Bool = false
    /// Pre-plan flat band list. Still honoured when no plan exists so an upgrade keeps pricing.
    var tariffPeriods: [TariffPeriod] = []
    /// Named time-of-use plans (off-peak / standard / peak bands, buy and sell prices).
    var tariffPlans: [TariffPlan] = []
    /// `id` of the plan in use. Empty (or unknown) means "no plan".
    var activeTariffPlanID: String = ""

    // MARK: Push (optional microservice for immediate alerts)
    var pushEnabled: Bool = false
    var pushServiceURL: String = ""        // e.g. https://push.example.com

    /// Show a Live Activity (Lock Screen + Dynamic Island) during a charging session.
    /// Off by default — it's an opt-in convenience.
    var liveActivityEnabled: Bool = false

    var selectedCarID: Int?
    var demoMode: Bool = false

    /// In-app language override: "" (system), "es", or "en".
    var languageCode: String = ""
    /// User-defined order of the Summary (dashboard) cards. Empty = default order.
    /// Superseded by `sectionLayouts[.summary]`; still decoded so existing installs keep the
    /// order they arranged before per-section layouts existed.
    var dashboardCardOrder: [String] = []
    /// Per-screen block order and hidden blocks, keyed by `SectionID.rawValue`.
    var sectionLayouts: [String: SectionLayoutState] = [:]

    // MARK: Appearance
    /// Light, dark or system-following theme (system by default).
    var appearance: AppAppearance = .system
    /// Accent color as a 24-bit RGB hex string without `#` (default Tesla blue).
    var accentColorHex: String = AccentPalette.defaultHex
    /// Distinguishes an explicit user choice from the legacy crimson default during migration.
    var accentColorWasCustomized: Bool = false
    /// Full-screen, read-only instrument-cluster preferences.
    var driverDisplay: DriverDisplayConfiguration = .init()

    // MARK: Derived

    var mqttScheme: String { mqttTransport == .websocket ? "wss" : "mqtts" }

    var hasMQTTConfigured: Bool { !mqttHost.isEmpty }
    var hasAPIConfigured: Bool { !normalizedAPIBaseURL.isEmpty }
    var usesAPIPolling: Bool { liveSource == .api }
    /// True when the selected live source has what it needs to connect.
    var hasLiveSourceConfigured: Bool { usesAPIPolling ? hasAPIConfigured : hasMQTTConfigured }

    static let apiPollingChoices = [10, 15, 30, 60]
    /// Polling interval clamped to a sane range, whatever a restored backup contains.
    var effectiveAPIPollingSeconds: Int { min(300, max(5, apiPollingSeconds)) }

    /// Topic root, honoring an optional namespace prefix.
    var topicRoot: String {
        let ns = topicNamespace.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return ns.isEmpty ? "teslamate/cars" : "\(ns)/teslamate/cars"
    }

    var normalizedAPIBaseURL: String {
        var s = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        // The API field is a URL — be forgiving and default to https:// if no scheme is given
        // (unlike the MQTT host, which must be a bare hostname).
        if !s.isEmpty, !s.lowercased().hasPrefix("http://"), !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        return s
    }

    /// True when every configured channel is encrypted (or insecure has been explicitly allowed).
    var transportIsSecure: Bool {
        if allowInsecureTransport { return true } // user explicitly accepted the risk
        let apiSecure = normalizedAPIBaseURL.isEmpty || normalizedAPIBaseURL.lowercased().hasPrefix("https://")
        return apiSecure // MQTT path always uses TLS/wss in this app
    }

    /// Everything that changes how a value is rendered. Views use it to know when cached,
    /// pre-formatted strings must be rebuilt.
    var unitsSignature: String {
        "\(units.rawValue)|\(temperatureUnit.rawValue)|\(rangeKind.rawValue)|\(currencyCode)|\(languageCode)|\(consumptionUnit.rawValue)|\(pressureIsPsi)"
    }

    /// Everything that affects charge valuation and therefore the cost assigned to a drive.
    /// Stable ordering for dictionaries makes this suitable as a SwiftUI task identity.
    var tripPricingSignature: String {
        let locations = chargePricePerKwhByLocation
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        let legacy = tariffPeriods
            .sorted { $0.startMinute < $1.startMinute }
            .map { "\($0.startMinute)-\($0.endMinute)=\($0.pricePerKwh)" }
            .joined(separator: ",")
        let plans = tariffPlans
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { plan in
                let bands = plan.normalized().bands.map {
                    "\($0.startMinute)-\($0.endMinute)=\($0.buyPricePerKwh)"
                }.joined(separator: ",")
                return "\(plan.id.uuidString):\(bands)"
            }
            .joined(separator: "|")
        return "\(chargePricePerKwh)|\(fuelPricePerLiter)|\(fuelConsumptionLPer100km)|\(tariffEnabled)|\(activeTariffPlanID)|\(locations)|\(legacy)|\(plans)"
    }

    // MARK: Tariff

    /// The plan that prices unrecorded charges: the selected one, or a pre-plan band list
    /// wrapped on the fly so upgrading never silently drops the user's tariff.
    var activeTariff: TariffPlan? {
        guard tariffEnabled else { return nil }
        if let plan = tariffPlans.first(where: { $0.id.uuidString == activeTariffPlanID }) {
            return plan.bands.isEmpty ? nil : plan.normalized()
        }
        guard !tariffPeriods.isEmpty else { return nil }
        return Self.plan(fromLegacy: tariffPeriods).normalized()
    }

    /// Move a pre-plan band list into a real plan, once.
    mutating func migrateLegacyTariffIfNeeded() {
        guard !tariffPeriods.isEmpty, tariffPlans.isEmpty else { return }
        let plan = Self.plan(fromLegacy: tariffPeriods).normalized()
        tariffPlans = [plan]
        if activeTariffPlanID.isEmpty { activeTariffPlanID = plan.id.uuidString }
        tariffPeriods = []
    }

    private static func plan(fromLegacy periods: [TariffPeriod]) -> TariffPlan {
        TariffPlan(name: L("My tariff"),
                   bands: periods
                       .sorted { $0.startMinute < $1.startMinute }
                       .map { TariffBand(kind: .flat, startMinute: $0.startMinute,
                                         endMinute: $0.endMinute, buyPricePerKwh: $0.pricePerKwh) })
    }

    // MARK: Section layouts

    /// The saved arrangement for a screen. Falls back to the pre-existing dashboard order so
    /// an upgrade keeps the cards where the user put them.
    func layout(for section: SectionID) -> SectionLayoutState {
        if let saved = sectionLayouts[section.rawValue] { return saved }
        if section == .summary, !dashboardCardOrder.isEmpty {
            return SectionLayoutState(order: dashboardCardOrder, hidden: [])
        }
        return SectionLayoutState()
    }

    mutating func setLayout(_ layout: SectionLayoutState, for section: SectionID) {
        if layout.isDefault {
            sectionLayouts.removeValue(forKey: section.rawValue)
            if section == .summary { dashboardCardOrder = [] }
        } else {
            sectionLayouts[section.rawValue] = layout
            if section == .summary { dashboardCardOrder = layout.order }
        }
    }

    static let demo: ServerConfig = {
        var c = ServerConfig()
        c.demoMode = true
        c.serverHost = "demo.teslamate.local"
        c.selectedCarID = 1
        return c
    }()
}

// MARK: - Tolerant decoding

private extension KeyedDecodingContainer {
    /// Decode a value, falling back to `fallback` when the key is missing or its type mismatches.
    /// Keeps older persisted configs (written before a field existed) fully loadable.
    func lenient<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

extension ServerConfig {
    /// Custom decoder so that adding a new field never invalidates a user's saved configuration:
    /// every missing key resolves to its default instead of throwing `keyNotFound`. Defined in an
    /// extension to preserve the synthesized memberwise initializer used elsewhere.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        serverHost = c.lenient(.serverHost, serverHost)
        liveSource = c.lenient(.liveSource, liveSource)
        apiPollingSeconds = c.lenient(.apiPollingSeconds, apiPollingSeconds)
        mqttHost = c.lenient(.mqttHost, mqttHost)
        mqttPort = c.lenient(.mqttPort, mqttPort)
        mqttTransport = c.lenient(.mqttTransport, mqttTransport)
        mqttWebsocketPath = c.lenient(.mqttWebsocketPath, mqttWebsocketPath)
        mqttUsername = c.lenient(.mqttUsername, mqttUsername)
        topicNamespace = c.lenient(.topicNamespace, topicNamespace)
        mqttClientID = c.lenient(.mqttClientID, mqttClientID)
        usesBasicAuth = c.lenient(.usesBasicAuth, usesBasicAuth)
        basicAuthUsername = c.lenient(.basicAuthUsername, basicAuthUsername)
        apiBaseURL = c.lenient(.apiBaseURL, apiBaseURL)
        trustCustomCertificate = c.lenient(.trustCustomCertificate, trustCustomCertificate)
        pinnedPublicKeySHA256 = c.lenient(.pinnedPublicKeySHA256, pinnedPublicKeySHA256)
        allowInsecureTransport = c.lenient(.allowInsecureTransport, allowInsecureTransport)
        units = c.lenient(.units, units)
        temperatureUnit = c.lenient(.temperatureUnit, temperatureUnit)
        rangeKind = c.lenient(.rangeKind, rangeKind)
        consumptionUnit = c.lenient(.consumptionUnit, consumptionUnit)
        pressureIsPsi = c.lenient(.pressureIsPsi, pressureIsPsi)
        currencyCode = c.lenient(.currencyCode, currencyCode)
        fuelPricePerLiter = c.lenient(.fuelPricePerLiter, fuelPricePerLiter)
        fuelConsumptionLPer100km = c.lenient(.fuelConsumptionLPer100km, fuelConsumptionLPer100km)
        chargePricePerKwh = c.lenient(.chargePricePerKwh, chargePricePerKwh)
        chargePricePerKwhByLocation = c.lenient(.chargePricePerKwhByLocation, chargePricePerKwhByLocation)
        tariffEnabled = c.lenient(.tariffEnabled, tariffEnabled)
        tariffPeriods = c.lenient(.tariffPeriods, tariffPeriods)
        tariffPlans = c.lenient(.tariffPlans, tariffPlans)
        activeTariffPlanID = c.lenient(.activeTariffPlanID, activeTariffPlanID)
        pushEnabled = c.lenient(.pushEnabled, pushEnabled)
        pushServiceURL = c.lenient(.pushServiceURL, pushServiceURL)
        liveActivityEnabled = c.lenient(.liveActivityEnabled, liveActivityEnabled)
        selectedCarID = (try? c.decodeIfPresent(Int.self, forKey: .selectedCarID)) ?? selectedCarID
        demoMode = c.lenient(.demoMode, demoMode)
        languageCode = c.lenient(.languageCode, languageCode)
        dashboardCardOrder = c.lenient(.dashboardCardOrder, dashboardCardOrder)
        sectionLayouts = c.lenient(.sectionLayouts, sectionLayouts)
        appearance = c.lenient(.appearance, appearance)
        let decodedAccent = c.lenient(.accentColorHex, accentColorHex)
        accentColorWasCustomized = c.lenient(.accentColorWasCustomized, accentColorWasCustomized)
        if !accentColorWasCustomized,
           decodedAccent.caseInsensitiveCompare("B30333") == .orderedSame {
            // Builds before the unified-accent design stored crimson even when the user never
            // made a choice. Move that legacy default to Tesla blue once.
            accentColorHex = AccentPalette.defaultHex
        } else {
            accentColorHex = decodedAccent
        }
        driverDisplay = c.lenient(.driverDisplay, driverDisplay)
    }
}
