import Foundation

// DTOs modeled after the real TeslaMateApi JSON (github.com/tobiasehlert/teslamateapi).
// Decoding uses `.convertFromSnakeCase`; fields are optional so partial/version-divergent
// responses degrade gracefully. The drive/charge payloads are nested (odometer_details,
// battery_details, range_rated, …), reflected here.

// MARK: - Cars

struct CarsEnvelope: Decodable {
    let data: CarsData?
    struct CarsData: Decodable { let cars: [CarDTO]? }
}

struct CarDTO: Decodable {
    let carId: Int?
    let name: String?
    let carDetails: CarDetails?
    let carExterior: CarExterior?
    let teslamateStats: Stats?

    struct CarDetails: Decodable {
        let model: String?
        let trimBadging: String?
        let vin: String?
        let efficiency: Double?
    }
    struct CarExterior: Decodable {
        let exteriorColor: String?
        let wheelType: String?
        let spoilerType: String?
    }
    struct Stats: Decodable {
        let totalCharges: Int?
        let totalDrives: Int?
        let totalUpdates: Int?
    }

    func toDomain() -> CarSummary? {
        guard let id = carId else { return nil }
        return CarSummary(id: id, displayName: name ?? "Car \(id)", model: carDetails?.model)
    }

    func toInfo() -> CarInfo? {
        guard let id = carId else { return nil }
        return CarInfo(
            id: id,
            name: name ?? "Car \(id)",
            model: carDetails?.model,
            trimBadging: carDetails?.trimBadging,
            vin: carDetails?.vin,
            exteriorColor: carExterior?.exteriorColor,
            wheelType: carExterior?.wheelType,
            efficiencyKwhPerKm: carDetails?.efficiency,
            totalDrives: teslamateStats?.totalDrives,
            totalCharges: teslamateStats?.totalCharges,
            totalUpdates: teslamateStats?.totalUpdates)
    }
}

// MARK: - Shared nested objects

struct OdometerDetails: Decodable {
    let odometerStart: Double?
    let odometerEnd: Double?
    let odometerDistance: Double?
}

struct BatteryLevels: Decodable {
    let startBatteryLevel: Int?
    let endBatteryLevel: Int?
    let startUsableBatteryLevel: Int?
    let endUsableBatteryLevel: Int?
}

struct RangeDetail: Decodable {
    let startRange: Double?
    let endRange: Double?
    let rangeDiff: Double?
}

/// History responses use the server's configured units; the domain always uses km and °C.
struct HistoryUnitsDTO: Decodable {
    let unitOfLength: String?
    let unitOfTemperature: String?

    var lengthIsMiles: Bool { unitOfLength?.lowercased().hasPrefix("mi") == true }
    func kilometers(_ value: Double?) -> Double? {
        value.map { lengthIsMiles ? $0 * 1.609344 : $0 }
    }
    func celsius(_ value: Double?) -> Double? {
        value.map { unitOfTemperature?.uppercased() == "F" ? ($0 - 32) * 5 / 9 : $0 }
    }
}

// MARK: - Drives

struct DrivesEnvelope: Decodable {
    let data: DrivesData?
    struct DrivesData: Decodable {
        let drives: [DriveDTO]?
        let units: HistoryUnitsDTO?
    }
}

struct DriveDTO: Decodable {
    let driveId: Int?
    let startDate: String?
    let endDate: String?
    let startAddress: String?
    let endAddress: String?
    let durationMin: Int?
    let speedMax: Double?
    let speedAvg: Double?
    let powerMax: Double?
    let powerMin: Double?                 // most-negative power (peak regen)
    let outsideTempAvg: Double?
    let insideTempAvg: Double?
    let consumptionNet: Double?          // Wh/km
    let energyConsumedNet: Double?       // kWh for the whole drive
    let odometerDetails: OdometerDetails?
    let batteryDetails: BatteryLevels?
    let rangeRated: RangeDetail?
    let rangeIdeal: RangeDetail?

    func toDomain(index: Int, units: HistoryUnitsDTO? = nil) -> DriveRecord? {
        guard let start = startDate.flatMap(VehicleState.parseDate) else { return nil }
        let distance = units?.kilometers(odometerDetails?.odometerDistance) ?? odometerDetails?.odometerDistance ?? 0
        // Some TeslaMateApi versions scale consumption inversely when configured in miles.
        // Net kWh is invariant: derive Wh/km from it while retaining the API's precision gate.
        let consumption = consumptionNet.map { value in
            if units?.lengthIsMiles == true, let energy = energyConsumedNet, distance > 0 {
                return energy * 1000 / distance
            }
            return units?.lengthIsMiles == true ? value / 1.609344 : value
        }
        return DriveRecord(
            id: driveId ?? index,
            startDate: start,
            endDate: endDate.flatMap(VehicleState.parseDate),
            startAddress: startAddress,
            endAddress: endAddress,
            startGeofence: nil,
            endGeofence: nil,
            distanceKm: distance,
            durationMin: durationMin ?? 0,
            startBattery: batteryDetails?.startBatteryLevel,
            endBattery: batteryDetails?.endBatteryLevel,
            startUsableBattery: batteryDetails?.startUsableBatteryLevel,
            endUsableBattery: batteryDetails?.endUsableBatteryLevel,
            startRangeKm: units?.kilometers(rangeRated?.startRange) ?? rangeRated?.startRange,
            endRangeKm: units?.kilometers(rangeRated?.endRange) ?? rangeRated?.endRange,
            avgSpeedKmh: units?.kilometers(speedAvg) ?? speedAvg,
            maxSpeedKmh: units?.kilometers(speedMax) ?? speedMax,
            maxPowerKw: powerMax,
            minPowerKw: powerMin,
            outsideTempAvg: units?.celsius(outsideTempAvg) ?? outsideTempAvg,
            insideTempAvg: units?.celsius(insideTempAvg) ?? insideTempAvg,
            energyConsumedKwh: energyConsumedNet,
            startCoord: nil,
            endCoord: nil,
            path: [],
            consumptionWhPerKm: consumption,
            elevationProfile: []
        )
    }
}

// MARK: - Drive details (per-point GPS trace) — /v1/cars/{id}/drives/{driveId}

struct DriveDetailsEnvelope: Decodable {
    let data: DriveDetailsData?
    struct DriveDetailsData: Decodable { let drive: DriveWithDetails? }
    struct DriveWithDetails: Decodable { let driveDetails: [DrivePointDTO]? }
}

/// A single recorded position along a drive. Latitude/longitude are always present in
/// TeslaMate's `positions` table; elevation is nullable on older rows.
struct DrivePointDTO: Decodable {
    let latitude: Double?
    let longitude: Double?
    let elevation: Double?

    var coordinate: Coordinate? { Coordinate(latitude: latitude, longitude: longitude) }
}

// MARK: - Charges

struct ChargesEnvelope: Decodable {
    let data: ChargesData?
    struct ChargesData: Decodable {
        let charges: [ChargeDTO]?
        let units: HistoryUnitsDTO?
    }
}

struct ChargeDTO: Decodable {
    let chargeId: Int?
    let startDate: String?
    let endDate: String?
    let address: String?
    let geofence: String?
    let chargeEnergyAdded: Double?
    let chargeEnergyUsed: Double?        // grid energy incl. losses
    let cost: Double?
    let durationMin: Int?
    let outsideTempAvg: Double?
    let odometer: Double?
    let batteryDetails: BatteryLevels?
    let rangeRated: RangeDetail?
    let rangeIdeal: RangeDetail?
    let latitude: Double?
    let longitude: Double?

    func toDomain(index: Int, units: HistoryUnitsDTO? = nil) -> ChargeRecord? {
        guard let start = startDate.flatMap(VehicleState.parseDate) else { return nil }
        let energy = chargeEnergyAdded ?? 0
        let dur = durationMin ?? 0
        // No explicit peak-power field; estimate average power to classify AC vs DC.
        let avgPower = dur > 0 ? energy / (Double(dur) / 60.0) : 0
        return ChargeRecord(
            id: chargeId ?? index,
            startDate: start,
            endDate: endDate.flatMap(VehicleState.parseDate),
            address: address,
            geofence: geofence,
            energyAddedKwh: energy,
            startBattery: batteryDetails?.startBatteryLevel,
            endBattery: batteryDetails?.endBatteryLevel,
            startRangeKm: units?.kilometers(rangeRated?.startRange) ?? rangeRated?.startRange,
            endRangeKm: units?.kilometers(rangeRated?.endRange) ?? rangeRated?.endRange,
            durationMin: dur,
            cost: cost,
            energyUsedKwh: (chargeEnergyUsed ?? 0) > 0 ? chargeEnergyUsed : nil,
            outsideTempAvg: units?.celsius(outsideTempAvg) ?? outsideTempAvg,
            odometerKm: units?.kilometers(odometer) ?? odometer,
            avgPowerKw: avgPower > 0 ? avgPower : nil,
            coord: Coordinate(latitude: latitude, longitude: longitude),
            isFastCharger: avgPower > 25
        )
    }
}

// MARK: - Charge detail (per-point curve) — /v1/cars/{id}/charges/{chargeId}

struct ChargeDetailEnvelope: Decodable {
    let data: ChargeDetailData?
    struct ChargeDetailData: Decodable {
        let charge: ChargeWithDetails?
    }
    struct ChargeWithDetails: Decodable {
        let chargeDetails: [ChargeDetailPointDTO]?
    }
}

struct ChargeDetailPointDTO: Decodable {
    let date: String?
    let batteryLevel: Int?
    let chargerDetails: ChargerDetailDTO?

    struct ChargerDetailDTO: Decodable {
        let chargerPower: Int?       // kW (TeslaMate stores it as an integer)
        let chargerVoltage: Int?
        let chargerActualCurrent: Int?
    }

    func toDomain() -> ChargeCurvePoint? {
        guard let date = date.flatMap(VehicleState.parseDate),
              let soc = batteryLevel,
              let power = chargerDetails?.chargerPower else { return nil }
        return ChargeCurvePoint(date: date, soc: soc, powerKw: Double(power),
                                voltage: chargerDetails?.chargerVoltage,
                                current: chargerDetails?.chargerActualCurrent)
    }
}

// MARK: - Battery health — /v1/cars/{id}/battery-health

struct BatteryHealthEnvelope: Decodable {
    let data: BatteryHealthData?
    struct BatteryHealthData: Decodable {
        let batteryHealth: BatteryHealthDTO?
        let units: UnitsDTO?
    }
    struct UnitsDTO: Decodable { let unitOfLength: String? }
}

struct BatteryHealthDTO: Decodable {
    let maxRange: Double?
    let currentRange: Double?
    let maxCapacity: Double?
    let currentCapacity: Double?
    let ratedEfficiency: Double?
    let batteryHealthPercentage: Double?

    /// `lengthIsMiles` converts the range figures to km when TeslaMate is configured in miles,
    /// keeping the rest of the app's km-based assumptions intact.
    func toDomain(lengthIsMiles: Bool) -> BatteryHealthSummary? {
        let toKm = { (v: Double?) -> Double in
            guard let v else { return 0 }
            return lengthIsMiles ? v * 1.609344 : v
        }
        let summary = BatteryHealthSummary(
            healthPercentage: batteryHealthPercentage ?? 0,
            currentCapacityKwh: currentCapacity ?? 0,
            maxCapacityKwh: maxCapacity ?? 0,
            currentRangeKm: toKm(currentRange),
            maxRangeKm: toKm(maxRange),
            ratedEfficiency: ratedEfficiency)
        // Only useful if at least one signal is present.
        guard summary.healthPercentage > 0 || summary.maxCapacityKwh > 0 || summary.maxRangeKm > 0 else { return nil }
        return summary
    }
}

// MARK: - Software updates — /v1/cars/{id}/updates

struct UpdatesEnvelope: Decodable {
    let data: UpdatesData?
    struct UpdatesData: Decodable { let updates: [UpdateDTO]? }
}

struct UpdateDTO: Decodable {
    let updateId: Int?
    let startDate: String?
    let endDate: String?
    let version: String?

    func toDomain(index: Int) -> SoftwareUpdate? {
        guard let start = startDate.flatMap(VehicleState.parseDate) else { return nil }
        let v = (version?.isEmpty == false) ? version! : L("Unknown version")
        return SoftwareUpdate(id: updateId ?? index, version: v, startDate: start,
                              endDate: endDate.flatMap(VehicleState.parseDate))
    }
}

// MARK: - Live status — /v1/cars/{id}/status (API-only live mode)

/// TeslaMateApi answers some failures with HTTP 200 and `{"error": "…"}`.
struct APIErrorBody: Decodable {
    let error: String?
}

struct LiveStatusEnvelope: Decodable {
    let data: LiveStatusDTO?
}

/// TeslaMateApi's in-memory copy of the car's MQTT topics. The server fills a Go struct, so a
/// topic it has not received yet comes back as `0`, `false` or `""`; `apply(to:at:)` treats
/// those zero values as "unknown" where a real reading can't be zero. Lengths, pressures and
/// temperatures arrive in TeslaMate's display units and are normalized to km, bar and °C.
struct LiveStatusDTO: Decodable {
    let status: Status?
    let units: Units?

    struct Units: Decodable {
        let unitOfLength: String?
        let unitOfPressure: String?
        let unitOfTemperature: String?

        var lengthIsMiles: Bool { unitOfLength?.lowercased().hasPrefix("mi") == true }
        var pressureIsPsi: Bool { unitOfPressure?.lowercased() == "psi" }
        var temperatureIsFahrenheit: Bool { unitOfTemperature?.uppercased() == "F" }
    }

    struct Status: Decodable {
        let displayName: String?
        let state: String?
        let stateSince: String?
        let odometer: Double?
        let carStatus: CarStatus?
        let carDetails: CarDetails?
        let carExterior: CarExterior?
        let carGeodata: CarGeodata?
        let carVersions: CarVersions?
        let drivingDetails: DrivingDetails?
        let climateDetails: ClimateDetails?
        let batteryDetails: BatteryDetails?
        let chargingDetails: ChargingDetails?
        let tpmsDetails: TpmsDetails?
    }

    struct CarStatus: Decodable {
        let healthy: Bool?
        let locked: Bool?
        let sentryMode: Bool?
        let windowsOpen: Bool?
        let doorsOpen: Bool?
        let driverFrontDoorOpen: Bool?
        let driverRearDoorOpen: Bool?
        let passengerFrontDoorOpen: Bool?
        let passengerRearDoorOpen: Bool?
        let trunkOpen: Bool?
        let frunkOpen: Bool?
        let isUserPresent: Bool?
        let centerDisplayState: Double?
    }

    struct CarDetails: Decodable {
        let model: String?
        let trimBadging: String?
    }

    struct CarExterior: Decodable {
        let exteriorColor: String?
        let spoilerType: String?
        let wheelType: String?
    }

    struct Location: Decodable {
        let latitude: Double?
        let longitude: Double?
    }

    struct CarGeodata: Decodable {
        let geofence: String?
        let location: Location?
        let latitude: Double?       // deprecated duplicate of location.latitude
        let longitude: Double?
    }

    struct CarVersions: Decodable {
        let version: String?
        let updateAvailable: Bool?
        let updateVersion: String?
    }

    struct ActiveRoute: Decodable {
        let destination: String?
        let energyAtArrival: Double?
        let distanceToArrival: Double?
        let minutesToArrival: Double?
        let trafficMinutesDelay: Double?
        let location: Location?
    }

    struct DrivingDetails: Decodable {
        let activeRoute: ActiveRoute?
        let shiftState: String?
        let power: Double?          // kW
        let speed: Double?
        let heading: Double?
        let elevation: Double?
    }

    struct ClimateDetails: Decodable {
        let isClimateOn: Bool?
        let insideTemp: Double?
        let outsideTemp: Double?
        let isPreconditioning: Bool?
        let climateKeeperMode: String?
    }

    struct BatteryDetails: Decodable {
        let estBatteryRange: Double?
        let ratedBatteryRange: Double?
        let idealBatteryRange: Double?
        let batteryLevel: Double?
        let usableBatteryLevel: Double?
    }

    struct ChargingDetails: Decodable {
        let pluggedIn: Bool?
        let chargingState: String?
        let chargeEnergyAdded: Double?
        let chargeLimitSoc: Double?
        let chargePortDoorOpen: Bool?
        let chargerActualCurrent: Double?
        let chargerPhases: Double?
        let chargerPower: Double?
        let chargerVoltage: Double?
        let chargeCurrentRequest: Double?
        let chargeCurrentRequestMax: Double?
        let scheduledChargingStartTime: String?
        let timeToFullCharge: Double?
    }

    struct TpmsDetails: Decodable {
        let tpmsPressureFl: Double?
        let tpmsPressureFr: Double?
        let tpmsPressureRl: Double?
        let tpmsPressureRr: Double?
        let tpmsSoftWarningFl: Bool?
        let tpmsSoftWarningFr: Bool?
        let tpmsSoftWarningRl: Bool?
        let tpmsSoftWarningRr: Bool?
    }

    /// Overlay this snapshot on `state`, keeping earlier values for anything still unknown.
    func apply(to state: inout VehicleState, at now: Date = Date()) {
        guard let s = status else { return }
        let u = units ?? Units(unitOfLength: nil, unitOfPressure: nil, unitOfTemperature: nil)
        let km: (Double) -> Double = { u.lengthIsMiles ? $0 * 1.609344 : $0 }
        let bar: (Double) -> Double = { u.pressureIsPsi ? $0 / 14.503773800722 : $0 }
        let celsius: (Double) -> Double = { u.temperatureIsFahrenheit ? ($0 - 32) * 5 / 9 : $0 }
        state.lastUpdated = now

        // Status / identity
        if let v = Self.text(s.state) { state.state = CarState(raw: v) }
        if let v = Self.date(s.stateSince) { state.since = v }
        if let v = Self.text(s.displayName) { state.displayName = v }
        if let v = Self.positive(s.odometer) { state.odometer = km(v) }
        if let v = s.carStatus?.healthy { state.healthy = v }
        if let v = s.carVersions {
            if let version = Self.text(v.version) { state.version = version }
            if let available = v.updateAvailable { state.updateAvailable = available }
            state.updateVersion = Self.text(v.updateVersion)
        }
        if let v = Self.text(s.carDetails?.model) { state.model = v }
        if let v = Self.text(s.carDetails?.trimBadging) { state.trimBadging = v }
        if let v = Self.text(s.carExterior?.exteriorColor) { state.exteriorColor = v }
        if let v = Self.text(s.carExterior?.wheelType) { state.wheelType = v }
        if let v = Self.text(s.carExterior?.spoilerType) { state.spoilerType = v }

        // Battery: an all-zero block means TeslaMate has not reported it yet.
        if let b = s.batteryDetails,
           [b.batteryLevel, b.usableBatteryLevel, b.ratedBatteryRange, b.estBatteryRange, b.idealBatteryRange]
               .contains(where: { ($0 ?? 0) > 0 }) {
            if let v = Self.int(b.batteryLevel) { state.batteryLevel = v }
            if let v = Self.int(b.usableBatteryLevel) { state.usableBatteryLevel = v }
            if let v = Self.finite(b.ratedBatteryRange) { state.ratedBatteryRangeKm = km(v) }
            if let v = Self.finite(b.estBatteryRange) { state.estBatteryRangeKm = km(v) }
            if let v = Self.finite(b.idealBatteryRange) { state.idealBatteryRangeKm = km(v) }
        }

        // Charging
        if let c = s.chargingDetails {
            if let v = c.pluggedIn { state.pluggedIn = v }
            if let v = Self.text(c.chargingState) { state.chargingState = ChargingState(raw: v) }
            if let v = Self.finite(c.chargeEnergyAdded) { state.chargeEnergyAdded = v }
            if let v = Self.int(c.chargeLimitSoc), v > 0 { state.chargeLimitSoc = v }
            if let v = c.chargePortDoorOpen { state.chargePortDoorOpen = v }
            if let v = Self.finite(c.chargerPower) { state.chargerPower = v }
            if let v = Self.int(c.chargerVoltage) { state.chargerVoltage = v }
            if let v = Self.int(c.chargerActualCurrent) { state.chargerActualCurrent = v }
            if let v = Self.int(c.chargerPhases) { state.chargerPhases = v }
            if let v = Self.int(c.chargeCurrentRequest) { state.chargeCurrentRequest = v }
            if let v = Self.int(c.chargeCurrentRequestMax) { state.chargeCurrentRequestMax = v }
            state.scheduledChargingStartTime = Self.date(c.scheduledChargingStartTime)
            if let v = Self.finite(c.timeToFullCharge) { state.timeToFullCharge = v }
        }

        // Climate
        if let c = s.climateDetails {
            if let v = c.isClimateOn { state.isClimateOn = v }
            if let v = Self.finite(c.insideTemp) { state.insideTemp = celsius(v) }
            if let v = Self.finite(c.outsideTemp) { state.outsideTemp = celsius(v) }
            if let v = c.isPreconditioning { state.isPreconditioning = v }
            if let v = Self.text(c.climateKeeperMode) { state.climateKeeperMode = v }
        }

        // Position
        let location = s.carGeodata?.location
        let latitude = Self.finite(location?.latitude ?? s.carGeodata?.latitude)
        let longitude = Self.finite(location?.longitude ?? s.carGeodata?.longitude)
        let hasLocation = latitude != nil && longitude != nil && (latitude != 0 || longitude != 0)
        if hasLocation {
            state.latitude = latitude
            state.longitude = longitude
        }
        if let geodata = s.carGeodata { state.geofence = Self.text(geodata.geofence) }

        // Driving
        if let d = s.drivingDetails {
            if let v = Self.text(d.shiftState) { state.shiftState = ShiftState(raw: v) }
            if let v = Self.finite(d.power) { state.power = v }
            if let v = Self.finite(d.speed) {
                // `/status` reports 0 instead of "no speed" while parked; MQTT sends nothing.
                state.speed = (v == 0 && !state.isDriving) ? nil : km(v)
            }
            if hasLocation {
                if let v = Self.int(d.heading) { state.heading = v }
                if let v = Self.int(d.elevation) { state.elevation = v }
            }
            applyActiveRoute(d.activeRoute, to: &state, lengthIsMiles: u.lengthIsMiles, at: now)
        }

        // Security / openings
        if let c = s.carStatus {
            if let v = c.locked { state.locked = v }
            if let v = c.sentryMode { state.sentryMode = v }
            if let v = Self.int(c.centerDisplayState) { state.centerDisplayState = v }
            if let v = c.windowsOpen { state.windowsOpen = v }
            if let v = c.doorsOpen { state.doorsOpen = v }
            if let v = c.frunkOpen { state.frunkOpen = v }
            if let v = c.trunkOpen { state.trunkOpen = v }
            if let v = c.isUserPresent { state.isUserPresent = v }
            if let v = c.driverFrontDoorOpen { state.driverFrontDoorOpen = v }
            if let v = c.driverRearDoorOpen { state.driverRearDoorOpen = v }
            if let v = c.passengerFrontDoorOpen { state.passengerFrontDoorOpen = v }
            if let v = c.passengerRearDoorOpen { state.passengerRearDoorOpen = v }
        }

        // TPMS: 0 bar is "no reading", never a real tire pressure.
        if let t = s.tpmsDetails {
            if let v = Self.positive(t.tpmsPressureFl) { state.tpmsPressureFL = bar(v) }
            if let v = Self.positive(t.tpmsPressureFr) { state.tpmsPressureFR = bar(v) }
            if let v = Self.positive(t.tpmsPressureRl) { state.tpmsPressureRL = bar(v) }
            if let v = Self.positive(t.tpmsPressureRr) { state.tpmsPressureRR = bar(v) }
            if let v = t.tpmsSoftWarningFl { state.tpmsSoftWarningFL = v }
            if let v = t.tpmsSoftWarningFr { state.tpmsSoftWarningFR = v }
            if let v = t.tpmsSoftWarningRl { state.tpmsSoftWarningRL = v }
            if let v = t.tpmsSoftWarningRr { state.tpmsSoftWarningRR = v }
        }
    }

    /// TeslaMateApi converts the MQTT `miles_to_arrival` to km, and back to miles only when
    /// TeslaMate displays miles. The app stores miles, like the MQTT topic.
    private func applyActiveRoute(_ route: ActiveRoute?, to state: inout VehicleState,
                                  lengthIsMiles: Bool, at now: Date) {
        guard let route else { return }
        guard let destination = Self.text(route.destination) else {
            let hadRoute = state.activeRouteDestination != nil
            state.activeRouteDestination = nil
            state.activeRouteLatitude = nil
            state.activeRouteLongitude = nil
            state.activeRouteTrafficMinutesDelay = nil
            state.activeRouteEnergyAtArrival = nil
            state.activeRouteMilesToArrival = nil
            state.activeRouteMinutesToArrival = nil
            if hadRoute { state.activeRouteUpdatedAt = now }
            return
        }
        state.activeRouteError = nil
        state.activeRouteDestination = destination
        if let lat = Self.finite(route.location?.latitude), let lon = Self.finite(route.location?.longitude),
           lat != 0 || lon != 0 {
            state.activeRouteLatitude = lat
            state.activeRouteLongitude = lon
        }
        state.activeRouteTrafficMinutesDelay = Self.finite(route.trafficMinutesDelay)
        state.activeRouteEnergyAtArrival = Self.int(route.energyAtArrival)
        state.activeRouteMilesToArrival = Self.finite(route.distanceToArrival)
            .map { lengthIsMiles ? $0 : $0 / 1.609344 }
        state.activeRouteMinutesToArrival = Self.finite(route.minutesToArrival)
        state.activeRouteUpdatedAt = now
    }

    // MARK: Zero-value helpers

    private static func text(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func positive(_ value: Double?) -> Double? {
        guard let value = finite(value), value > 0 else { return nil }
        return value
    }

    private static func int(_ value: Double?) -> Int? {
        guard let value = finite(value), abs(value) < 1e9 else { return nil }
        return Int(value.rounded())
    }

    /// Go formats an unset timestamp as year 1 (`0001-01-01T…`); anything that old is unknown.
    private static func date(_ value: String?) -> Date? {
        guard let value = text(value), let date = VehicleState.parseDate(value),
              date.timeIntervalSince1970 > 946_684_800 else { return nil }
        return date
    }
}
