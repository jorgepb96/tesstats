import XCTest
@testable import Tesstats

@MainActor
final class NotificationEngineSentryTests: XCTestCase {

    private func makeEngine() -> (NotificationEngine, EventInboxStore) {
        let suite = "NotificationEngineSentryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let inbox = EventInboxStore(defaults: defaults, key: "events")
        let engine = NotificationEngine(defaults: defaults, inbox: inbox)
        return (engine, inbox)
    }

    private func state(sentryMode: Bool? = nil, banner: Bool = false) -> VehicleState {
        var s = VehicleState(carID: 1)
        s.state = .online
        s.sentryMode = sentryMode
        s.centerDisplayState = banner ? 7 : 0
        return s
    }

    func testSentryArmedAndDisarmedNotifications() {
        let (engine, inbox) = makeEngine()
        engine.prefs.sentryArmedAlerts = true

        engine.process(previous: state(sentryMode: false), current: state(sentryMode: true), carName: "Car")
        XCTAssertTrue(inbox.items.contains { $0.title == L("Sentry armed") })

        engine.process(previous: state(sentryMode: true), current: state(sentryMode: false), carName: "Car")
        XCTAssertTrue(inbox.items.contains { $0.title == L("Sentry disarmed") })
    }

    func testSentryArmedAlertsAreOffByDefault() {
        let (engine, inbox) = makeEngine()
        XCTAssertFalse(engine.prefs.sentryArmedAlerts)
        engine.process(previous: state(sentryMode: false), current: state(sentryMode: true), carName: "Car")
        XCTAssertTrue(inbox.items.isEmpty)
    }

    func testSentryEventCooldownSuppressesTheBurst() {
        let (engine, inbox) = makeEngine()
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // First banner transition → alert.
        engine.process(previous: state(), current: state(banner: true), carName: "Car", now: t0)
        // Banner clears and re-fires 2 minutes later (same incident) → suppressed.
        engine.process(previous: state(banner: true), current: state(), carName: "Car", now: t0.addingTimeInterval(60))
        engine.process(previous: state(), current: state(banner: true), carName: "Car", now: t0.addingTimeInterval(120))

        XCTAssertEqual(inbox.items.filter { $0.title == L("Possible Sentry event") }.count, 1)

        // A new banner after the cooldown expires → alerts again.
        let later = t0.addingTimeInterval(NotificationEngine.sentryCooldown + 60)
        engine.process(previous: state(banner: true), current: state(), carName: "Car", now: later)
        engine.process(previous: state(), current: state(banner: true), carName: "Car", now: later.addingTimeInterval(10))
        XCTAssertEqual(inbox.items.filter { $0.title == L("Possible Sentry event") }.count, 2)
    }

    func testPreferencesDecodeLeniently() throws {
        // A pre-existing prefs blob without the new sentry keys must keep its values
        // instead of resetting to defaults.
        let legacy = Data(#"{"enabled":true,"chargeStarted":true,"quietHoursEnabled":true,"quietStartMinutes":100}"#.utf8)
        let prefs = try JSONDecoder().decode(NotificationPreferences.self, from: legacy)
        XCTAssertTrue(prefs.chargeStarted)                 // preserved from the blob
        XCTAssertTrue(prefs.quietHoursEnabled)
        XCTAssertEqual(prefs.quietStartMinutes, 100)
        XCTAssertFalse(prefs.sentryArmedAlerts)            // new keys → defaults
        XCTAssertTrue(prefs.sentryBypassQuietHours)
    }
}
