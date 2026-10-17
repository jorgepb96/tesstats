import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif
#if os(iOS)
import ActivityKit
#endif

/// Bridges the live vehicle state to the widget extension: writes the shared App Group
/// snapshot, nudges WidgetKit to reload, and starts/updates/ends the charging Live Activity.
/// All read-only — it only reflects TeslaMate data.
@MainActor
enum WidgetBridge {
    private static var lastSnapshotWrite = Date.distantPast
    private static var lastWatchPush = Date.distantPast
    private static var lastActivityUpdate = Date.distantPast
    private static let store = WidgetSharedStore()
    private static var observedActivityIDs = Set<String>()
    private static var activityPushTokens: [String: String] = [:]
    private static var batteryHealthByCar: [Int: BatteryHealthSummary] = [:]
    /// Installed by `AppEnvironment` when the optional push bridge is configured.
    static var liveActivityPushTokenHandler: ((String, Int) -> Void)?

    /// Keep every read-only companion surface in sync when the user changes language,
    /// without waiting for the next MQTT message.
    static func updateLanguage(_ code: String) {
        let effectiveCode = LanguageManager.resolvedLanguageCode(code)
        if var snapshot = store.load() {
            snapshot.languageCode = effectiveCode
            store.save(snapshot)
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
            #if os(iOS)
            WatchBridge.shared.push(snapshot)
            #endif
        }
        #if os(iOS)
        for activity in Activity<ChargingActivityAttributes>.activities {
            let updatedState = {
                var copy = activity.content.state
                copy.languageCode = effectiveCode
                return copy
            }()
            let staleDate = activity.content.staleDate
            update(activity, to: ActivityContent(state: updatedState, staleDate: staleDate))
            reregister(activity)
        }
        #endif
    }

    /// Propagate an appearance change immediately instead of waiting for the next MQTT event.
    /// Live Activities are rendered by a separate process, so their color must be part of the
    /// ActivityKit state rather than the app's in-memory theme singleton.
    static func updateAccent(_ hex: String) {
        if var snapshot = store.load() {
            snapshot.accentColorHex = hex
            store.save(snapshot)
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
            #if os(iOS)
            WatchBridge.shared.push(snapshot)
            #endif
        }
        #if os(iOS)
        for activity in Activity<ChargingActivityAttributes>.activities {
            var updatedState = activity.content.state
            updatedState.accentColorHex = hex
            let state = updatedState
            let staleDate = activity.content.staleDate
            update(activity, to: ActivityContent(state: state, staleDate: staleDate))
            reregister(activity)
        }
        #endif
    }

    static func update(state: VehicleState, carName: String, config: ServerConfig, cache: CacheStore, force: Bool = false) {
        // Live Activity is evaluated every call (cheap, no disk) so it starts/ends promptly.
        #if os(iOS)
        updateLiveActivity(state: state, carName: carName, config: config)
        #endif

        let now = Date()
        let snap = makeSnapshot(state: state, carName: carName, config: config, now: now)

        // While the Watch app is visible, interactive WatchConnectivity messages arrive
        // immediately. Keep that path responsive without making WidgetKit hit disk each time.
        #if os(iOS)
        if force || now.timeIntervalSince(lastWatchPush) >= 1 {
            lastWatchPush = now
            WatchBridge.shared.push(snap)
        }
        #endif

        // The persistent widget snapshot + timeline reload remain throttled because both hit
        // disk and are scheduled by the OS. Watch application context is persisted separately.
        guard force || now.timeIntervalSince(lastSnapshotWrite) >= 20 else { return }
        lastSnapshotWrite = now

        let snapshotCarID = state.carID
        let snapshotUpdatedAt = snap.lastUpdated
        // A multi-year drive cache can be several MB. Fetch its first item away from the main
        // actor before completing the small widget snapshot.
        Task { @MainActor in
            var completed = snap
            if let trip = await cache.scoped(to: config).loadLatestDrive(carID: snapshotCarID) {
                completed.lastTripTitle = "\(trip.originName) → \(trip.destinationName)"
                completed.lastTripDistanceKm = trip.distanceKm
                completed.lastTripDate = trip.startDate
            }
            // Do not let a slower cache read replace a newer live state for the same vehicle.
            if let current = store.load(), current.carID == snapshotCarID,
               current.lastUpdated > snapshotUpdatedAt {
                completed = current
            }
            store.save(completed)
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
            #if os(iOS)
            WatchBridge.shared.push(completed)
            #endif
        }
    }

    /// Merge the official TeslaMateApi battery-health reading into the companion snapshot.
    /// Live MQTT updates preserve these fields until the next history refresh.
    static func updateBatteryHealth(_ health: BatteryHealthSummary, carID: Int) {
        batteryHealthByCar[carID] = health
        guard var snapshot = store.load(), snapshot.carID == carID else { return }
        snapshot.batteryHealthPercent = health.healthPercentage > 0 ? health.healthPercentage : nil
        snapshot.currentCapacityKwh = health.currentCapacityKwh > 0 ? health.currentCapacityKwh : nil
        snapshot.originalCapacityKwh = health.maxCapacityKwh > 0 ? health.maxCapacityKwh : nil
        snapshot.fullRangeKm = health.currentRangeKm > 0 ? health.currentRangeKm : snapshot.fullRangeKm
        snapshot.originalRangeKm = health.maxRangeKm > 0 ? health.maxRangeKm : nil
        store.save(snapshot)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
        #if os(iOS)
        WatchBridge.shared.push(snapshot)
        #endif
    }

    private static func makeSnapshot(state: VehicleState,
                                     carName: String,
                                     config: ServerConfig,
                                     now: Date) -> WidgetSnapshot {
        let previous = store.load()
        var snap = WidgetSnapshot()
        snap.carID = state.carID
        snap.carName = carName
        snap.stateRaw = state.state?.rawValue ?? (state.isCharging ? "charging" : "offline")
        snap.batteryLevel = state.batteryLevel ?? 0
        snap.usableLevel = state.usableBatteryLevel
        snap.rangeKm = state.range(for: config.rangeKind)
        snap.isCharging = state.isCharging
        snap.chargerPowerKw = state.chargerPower
        snap.chargeLimitSoc = state.chargeLimitSoc
        snap.timeToFullHours = state.timeToFullCharge
        snap.odometerKm = state.odometer
        snap.locked = state.locked
        snap.sentryMode = state.sentryMode
        snap.occupied = state.isUserPresent
        snap.tpmsPressureFL = state.tpmsPressureFL
        snap.tpmsPressureFR = state.tpmsPressureFR
        snap.tpmsPressureRL = state.tpmsPressureRL
        snap.tpmsPressureRR = state.tpmsPressureRR
        snap.tpmsSoftWarningFL = state.tpmsSoftWarningFL
        snap.tpmsSoftWarningFR = state.tpmsSoftWarningFR
        snap.tpmsSoftWarningRL = state.tpmsSoftWarningRL
        snap.tpmsSoftWarningRR = state.tpmsSoftWarningRR
        snap.insideTempC = state.insideTemp
        snap.outsideTempC = state.outsideTemp
        snap.isClimateOn = state.isClimateOn
        snap.isPreconditioning = state.isPreconditioning
        snap.climateKeeperMode = state.climateKeeperMode
        snap.isImperial = config.units == .imperial
        snap.pressureIsPsi = config.pressureIsPsi
        snap.languageCode = LanguageManager.resolvedLanguageCode(config.languageCode)
        snap.accentColorHex = config.accentColorHex
        snap.lastUpdated = state.lastUpdated == .distantPast ? now : state.lastUpdated
        if let range = snap.rangeKm, snap.batteryLevel > 0 {
            snap.fullRangeKm = range / (Double(snap.batteryLevel) / 100)
        }

        if let previous, previous.carID == state.carID {
            snap.lastTripTitle = previous.lastTripTitle
            snap.lastTripDistanceKm = previous.lastTripDistanceKm
            snap.lastTripDate = previous.lastTripDate
            snap.batteryHealthPercent = previous.batteryHealthPercent
            snap.currentCapacityKwh = previous.currentCapacityKwh
            snap.originalCapacityKwh = previous.originalCapacityKwh
            snap.originalRangeKm = previous.originalRangeKm
            // The API-derived full-charge range is more authoritative than the SoC projection.
            if previous.batteryHealthPercent != nil, previous.fullRangeKm != nil {
                snap.fullRangeKm = previous.fullRangeKm
            }
        }
        if let health = batteryHealthByCar[state.carID] {
            snap.batteryHealthPercent = health.healthPercentage > 0 ? health.healthPercentage : nil
            snap.currentCapacityKwh = health.currentCapacityKwh > 0 ? health.currentCapacityKwh : nil
            snap.originalCapacityKwh = health.maxCapacityKwh > 0 ? health.maxCapacityKwh : nil
            snap.fullRangeKm = health.currentRangeKm > 0 ? health.currentRangeKm : snap.fullRangeKm
            snap.originalRangeKm = health.maxRangeKm > 0 ? health.maxRangeKm : nil
        }
        return snap
    }

    /// Clear the shared snapshot, stop activities and refresh widgets (used by "Delete all data").
    static func clearAll() {
        store.clear()
        batteryHealthByCar.removeAll()
        stopLiveActivities()
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
        #if os(iOS)
        var empty = WidgetSnapshot()
        empty.lastUpdated = Date()
        WatchBridge.shared.push(empty)
        #endif
    }

    /// Tear down any running Live Activity (e.g. when the user disables it).
    static func stopLiveActivities() {
        #if os(iOS)
        for activity in Activity<ChargingActivityAttributes>.activities {
            end(activity, content: nil, dismissalPolicy: .immediate)
        }
        #endif
    }

    /// Re-send any token already received after push settings or connectivity change.
    static func reregisterLiveActivityPushTokens() {
        #if os(iOS)
        for activity in Activity<ChargingActivityAttributes>.activities {
            observePushToken(for: activity)
            reregister(activity)
        }
        #endif
    }

    #if os(iOS)
    private static func updateLiveActivity(state: VehicleState, carName: String, config: ServerConfig) {
        guard config.liveActivityEnabled, ActivityAuthorizationInfo().areActivitiesEnabled else {
            stopLiveActivities()
            return
        }
        let content = ChargingActivityAttributes.ContentState(
            batteryLevel: state.batteryLevel ?? 0,
            chargeLimitSoc: state.chargeLimitSoc ?? 100,
            chargerPowerKw: state.chargerPower ?? 0,
            timeToFullHours: state.timeToFullCharge ?? 0,
            rangeKm: state.range(for: config.rangeKind) ?? 0,
            isImperial: config.units == .imperial,
            isComplete: !state.isCharging,
            languageCode: LanguageManager.resolvedLanguageCode(config.languageCode),
            accentColorHex: config.accentColorHex)

        let existing = Activity<ChargingActivityAttributes>.activities.first

        if state.isCharging {
            if let existing {
                observePushToken(for: existing)
                // Throttle in-flight updates to avoid ActivityKit rate limits.
                let now = Date()
                guard now.timeIntervalSince(lastActivityUpdate) >= 5 else { return }
                lastActivityUpdate = now
                update(existing, to: ActivityContent(state: content, staleDate: nil))
            } else {
                lastActivityUpdate = Date()
                do {
                    let activity = try Activity.request(
                        attributes: ChargingActivityAttributes(carName: carName, carID: state.carID),
                        content: ActivityContent(state: content, staleDate: Date().addingTimeInterval(3600)),
                        pushType: .token)
                    observePushToken(for: activity)
                } catch {
                    // Rate-limited or disabled mid-flight — ignore.
                }
            }
        } else if let existing {
            // Charging ended — show the final state briefly, then dismiss.
            end(existing, content: ActivityContent(state: content, staleDate: nil),
                dismissalPolicy: .after(Date().addingTimeInterval(8)))
        }
    }


    private static func observePushToken(for activity: Activity<ChargingActivityAttributes>) {
        let id = activity.id
        guard observedActivityIDs.insert(id).inserted else { return }
        Task {
            for await data in activity.pushTokenUpdates {
                let token = data.map { String(format: "%02x", $0) }.joined()
                activityPushTokens[id] = token
                reregister(activity)
            }
            observedActivityIDs.remove(id)
            activityPushTokens.removeValue(forKey: id)
        }
    }

    /// `Activity` is not `Sendable` in the iOS 26.5 SDK, so calling its nonisolated `update`/`end`
    /// from this main-actor type is rejected as a data race. ActivityKit allows those calls from
    /// any context; hand them to a detached task instead.
    private struct UncheckedSendable<Value>: @unchecked Sendable { let value: Value }

    private static func update(_ activity: Activity<ChargingActivityAttributes>,
                               to content: ActivityContent<ChargingActivityAttributes.ContentState>) {
        let box = UncheckedSendable(value: (activity, content))
        Task.detached { await box.value.0.update(box.value.1) }
    }

    private static func end(_ activity: Activity<ChargingActivityAttributes>,
                            content: ActivityContent<ChargingActivityAttributes.ContentState>?,
                            dismissalPolicy: ActivityUIDismissalPolicy) {
        let box = UncheckedSendable(value: (activity, content, dismissalPolicy))
        Task.detached { await box.value.0.end(box.value.1, dismissalPolicy: box.value.2) }
    }

    private static func reregister(_ activity: Activity<ChargingActivityAttributes>) {
        guard let token = activityPushTokens[activity.id],
              let carID = activity.attributes.carID else { return }
        liveActivityPushTokenHandler?(token, carID)
    }
    #endif
}
