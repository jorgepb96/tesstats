import Foundation

// MARK: - Vehicle info (from TeslaMateApi /cars)

struct CarInfo: Sendable, Equatable, Codable {
    var id: Int
    var name: String
    var model: String?
    var trimBadging: String?
    var vin: String?
    var exteriorColor: String?
    var wheelType: String?
    var efficiencyKwhPerKm: Double?
    var totalDrives: Int?
    var totalCharges: Int?
    var totalUpdates: Int?
}

// MARK: - Drives

struct DriveRecord: Identifiable, Sendable, Codable, Hashable {
    let id: Int
    var startDate: Date
    var endDate: Date?
    var startAddress: String?
    var endAddress: String?
    var startGeofence: String?
    var endGeofence: String?
    var distanceKm: Double
    var durationMin: Int
    var startBattery: Int?
    var endBattery: Int?
    var startUsableBattery: Int?
    var endUsableBattery: Int?
    var startRangeKm: Double?
    var endRangeKm: Double?
    var avgSpeedKmh: Double?
    var maxSpeedKmh: Double?
    var maxPowerKw: Double?
    /// Most-negative power during the drive (kW). Maps to TeslaMate `power_min`; the magnitude
    /// when negative is the peak regenerative-braking power.
    var minPowerKw: Double?
    var outsideTempAvg: Double?
    var insideTempAvg: Double?
    /// Net energy consumed for the drive (kWh) as recorded by TeslaMate (`energy_consumed_net`).
    var energyConsumedKwh: Double?
    var startCoord: Coordinate?
    var endCoord: Coordinate?
    /// Path of the drive. May be a rich trace, or just [start, end] when the
    /// positions endpoint is unavailable (documented limitation of TeslaMateApi).
    var path: [Coordinate]

    var originName: String { startGeofence ?? startAddress ?? L("Origin") }
    var destinationName: String { endGeofence ?? endAddress ?? L("Destination") }

    /// Consumption in Wh/km derived from range delta if not provided directly.
    var consumptionWhPerKm: Double?

    var elevationProfile: [Double]   // optional sampled elevation (m) for the detail chart

    /// Peak regenerative-braking power (kW, positive) when the drive recorded a negative power_min.
    var maxRegenKw: Double? {
        guard let p = minPowerKw, p < 0 else { return nil }
        return -p
    }
}

/// The real GPS trace of a single drive, fetched on demand from TeslaMateApi's
/// drive-details endpoint. Used to draw the route from actual recorded positions
/// instead of geocoding the (ambiguous) start/end address text.
struct DriveTrace: Sendable {
    var path: [Coordinate]
    var elevationProfile: [Double]

    var isUsable: Bool { path.count >= 2 }
}

// MARK: - Charges

struct ChargeRecord: Identifiable, Sendable, Codable, Hashable {
    let id: Int
    var startDate: Date
    var endDate: Date?
    var address: String?
    var geofence: String?
    var energyAddedKwh: Double
    var startBattery: Int?
    var endBattery: Int?
    var startRangeKm: Double?
    var endRangeKm: Double?
    var durationMin: Int
    var cost: Double?
    /// Energy actually drawn from the grid/source (kWh), TeslaMate `charge_energy_used`. Always
    /// ≥ `energyAddedKwh`; the difference is charging loss (heat, BMS, AC/DC conversion).
    var energyUsedKwh: Double?
    /// Average ambient temperature during the session (°C), TeslaMate `outside_temp_avg`.
    var outsideTempAvg: Double?
    /// Odometer reading at the session (km), TeslaMate `odometer`.
    var odometerKm: Double?
    /// Session AVERAGE power (kWh ÷ hours) — the list endpoint has no per-point data, so this
    /// is not the peak. The real peak comes from the per-point curve (`ChargeCurvePoint`).
    var avgPowerKw: Double?
    var coord: Coordinate?
    /// Fast / public DC charging (Supercharger etc.) vs. slower AC/home.
    var isFastCharger: Bool

    var locationName: String { geofence ?? address ?? L("Unknown location") }
    var isHome: Bool { (geofence?.localizedCaseInsensitiveContains("home") ?? false) }

    /// Charging efficiency (added ÷ used), 0…1, when the grid-energy figure is available.
    var chargingEfficiency: Double? {
        guard let used = energyUsedKwh, used.isFinite, energyAddedKwh.isFinite,
              used > 0, energyAddedKwh >= 0, used >= energyAddedKwh else { return nil }
        return energyAddedKwh / used
    }
}

// MARK: - Charge curve (per-point kW vs SoC, from the charge-detail endpoint)

struct ChargeCurvePoint: Identifiable, Sendable, Codable, Hashable {
    var id: Date { date }
    var date: Date
    var soc: Int           // battery_level (%)
    var powerKw: Double     // charger_power (kW)
    var voltage: Int?
    var current: Int?
}

// MARK: - Battery health / degradation

struct BatteryHealthPoint: Identifiable, Sendable, Codable, Hashable {
    var id: Date { date }
    var date: Date
    var odometerKm: Double
    /// Observed maximum rated range at ~100% (km) — the degradation curve.
    var maxRangeKm: Double
    var usableCapacityKwh: Double?
}

/// Official battery-health snapshot from TeslaMateApi's `/battery-health` endpoint — a single
/// current reading (not a time series), more authoritative than the locally-derived curve.
struct BatteryHealthSummary: Sendable, Codable, Equatable {
    var healthPercentage: Double          // battery_health_percentage (0…100)
    var currentCapacityKwh: Double        // current usable pack capacity now
    var maxCapacityKwh: Double            // pack capacity when new
    var currentRangeKm: Double            // projected max range now (at 100%)
    var maxRangeKm: Double                // projected max range when new (at 100%)
    var ratedEfficiency: Double?

    /// Capacity retained vs. new (0…1), preferring the explicit percentage.
    var capacityLossFraction: Double? {
        if maxCapacityKwh > 0, currentCapacityKwh > 0 { return max(0, 1 - currentCapacityKwh / maxCapacityKwh) }
        if healthPercentage > 0 { return max(0, 1 - healthPercentage / 100) }
        return nil
    }
}

// MARK: - Software updates

/// One firmware installation from TeslaMateApi's `/updates` endpoint.
struct SoftwareUpdate: Identifiable, Sendable, Codable, Hashable {
    let id: Int
    var version: String
    var startDate: Date
    var endDate: Date?
}

// MARK: - Aggregates

struct ChargeAggregates: Sendable {
    var totalEnergyKwh: Double = 0
    var totalEnergyUsedKwh: Double = 0    // grid energy incl. losses (charge_energy_used)
    var totalCost: Double = 0
    var homeEnergyKwh: Double = 0
    var publicEnergyKwh: Double = 0
    var homeCost: Double = 0
    var publicCost: Double = 0
    var sessionCount: Int = 0
    private var meteredEnergyAddedKwh: Double = 0
    private var meteredSessionCount: Int = 0

    static func from(_ charges: [ChargeRecord]) -> ChargeAggregates {
        var agg = ChargeAggregates()
        for c in charges {
            agg.sessionCount += 1
            agg.totalEnergyKwh += c.energyAddedKwh
            if c.chargingEfficiency != nil, let used = c.energyUsedKwh {
                agg.totalEnergyUsedKwh += used
                agg.meteredEnergyAddedKwh += c.energyAddedKwh
                agg.meteredSessionCount += 1
            }
            agg.totalCost += c.cost ?? 0
            // Classify AC (home/destination) vs DC fast (public) by power — more reliable
            // than geofence names, which many setups don't configure.
            if c.isFastCharger {
                agg.publicEnergyKwh += c.energyAddedKwh
                agg.publicCost += c.cost ?? 0
            } else {
                agg.homeEnergyKwh += c.energyAddedKwh
                agg.homeCost += c.cost ?? 0
            }
        }
        return agg
    }

    /// Overall charging efficiency (energy into battery ÷ energy drawn), 0…1, when the grid
    /// figure is available for the period.
    var chargingEfficiency: Double? {
        guard meteredSessionCount > 0, totalEnergyUsedKwh > 0 else { return nil }
        return meteredEnergyAddedKwh / totalEnergyUsedKwh
    }

    /// Energy lost to charging (kWh) when the grid figure exceeds what reached the battery.
    var lossKwh: Double? {
        guard meteredSessionCount > 0 else { return nil }
        return totalEnergyUsedKwh - meteredEnergyAddedKwh
    }
}

struct EfficiencySummary: Sendable {
    var avgWhPerKm: Double = 0
    var totalDistanceKm: Double = 0
    var totalDrives: Int = 0
    var maxSpeedKmh: Double = 0

    static func from(_ drives: [DriveRecord]) -> EfficiencySummary {
        var s = EfficiencySummary()
        // Distance-weighted average: a 2 km cold-start drive shouldn't count the same as a
        // 200 km motorway run. (A plain mean of per-drive Wh/km biases the figure high.)
        var weightedSum = 0.0, weightedDistance = 0.0
        for d in drives {
            s.totalDrives += 1
            s.totalDistanceKm += d.distanceKm
            if let m = d.maxSpeedKmh { s.maxSpeedKmh = max(s.maxSpeedKmh, m) }
            if let c = d.consumptionWhPerKm, c > 0, d.distanceKm > 0 {
                weightedSum += c * d.distanceKm
                weightedDistance += d.distanceKm
            }
        }
        if weightedDistance > 0 { s.avgWhPerKm = weightedSum / weightedDistance }
        return s
    }
}
