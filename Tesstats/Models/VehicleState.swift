import Foundation

/// Live snapshot of a single vehicle, assembled incrementally from MQTT topics
/// `teslamate/cars/<car_id>/<metric>`. Every field is optional — TeslaMate emits
/// metrics independently and may omit any of them. Codable so it can be cached.
struct VehicleState: Sendable, Codable, Equatable {
    let carID: Int
    var lastUpdated: Date = .distantPast

    // Status
    var state: CarState?
    var since: Date?
    var healthy: Bool?
    var version: String?
    var updateAvailable: Bool?
    var updateVersion: String?

    // Vehicle identity
    var displayName: String?
    var model: String?
    var trimBadging: String?
    var exteriorColor: String?
    var wheelType: String?
    var spoilerType: String?

    // Battery / range
    var batteryLevel: Int?
    var usableBatteryLevel: Int?
    var ratedBatteryRangeKm: Double?
    var estBatteryRangeKm: Double?
    var idealBatteryRangeKm: Double?

    // Charging
    var pluggedIn: Bool?
    var chargingState: ChargingState?
    var chargeEnergyAdded: Double?
    var chargeLimitSoc: Int?
    var chargePortDoorOpen: Bool?
    var chargerPower: Double?
    var chargerVoltage: Int?
    var chargerActualCurrent: Int?
    var chargerPhases: Int?
    var chargeCurrentRequest: Int?
    var chargeCurrentRequestMax: Int?
    var scheduledChargingStartTime: Date?
    var timeToFullCharge: Double?      // hours

    // Climate
    var isClimateOn: Bool?
    var insideTemp: Double?            // °C
    var outsideTemp: Double?           // °C
    var isPreconditioning: Bool?
    var climateKeeperMode: String?

    // Driving / position
    var speed: Double?                 // km/h
    var power: Double?                 // kW
    var heading: Int?
    var elevation: Int?                // m
    var shiftState: ShiftState?
    var odometer: Double?              // km
    var latitude: Double?
    var longitude: Double?
    var geofence: String?

    // Security / physical
    var locked: Bool?
    var sentryMode: Bool?
    var centerDisplayState: Int?       // 7 ⇒ "Sentry mode active" banner on screen (inferred event)
    var windowsOpen: Bool?
    var doorsOpen: Bool?
    var frunkOpen: Bool?
    var trunkOpen: Bool?
    var isUserPresent: Bool?
    var driverFrontDoorOpen: Bool?
    var driverRearDoorOpen: Bool?
    var passengerFrontDoorOpen: Bool?
    var passengerRearDoorOpen: Bool?

    // TPMS (bar)
    var tpmsPressureFL: Double?
    var tpmsPressureFR: Double?
    var tpmsPressureRL: Double?
    var tpmsPressureRR: Double?
    // TPMS soft warnings — the car's own low-pressure flag per wheel (more reliable than a
    // fixed bar threshold, since the car knows its recommended pressure).
    var tpmsSoftWarningFL: Bool?
    var tpmsSoftWarningFR: Bool?
    var tpmsSoftWarningRL: Bool?
    var tpmsSoftWarningRR: Bool?

    // Active route
    var activeRouteDestination: String?
    var activeRouteLatitude: Double?
    var activeRouteLongitude: Double?
    var activeRouteTrafficMinutesDelay: Double?
    var activeRouteEnergyAtArrival: Int?
    var activeRouteMilesToArrival: Double?
    var activeRouteMinutesToArrival: Double?
    var activeRouteError: String?
    var activeRouteUpdatedAt: Date?

    init(carID: Int) { self.carID = carID }
}

// MARK: - Convenience

extension VehicleState {
    var coordinate: Coordinate? { Coordinate(latitude: latitude, longitude: longitude) }
    var routeCoordinate: Coordinate? { Coordinate(latitude: activeRouteLatitude, longitude: activeRouteLongitude) }

    var isCharging: Bool { state == .charging || chargingState == .charging }
    var isDriving: Bool { state == .driving || shiftState == .drive || shiftState == .reverse }

    /// Inferred Sentry event: TeslaMate has no Sentry topic; center display state `7`
    /// shows the "Sentry mode active" banner — treated as a *possible* detection.
    var sentryBannerActive: Bool { centerDisplayState == 7 }

    /// All known tire pressures (bar) paired with a localized wheel label.
    var tirePressures: [(label: String, bar: Double)] {
        [(L("Front left"), tpmsPressureFL), (L("Front right"), tpmsPressureFR),
         (L("Rear left"), tpmsPressureRL), (L("Rear right"), tpmsPressureRR)]
            .compactMap { label, value in value.map { (label, $0) } }
    }

    /// Wheels whose pressure is below `bar`. Used for the low-pressure alert.
    func tiresBelow(bar threshold: Double) -> [(label: String, bar: Double)] {
        tirePressures.filter { $0.bar > 0 && $0.bar < threshold }
    }

    /// Wheels the car itself flags with a low-pressure soft warning.
    var tiresWithSoftWarning: [String] {
        [(L("Front left"), tpmsSoftWarningFL), (L("Front right"), tpmsSoftWarningFR),
         (L("Rear left"), tpmsSoftWarningRL), (L("Rear right"), tpmsSoftWarningRR)]
            .compactMap { label, flag in flag == true ? label : nil }
    }

    var anyTpmsSoftWarning: Bool { !tiresWithSoftWarning.isEmpty }

    var anyOpeningOpen: Bool {
        [windowsOpen, doorsOpen, frunkOpen, trunkOpen,
         driverFrontDoorOpen, driverRearDoorOpen,
         passengerFrontDoorOpen, passengerRearDoorOpen]
            .contains { $0 == true }
    }

    func range(for kind: RangeKind) -> Double? {
        switch kind {
        case .rated: ratedBatteryRangeKm
        case .estimated: estBatteryRangeKm
        case .ideal: idealBatteryRangeKm
        }
    }

    var modelLine: String {
        var parts: [String] = []
        if let model { parts.append(modelDisplay(model)) }
        if let trimBadging, !trimBadging.isEmpty { parts.append(trimBadging.uppercased()) }
        return parts.joined(separator: " ")
    }

    private func modelDisplay(_ raw: String) -> String {
        switch raw.uppercased() {
        case "S": "Model S"
        case "3": "Model 3"
        case "X": "Model X"
        case "Y": "Model Y"
        default: raw
        }
    }
}

// MARK: - MQTT topic application

extension VehicleState {
    /// Apply a single MQTT metric (the topic suffix after `cars/<id>/`) to this snapshot.
    mutating func apply(metric: String, value: String) {
        lastUpdated = Date()
        let v = value
        switch metric {
        // Status
        case "state": state = CarState(raw: v)
        case "since": since = Self.parseDate(v)
        case "healthy": healthy = Self.bool(v)
        case "version": version = v.nilIfEmpty
        case "update_available": updateAvailable = Self.bool(v)
        case "update_version": updateVersion = v.nilIfEmpty

        // Identity
        case "display_name": displayName = v.nilIfEmpty
        case "model": model = v.nilIfEmpty
        case "trim_badging": trimBadging = v.nilIfEmpty
        case "exterior_color": exteriorColor = v.nilIfEmpty
        case "wheel_type": wheelType = v.nilIfEmpty
        case "spoiler_type": spoilerType = v.nilIfEmpty

        // Battery / range
        case "battery_level": batteryLevel = Int(v)
        case "usable_battery_level": usableBatteryLevel = Int(v)
        case "rated_battery_range_km": ratedBatteryRangeKm = Self.finiteDouble(v)
        case "est_battery_range_km": estBatteryRangeKm = Self.finiteDouble(v)
        case "ideal_battery_range_km": idealBatteryRangeKm = Self.finiteDouble(v)

        // Charging
        case "plugged_in": pluggedIn = Self.bool(v)
        case "charging_state": chargingState = ChargingState(raw: v)
        case "charge_energy_added": chargeEnergyAdded = Self.finiteDouble(v)
        case "charge_limit_soc": chargeLimitSoc = Int(v)
        case "charge_port_door_open": chargePortDoorOpen = Self.bool(v)
        case "charger_power": chargerPower = Self.finiteDouble(v)
        case "charger_voltage": chargerVoltage = Int(v)
        case "charger_actual_current": chargerActualCurrent = Int(v)
        case "charger_phases": chargerPhases = Int(v)
        case "charge_current_request": chargeCurrentRequest = Int(v)
        case "charge_current_request_max": chargeCurrentRequestMax = Int(v)
        case "scheduled_charging_start_time": scheduledChargingStartTime = Self.parseDate(v)
        case "time_to_full_charge": timeToFullCharge = Self.finiteDouble(v)

        // Climate
        case "is_climate_on": isClimateOn = Self.bool(v)
        case "inside_temp": insideTemp = Self.finiteDouble(v)
        case "outside_temp": outsideTemp = Self.finiteDouble(v)
        case "is_preconditioning": isPreconditioning = Self.bool(v)
        case "climate_keeper_mode": climateKeeperMode = v.nilIfEmpty

        // Driving / position
        case "speed": speed = Self.finiteDouble(v)
        case "power": power = Self.finiteDouble(v)
        case "heading": heading = Int(v)
        case "elevation": elevation = Int(v)
        case "shift_state": shiftState = ShiftState(raw: v)
        case "odometer": odometer = Self.finiteDouble(v)
        case "latitude": latitude = Self.finiteDouble(v)
        case "longitude": longitude = Self.finiteDouble(v)
        case "geofence": geofence = v.nilIfEmpty
        case "location": applyLocationJSON(v)

        // Security / physical
        case "locked": locked = Self.bool(v)
        case "sentry_mode": sentryMode = Self.bool(v)
        case "center_display_state": centerDisplayState = Int(v)
        case "windows_open": windowsOpen = Self.bool(v)
        case "doors_open": doorsOpen = Self.bool(v)
        case "frunk_open": frunkOpen = Self.bool(v)
        case "trunk_open": trunkOpen = Self.bool(v)
        case "is_user_present": isUserPresent = Self.bool(v)
        case "driver_front_door_open": driverFrontDoorOpen = Self.bool(v)
        case "driver_rear_door_open": driverRearDoorOpen = Self.bool(v)
        case "passenger_front_door_open": passengerFrontDoorOpen = Self.bool(v)
        case "passenger_rear_door_open": passengerRearDoorOpen = Self.bool(v)

        // TPMS
        case "tpms_pressure_fl": tpmsPressureFL = Self.finiteDouble(v)
        case "tpms_pressure_fr": tpmsPressureFR = Self.finiteDouble(v)
        case "tpms_pressure_rl": tpmsPressureRL = Self.finiteDouble(v)
        case "tpms_pressure_rr": tpmsPressureRR = Self.finiteDouble(v)
        case "tpms_soft_warning_fl": tpmsSoftWarningFL = Self.bool(v)
        case "tpms_soft_warning_fr": tpmsSoftWarningFR = Self.bool(v)
        case "tpms_soft_warning_rl": tpmsSoftWarningRL = Self.bool(v)
        case "tpms_soft_warning_rr": tpmsSoftWarningRR = Self.bool(v)

        // Active route
        case "active_route_destination": activeRouteDestination = v.nilIfEmpty; activeRouteUpdatedAt = Date()
        case "active_route_latitude": activeRouteLatitude = Self.finiteDouble(v); activeRouteUpdatedAt = Date()
        case "active_route_longitude": activeRouteLongitude = Self.finiteDouble(v); activeRouteUpdatedAt = Date()
        case "active_route_traffic_minutes_delay": activeRouteTrafficMinutesDelay = Self.finiteDouble(v); activeRouteUpdatedAt = Date()
        case "active_route_energy_at_arrival": activeRouteEnergyAtArrival = Int(v); activeRouteUpdatedAt = Date()
        case "active_route_miles_to_arrival": activeRouteMilesToArrival = Self.finiteDouble(v); activeRouteUpdatedAt = Date()
        case "active_route": applyActiveRouteJSON(v)

        default: break // unknown / future metric — ignored gracefully
        }
    }

    private mutating func applyLocationJSON(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let lat = Self.finiteDouble(obj["latitude"]) { latitude = lat }
        if let lon = Self.finiteDouble(obj["longitude"]) { longitude = lon }
    }

    private mutating func applyActiveRouteJSON(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        activeRouteUpdatedAt = Date()
        if let error = obj["error"] as? String, !error.isEmpty {
            activeRouteError = error
            activeRouteDestination = nil
            activeRouteLatitude = nil
            activeRouteLongitude = nil
            activeRouteTrafficMinutesDelay = nil
            activeRouteEnergyAtArrival = nil
            activeRouteMilesToArrival = nil
            activeRouteMinutesToArrival = nil
            return
        }
        activeRouteError = nil
        if let dest = obj["destination"] as? String { activeRouteDestination = dest.nilIfEmpty }
        let location = obj["location"] as? [String: Any]
        if let lat = Self.finiteDouble(location?["latitude"] ?? obj["latitude"]) { activeRouteLatitude = lat }
        if let lon = Self.finiteDouble(location?["longitude"] ?? obj["longitude"]) { activeRouteLongitude = lon }
        if let delay = Self.finiteDouble(obj["traffic_minutes_delay"]) { activeRouteTrafficMinutesDelay = delay }
        if let energy = Self.finiteDouble(obj["energy_at_arrival"]),
           energy >= Double(Int.min), energy <= Double(Int.max) {
            activeRouteEnergyAtArrival = Int(energy)
        }
        if let miles = Self.finiteDouble(obj["miles_to_arrival"]) { activeRouteMilesToArrival = miles }
        if let minutes = Self.finiteDouble(obj["minutes_to_arrival"]) { activeRouteMinutesToArrival = minutes }
    }

    // Parsing helpers
    static func bool(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "true", "1", "yes", "on": true
        case "false", "0", "no", "off": false
        default: nil
        }
    }

    /// MQTT and JSON are external inputs. Values such as `nan` and `inf` are accepted by
    /// `Double` but later trap when converted to `Int` or passed to Charts/MapKit.
    static func finiteDouble(_ value: String) -> Double? {
        guard let number = Double(value), number.isFinite else { return nil }
        return number
    }

    static func finiteDouble(_ value: Any?) -> Double? {
        let number: Double?
        switch value {
        case let value as Double: number = value
        case let value as NSNumber: number = value.doubleValue
        case let value as String: number = Double(value)
        default: number = nil
        }
        guard let number, number.isFinite else { return nil }
        return number
    }

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        return isoFractional.date(from: s) ?? iso.date(from: s)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
