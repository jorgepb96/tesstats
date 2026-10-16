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
