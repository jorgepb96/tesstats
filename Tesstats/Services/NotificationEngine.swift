import Foundation
import UserNotifications

struct NotificationPreferences: Codable, Sendable, Equatable {
    var enabled = true
    var chargeComplete = true
    var chargeCostMissing = true
    var chargeStarted = false
    var chargeTargetReached = true
    var leftUnplugged = true
    var pluggedNotCharging = true
    var openingsOrUnlocked = true
    var lowBattery = true
    var lowBatteryThreshold = 20
    var softwareUpdate = true
    var geofence = true
    var sentryInferred = true
    /// Notify when Sentry Mode is armed or disarmed (the `sentry_mode` topic). Off by
    /// default — arming at every parking spot can be noisy.
    var sentryArmedAlerts = false
    /// Security alerts matter most at night: let the Sentry event break through quiet hours.
    var sentryBypassQuietHours = true

    // Tire pressure (TPMS) — threshold stored canonically in bar; the UI lets the user
    // enter it in bar or psi. Default ~2.4 bar (≈ 35 psi), a common low-pressure warning point.
    var tpmsLow = false
    var tpmsThresholdBar = 2.4
    var tpmsUnitIsPsi = false

    // Quiet hours — minutes since midnight; suppresses local alerts inside the window.
    var quietHoursEnabled = false
    var quietStartMinutes = 22 * 60      // 22:00
    var quietEndMinutes = 7 * 60         // 07:00

    static let barPerPsi = 0.0689476

    var tpmsThresholdDisplay: Double {
        get { tpmsUnitIsPsi ? tpmsThresholdBar / Self.barPerPsi : tpmsThresholdBar }
        set { tpmsThresholdBar = tpmsUnitIsPsi ? newValue * Self.barPerPsi : newValue }
    }
}

extension NotificationPreferences {
    /// Lenient decoding: every missing key falls back to its default, so adding a new
    /// preference never resets a user's saved choices (synthesized Codable would throw).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        func read<T: Decodable>(_ key: CodingKeys, _ into: inout T) {
            if let v = ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) { into = v }
        }
        read(.enabled, &enabled)
        read(.chargeComplete, &chargeComplete)
        read(.chargeCostMissing, &chargeCostMissing)
        read(.chargeStarted, &chargeStarted)
        read(.chargeTargetReached, &chargeTargetReached)
        read(.leftUnplugged, &leftUnplugged)
        read(.pluggedNotCharging, &pluggedNotCharging)
        read(.openingsOrUnlocked, &openingsOrUnlocked)
        read(.lowBattery, &lowBattery)
        read(.lowBatteryThreshold, &lowBatteryThreshold)
        read(.softwareUpdate, &softwareUpdate)
        read(.geofence, &geofence)
        read(.sentryInferred, &sentryInferred)
        read(.sentryArmedAlerts, &sentryArmedAlerts)
        read(.sentryBypassQuietHours, &sentryBypassQuietHours)
        read(.tpmsLow, &tpmsLow)
        read(.tpmsThresholdBar, &tpmsThresholdBar)
        read(.tpmsUnitIsPsi, &tpmsUnitIsPsi)
        read(.quietHoursEnabled, &quietHoursEnabled)
        read(.quietStartMinutes, &quietStartMinutes)
        read(.quietEndMinutes, &quietEndMinutes)
    }
}

/// On-device notification engine. Generates **local** notifications from live MQTT
/// transitions whenever the app has execution (foreground, or a background window the OS
/// grants). iOS cannot poll 24/7 reliably in the background — for guaranteed alerts with
/// the app closed, run the optional APNs push microservice (see /server). This is stated
/// honestly here and in the UI.
@MainActor
@Observable
final class NotificationEngine {
    var prefs: NotificationPreferences
    var authorized = false
    var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let defaultsKey = "tesstats.notification.prefs"
    private let defaults: UserDefaults
    private let inbox: EventInboxStore?

    /// A real Sentry alert triggers the banner repeatedly (each passer-by). One alert per
    /// window is plenty; the inbox keeps only the first of each burst too.
    static let sentryCooldown: TimeInterval = 10 * 60
    private var lastSentryEventAt: Date?

    init(defaults: UserDefaults = .standard, inbox: EventInboxStore? = nil) {
        self.defaults = defaults
        self.inbox = inbox
        if let data = defaults.data(forKey: defaultsKey),
           let loaded = try? JSONDecoder().decode(NotificationPreferences.self, from: data) {
            self.prefs = loaded
        } else {
            self.prefs = NotificationPreferences()
        }
    }

    func persist() {
        if let data = try? JSONEncoder().encode(prefs) { defaults.set(data, forKey: defaultsKey) }
    }

    func processCharges(_ charges: [ChargeRecord], carID: Int, server: String, prices: [String: Double]) {
        let key = "tesstats.charge-reminders.\(server).\(carID)"
        var state = defaults.data(forKey: key).flatMap {
            try? JSONDecoder().decode(ChargeCostReminderState.self, from: $0)
        } ?? ChargeCostReminderState()
        let reminders = state.inspect(charges, prices: prices)
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key) }
        guard prefs.enabled, prefs.chargeCostMissing else { return }
        for charge in reminders {
            post(id: "charge-cost-\(carID)-\(charge.id)", title: L("Add charging cost"),
                 body: "\(charge.locationName) · \(L("Tap to enter the price for this charging location."))",
                 route: ChargeNotificationRoute(carID: carID, chargeID: charge.id))
        }
    }

    /// Restore notification preferences to their defaults (used by "Delete all data").
    func resetToDefaults() {
        prefs = NotificationPreferences()
        defaults.removeObject(forKey: defaultsKey)
    }

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        await refreshAuthorizationStatus()
    }

    func refreshAuthorizationStatus() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        authorizationStatus = status
        #if os(iOS)
        authorized = status == .authorized || status == .provisional || status == .ephemeral
        #else
        authorized = status == .authorized || status == .provisional
        #endif
    }

    func sendTestNotification(after delay: TimeInterval = 10) async {
        await requestAuthorization()
        guard authorized else { return }
        post(id: "notification-test",
             title: L("Test notification"),
             body: L("Notifications are working on this iPhone."),
             trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false),
             bypassQuietHours: true)
    }

    /// Diff two consecutive snapshots and emit notifications for noteworthy transitions.
    /// `now` is injectable for tests (cooldown windows).
    func process(previous: VehicleState?, current: VehicleState, carName: String, now: Date = Date()) {
        guard prefs.enabled, let previous else { return }

        // Charge complete
        if prefs.chargeComplete,
           previous.chargingState != .complete, current.chargingState == .complete {
            post(id: "charge-complete",
                 title: L("Charging complete"),
                 body: L("\(carName) finished charging at \(current.batteryLevel ?? 100)%."))
        }

        // Charge started
        if prefs.chargeStarted,
           previous.chargingState != .charging, current.chargingState == .charging {
            let power = current.chargerPower.map { " \(Int($0)) kW" } ?? ""
            post(id: "charge-started",
                 title: L("Charging started"),
                 body: L("\(carName) started charging\(power) at \(current.batteryLevel ?? 0)%."))
        }

        // Charge target (limit SoC) reached
        if prefs.chargeTargetReached, let limit = current.chargeLimitSoc,
           let prev = previous.batteryLevel, let now = current.batteryLevel,
           prev < limit, now >= limit, current.pluggedIn == true || current.isCharging {
            post(id: "charge-target",
                 title: L("Charge limit reached"),
                 body: L("\(carName) hit its \(limit)% charge limit."))
        }

        // Tire pressure low (any wheel crosses below the configured threshold)
        if prefs.tpmsLow {
            let low = current.tiresBelow(bar: prefs.tpmsThresholdBar)
            let wasLow = !previous.tiresBelow(bar: prefs.tpmsThresholdBar).isEmpty
            if !low.isEmpty, !wasLow {
                let psi = prefs.tpmsUnitIsPsi
                let detail = low.map { t -> String in
                    let v = psi ? t.bar / NotificationPreferences.barPerPsi : t.bar
                    let unit = psi ? "psi" : "bar"
                    let value = v.formatted(.number.precision(.fractionLength(1)).locale(LanguageManager.locale))
                    return "\(t.label) \(value) \(unit)"
                }.joined(separator: ", ")
                post(id: "tpms-low",
                     title: L("Low tire pressure"),
                     body: L("\(carName): \(detail)."))
            }

            // The car's own soft warning — more reliable than a fixed threshold, fires on the
            // rising edge regardless of the bar value.
            if !current.tiresWithSoftWarning.isEmpty, previous.tiresWithSoftWarning.isEmpty {
                let wheels = current.tiresWithSoftWarning.joined(separator: ", ")
                post(id: "tpms-soft-warning",
                     title: L("Low tire pressure"),
                     body: L("\(carName) flagged low tire pressure: \(wheels)."))
            }
        }

        // Parked and left unplugged
        if prefs.leftUnplugged, previous.isDriving, !current.isDriving, current.pluggedIn == false {
            post(id: "unplugged",
                 title: L("Not plugged in"),
                 body: L("\(carName) was parked without being plugged in."))
        }

        // Plugged in but not charging
        if prefs.pluggedNotCharging,
           current.pluggedIn == true,
           previous.chargingState != .stopped, current.chargingState == .stopped {
            post(id: "plugged-idle",
                 title: L("Plugged in, not charging"),
                 body: L("\(carName) is connected but charging is stopped."))
        }

        // Openings / unlocked after parking
        if prefs.openingsOrUnlocked, !current.isDriving {
            if !previous.anyOpeningOpen, current.anyOpeningOpen {
                post(id: "opening",
                     title: L("Something is open"),
                     body: L("A door, window, frunk or trunk on \(carName) is open."))
            }
            if previous.locked == true, current.locked == false {
                post(id: "unlocked",
                     title: L("Vehicle unlocked"),
                     body: L("\(carName) is unlocked while parked."))
            }
        }

        // Low battery threshold crossing
        if prefs.lowBattery, let prev = previous.batteryLevel, let now = current.batteryLevel,
           prev > prefs.lowBatteryThreshold, now <= prefs.lowBatteryThreshold {
            post(id: "low-battery",
                 title: L("Low battery"),
                 body: L("\(carName) dropped to \(now)%."))
        }

        // Software update available
        if prefs.softwareUpdate, previous.updateAvailable != true, current.updateAvailable == true {
            post(id: "update",
                 title: L("Software update available"),
                 body: L("\(carName): \(current.updateVersion ?? "new version") is ready to install."))
        }

        // Geofence enter / exit
        if prefs.geofence, previous.geofence != current.geofence {
            if let g = current.geofence, !g.isEmpty {
                post(id: "geofence-enter",
                     title: L("Arrived"),
                     body: L("\(carName) entered \(g)."))
            } else if let g = previous.geofence, !g.isEmpty {
                post(id: "geofence-exit",
                     title: L("Departed"),
                     body: L("\(carName) left \(g)."))
            }
        }

        // Sentry armed / disarmed (the sentry_mode topic — a reliable signal).
        if prefs.sentryArmedAlerts, let was = previous.sentryMode, let isNow = current.sentryMode, was != isNow {
            if isNow {
                post(id: "sentry-armed",
                     title: L("Sentry armed"),
                     body: L("\(carName) armed Sentry Mode."))
            } else {
                post(id: "sentry-disarmed",
                     title: L("Sentry disarmed"),
                     body: L("\(carName) disarmed Sentry Mode."))
            }
        }

        // Inferred Sentry event (center_display_state == 7). Honest: inference, no video.
        // Cooldown suppresses the repeat-banner burst a single incident produces, and the
        // alert may break through quiet hours (a 3 AM security alert is the point of it).
        if prefs.sentryInferred, !previous.sentryBannerActive, current.sentryBannerActive {
            let withinCooldown = lastSentryEventAt.map { now.timeIntervalSince($0) < Self.sentryCooldown } ?? false
            if !withinCooldown {
                lastSentryEventAt = now
                let place = current.geofence ?? current.activeRouteDestination ?? L("its location")
                post(id: "sentry",
                     title: L("Possible Sentry event"),
                     body: L("\(carName) showed the Sentry banner near \(place). Inferred from the screen — any clip is on the car's USB, not available via TeslaMate."),
                     sound: Self.sentrySound,
                     timeSensitive: true,
                     bypassQuietHours: prefs.sentryBypassQuietHours)
            }
        }
    }

    /// Distinct two-tone alarm bundled with the app, so a Sentry alert is recognizable
    /// without looking at the phone.
    static let sentrySound = UNNotificationSound(named: UNNotificationSoundName("sentry-alert.wav"))

    /// True if `date` falls inside the user's quiet-hours window (handles overnight wrap).
    func isQuietTime(_ date: Date = Date()) -> Bool {
        guard prefs.quietHoursEnabled else { return false }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        let mins = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let start = prefs.quietStartMinutes, end = prefs.quietEndMinutes
        if start == end { return false }
        return start < end ? (mins >= start && mins < end)
                           : (mins >= start || mins < end)   // window crosses midnight
    }

    private func post(id: String, title: String, body: String,
                      sound: UNNotificationSound = .default,
                      timeSensitive: Bool = false,
                      trigger: UNNotificationTrigger? = nil,
                      bypassQuietHours: Bool = false,
                      route: ChargeNotificationRoute? = nil) {
        inbox?.add(category: .vehicle, title: title, body: body, symbol: symbol(for: id), chargeRoute: route)
        if isQuietTime() && !bypassQuietHours { return }   // respect quiet hours for on-device alerts
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound
        if let route { content.userInfo = ["carId": route.carID, "chargeId": route.chargeID] }
        if timeSensitive {
            // Breaks through Focus/scheduled summaries where the user allowed it. Degrades
            // to a normal alert when the signing profile lacks the entitlement (sideloads).
            content.interruptionLevel = .timeSensitive
        }
        let request = UNNotificationRequest(identifier: "\(id)", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    private func symbol(for id: String) -> String {
        switch id {
        case "charge-complete", "charge-started", "charge-target", "plugged-idle": "bolt.fill"
        case "tpms-low", "tpms-soft-warning": "gauge.with.dots.needle.bottom.50percent"
        case "unplugged", "low-battery": "battery.25percent"
        case "opening", "unlocked": "lock.open"
        case "update": "arrow.down.circle"
        case "geofence-enter", "geofence-exit": "mappin.and.ellipse"
        case "sentry", "sentry-armed", "sentry-disarmed": "video.fill"
        case "notification-test": "checkmark.circle.fill"
        default: "bell"
        }
    }
}
