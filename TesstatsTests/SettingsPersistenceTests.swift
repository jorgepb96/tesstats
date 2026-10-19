import XCTest
@testable import Tesstats

/// `ServerConfig` decodes leniently field by field, so a property that is added but not wired
/// into that decoder silently reverts to its default on every launch. These pin the newer
/// display preferences and the per-screen layouts to a real save/reload cycle.
@MainActor
final class SettingsPersistenceTests: XCTestCase {
    func testUnifiedAccentDefaultsToTeslaBlue() {
        XCTAssertEqual(AccentPalette.defaultHex, "3E6AE1")
        XCTAssertEqual(ServerConfig().accentColorHex, "3E6AE1")
    }

    func testLegacyUntouchedCrimsonMigratesToTeslaBlue() throws {
        let data = Data(#"{"accentColorHex":"B30333"}"#.utf8)
        let config = try JSONDecoder().decode(ServerConfig.self, from: data)
        XCTAssertEqual(config.accentColorHex, AccentPalette.defaultHex)
        XCTAssertFalse(config.accentColorWasCustomized)
    }

    func testExplicitAccentChoiceSurvivesMigrationAndPersistence() throws {
        let data = Data(#"{"accentColorHex":"B30333","accentColorWasCustomized":true}"#.utf8)
        let config = try JSONDecoder().decode(ServerConfig.self, from: data)
        XCTAssertEqual(config.accentColorHex, "B30333")
        XCTAssertTrue(config.accentColorWasCustomized)

        let roundTrip = try JSONDecoder().decode(ServerConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(roundTrip.accentColorHex, "B30333")
        XCTAssertTrue(roundTrip.accentColorWasCustomized)
    }

    func testSupportedLanguagePolicyUsesSpanishOnlyForSpanishUsers() {
        XCTAssertEqual(LanguageManager.resolvedLanguageCode("", preferredLanguages: ["es-ES"]), "es")
        XCTAssertEqual(LanguageManager.resolvedLanguageCode("", preferredLanguages: ["es-419"]), "es")
        XCTAssertEqual(LanguageManager.resolvedLanguageCode("", preferredLanguages: ["en-US"]), "en")
        XCTAssertEqual(LanguageManager.resolvedLanguageCode("", preferredLanguages: ["fr-FR"]), "en")
        XCTAssertEqual(LanguageManager.resolvedLanguageCode("", preferredLanguages: ["de-DE"]), "en")
        XCTAssertEqual(LanguageManager.resolvedLanguageCode("es", preferredLanguages: ["en-US"]), "es")
        XCTAssertEqual(LanguageManager.resolvedLanguageCode("en", preferredLanguages: ["es-ES"]), "en")
        XCTAssertEqual(LanguageManager.resolvedLanguageCode("fr", preferredLanguages: ["es-ES"]), "en")
    }

    func testLanguagePreferencePersists() {
        let suite = "tesstats.language.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        store.config.languageCode = "es"
        store.save()

        XCTAssertEqual(SettingsStore(defaults: defaults).config.languageCode, "es")
    }

    func testRuntimeLanguageOverrideSwitchesLocalizedStrings() {
        let previous = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first ?? ""
        defer { LanguageManager.apply(previous) }

        LanguageManager.apply("es")
        XCTAssertEqual(L("Summary"), "Resumen")
        XCTAssertEqual(L("Charging status"), "Cargando")

        LanguageManager.apply("en")
        XCTAssertEqual(L("Summary"), "Summary")
        XCTAssertEqual(L("Charging status"), "Charging")
    }

    func testCompanionLanguageAndNumberFormattingFollowTheAppOverride() throws {
        var snapshot = WidgetSnapshot.placeholder
        snapshot.languageCode = "es"
        XCTAssertEqual(WidgetLanguage.resolvedCode(snapshot.languageCode, preferredLanguages: ["en-US"]), "es")
        XCTAssertEqual(snapshot.distanceString(14.2), "14,2 km")
        XCTAssertEqual(WidgetLanguage.localized("Charging status", code: snapshot.languageCode), "Cargando")

        snapshot.languageCode = "en"
        XCTAssertEqual(snapshot.distanceString(14.2), "14.2 km")
        XCTAssertEqual(WidgetLanguage.localized("Charging status", code: snapshot.languageCode), "Charging")

        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        legacyObject.removeValue(forKey: "languageCode")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        XCTAssertNil(try JSONDecoder().decode(WidgetSnapshot.self, from: legacyData).languageCode)
    }

    func testCompanionAccentPersistsAndLegacySnapshotsRemainDecodable() throws {
        var snapshot = WidgetSnapshot.placeholder
        snapshot.accentColorHex = "FF453A"

        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(WidgetSnapshot.self, from: encoded).accentColorHex, "FF453A")

        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyObject.removeValue(forKey: "accentColorHex")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        XCTAssertNil(try JSONDecoder().decode(WidgetSnapshot.self, from: legacyData).accentColorHex)
    }

    func testWatchDashboardSnapshotRoundTripsAndFormatsVehicleUnits() throws {
        var snapshot = WidgetSnapshot.placeholder
        snapshot.languageCode = "en"
        snapshot.isImperial = false
        snapshot.fullRangeKm = 497.4
        snapshot.tpmsPressureFL = 2.9
        snapshot.insideTempC = 21.5

        let decoded = try JSONDecoder().decode(WidgetSnapshot.self,
                                               from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.carID, 1)
        XCTAssertEqual(decoded.fullRangeString(), "497 km")
        XCTAssertEqual(decoded.pressureString(decoded.tpmsPressureFL), "2.9 bar")
        XCTAssertEqual(decoded.temperatureString(decoded.insideTempC), "22°C")
        XCTAssertEqual(decoded.locked, true)
        XCTAssertEqual(decoded.sentryMode, true)
        XCTAssertEqual(decoded.batteryHealthPercent, 94)

        snapshot.isImperial = true
        snapshot.pressureIsPsi = true
        XCTAssertEqual(snapshot.pressureString(2.9), "42 psi")
        XCTAssertEqual(snapshot.temperatureString(20), "68°F")
    }

    func testLegacyWatchSnapshotLeavesNewDashboardFieldsEmpty() throws {
        let legacy = Data(#"{"carName":"Tesla","stateRaw":"offline","batteryLevel":50,"isCharging":false,"isImperial":false,"lastUpdated":0}"#.utf8)
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: legacy)

        XCTAssertNil(snapshot.carID)
        XCTAssertNil(snapshot.fullRangeKm)
        XCTAssertNil(snapshot.locked)
        XCTAssertNil(snapshot.tpmsPressureFL)
        XCTAssertNil(snapshot.insideTempC)
        XCTAssertNil(snapshot.batteryHealthPercent)
    }

    func testSettingsStoreRoundTripsDisplayUnitsAndLayouts() throws {
        let suite = "tesstats.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        store.config.consumptionUnit = .kwhPer100km
        store.config.pressureIsPsi = true
        store.config.driverDisplay.hiddenModules = [.odometer, .clock]
        store.config.driverDisplay.appearance = .highContrast
        store.config.driverDisplay.telemetryMode = .iphoneAndTeslaMate
        store.config.driverDisplay.iphoneSpeedAdjustmentEnabled = false
        store.config.driverDisplay.iphoneSpeedAdjustmentKmh = -3
        store.config.setLayout(SectionLayoutState(order: ["map", "list"], hidden: ["totals"]), for: .trips)
        store.save()

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.config.consumptionUnit, .kwhPer100km)
        XCTAssertEqual(reloaded.config.pressureIsPsi, true)
        XCTAssertEqual(reloaded.config.driverDisplay.hiddenModules, [.odometer, .clock])
        XCTAssertEqual(reloaded.config.driverDisplay.appearance, .highContrast)
        XCTAssertEqual(reloaded.config.driverDisplay.telemetryMode, .iphoneAndTeslaMate)
        XCTAssertFalse(reloaded.config.driverDisplay.iphoneSpeedAdjustmentEnabled)
        XCTAssertEqual(reloaded.config.driverDisplay.iphoneSpeedAdjustmentKmh, -3)
        XCTAssertEqual(reloaded.config.layout(for: .trips).order, ["map", "list"])
        XCTAssertEqual(reloaded.config.layout(for: .trips).hidden, ["totals"])
    }

    func testCloudflareAccessTokenIsBuiltOnlyWhenEnabledAndComplete() {
        let (store, cleanup) = isolatedStore()
        defer { cleanup() }

        store.config.cloudflareAccessClientID = " abc123.access\n"
        store.cloudflareAccessClientSecret = "s3cret\n"
        XCTAssertNil(store.cloudflareAccess, "Off by default")

        store.config.usesCloudflareAccess = true
        XCTAssertEqual(store.cloudflareAccess, CloudflareAccessToken(clientID: "abc123.access", clientSecret: "s3cret"))
        XCTAssertEqual(store.makeAPIConfig().cloudflareAccess, store.cloudflareAccess)

        store.config.mqttTransport = .websocket
        XCTAssertEqual(store.makeMQTTConfig().cloudflareAccess, store.cloudflareAccess)
        store.config.mqttTransport = .tls
        XCTAssertNil(store.makeMQTTConfig().cloudflareAccess, "Raw mqtts never passes through Access")

        store.cloudflareAccessClientSecret = ""
        XCTAssertNil(store.cloudflareAccess)
    }

    func testCloudflareAccessSettingsSurviveReloadProfilesAndBackups() throws {
        let (store, cleanup) = isolatedStore()
        defer { cleanup() }

        store.config.usesCloudflareAccess = true
        store.config.cloudflareAccessClientID = "home.access"
        store.cloudflareAccessClientSecret = "home-secret"
        store.save()
        let reloaded = SettingsStore(defaults: store.defaults, keychain: store.keychain)
        XCTAssertTrue(reloaded.config.usesCloudflareAccess)
        XCTAssertEqual(reloaded.config.cloudflareAccessClientID, "home.access")

        store.saveCurrentAsProfile(name: "Home")
        let home = try XCTUnwrap(store.activeProfileID)
        store.config.cloudflareAccessClientID = "garage.access"
        store.cloudflareAccessClientSecret = "garage-secret"
        store.saveCurrentAsProfile(name: "Garage")
        store.switchToProfile(home)
        XCTAssertEqual(store.config.cloudflareAccessClientID, "home.access")
        XCTAssertEqual(store.cloudflareAccessClientSecret, "home-secret")

        let backup = try XCTUnwrap(ConfigBackup.decode(store.makeBackup().encoded()))
        XCTAssertEqual(backup.cloudflareAccessClientSecret, "home-secret")
        store.cloudflareAccessClientSecret = ""
        store.restore(backup)
        XCTAssertEqual(store.cloudflareAccessClientSecret, "home-secret")

        // Backups written before this field existed still restore.
        let legacy = try XCTUnwrap(ConfigBackup.decode(Data(#"{"version":1,"config":{}}"#.utf8)))
        XCTAssertNil(legacy.cloudflareAccessClientSecret)
        XCTAssertFalse(legacy.config.usesCloudflareAccess)
    }

    /// A store whose defaults and Keychain service are private to the test, so secrets never
    /// touch (or get wiped from) the app's real Keychain items.
    private func isolatedStore() -> (SettingsStore, () -> Void) {
        let suite = "tesstats.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let keychain = KeychainStore(service: suite)
        return (SettingsStore(defaults: defaults, keychain: keychain), {
            keychain.deleteAll()
            defaults.removePersistentDomain(forName: suite)
        })
    }

    func testLegacyDriverDisplayDefaultsToStableAutoTelemetryWithoutLosingLayout() throws {
        let data = Data(#"{"preset":"minimal","appearance":"dark","speedScale":"extraLarge","landscapeMapFraction":0.64,"suggestWhenDriving":false,"keepScreenAwake":true}"#.utf8)

        let decoded = try JSONDecoder().decode(DriverDisplayConfiguration.self, from: data)

        XCTAssertEqual(decoded.appearance, .dark)
        XCTAssertEqual(decoded.speedScale, .extraLarge)
        XCTAssertEqual(decoded.landscapeMapFraction, 0.64, accuracy: 0.001)
        XCTAssertEqual(decoded.telemetryMode, .automatic)
        XCTAssertTrue(decoded.iphoneSpeedAdjustmentEnabled)
        XCTAssertEqual(decoded.iphoneSpeedAdjustmentKmh, 2)
    }

    func testCompanionFormattingRejectsNonFiniteValues() {
        var snapshot = WidgetSnapshot.placeholder
        snapshot.fullRangeKm = .infinity
        snapshot.tpmsPressureFL = .nan
        snapshot.insideTempC = .infinity
        snapshot.batteryHealthPercent = .nan

        XCTAssertEqual(snapshot.fullRangeString(), "—")
        XCTAssertEqual(snapshot.pressureString(snapshot.tpmsPressureFL), "—")
        XCTAssertEqual(snapshot.temperatureString(snapshot.insideTempC), "—")
        XCTAssertEqual(WidgetSnapshot.timeString(hours: .infinity), "—")
    }

    func testMainListsCanBeHiddenLikeEveryOtherBlock() {
        let trips = SectionLayout.visible(
            TripsBlock.self,
            layout: SectionLayoutState(order: [], hidden: [TripsBlock.list.rawValue]))
        let charging = SectionLayout.visible(
            ChargingBlock.self,
            layout: SectionLayoutState(order: [], hidden: [ChargingBlock.list.rawValue]))

        XCTAssertFalse(trips.contains(.list))
        XCTAssertFalse(charging.contains(.list))
    }

    func testNewDashboardBlocksKeepTheirDefaultPositionForLegacyLayouts() {
        let legacyOrder: [String] = [
            "battery", "charging", "driving", "route", "location", "climate",
            "security", "sentry", "tpms", "vehicle", "software"
        ]

        let resolved = SectionLayout.resolved(
            DashboardCard.self,
            layout: SectionLayoutState(order: legacyOrder, hidden: []))

        XCTAssertEqual(Array(resolved.prefix(4)), [.overview, .quickStats, .lastDrive, .activity])
        XCTAssertEqual(resolved.dropFirst(4).map(\.rawValue), legacyOrder)
    }
}
