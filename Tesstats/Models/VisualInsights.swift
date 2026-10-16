import Foundation

struct DailyHistoryGroup<Item: Sendable>: Identifiable, Sendable {
    var day: Date
    var items: [Item]
    var title: String
    var detail: String

    var id: Date { day }
}

enum DailyHistoryGrouper {
    static func group<Item: Sendable>(
        _ items: [Item],
        calendar: Calendar = .current,
        date: (Item) -> Date,
        title: (Date) -> String,
        detail: ([Item]) -> String
    ) -> [DailyHistoryGroup<Item>] {
        let buckets = Dictionary(grouping: items) { item in
            calendar.startOfDay(for: date(item))
        }
        return buckets.keys.sorted(by: >).map { day in
            let bucket = (buckets[day] ?? []).sorted { date($0) > date($1) }
            return DailyHistoryGroup(day: day, items: bucket, title: title(day), detail: detail(bucket))
        }
    }
}

struct DashboardActivitySegment: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case driving, charging, online
    }

    var id: String { "\(kind.rawValue)-\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)" }
    var kind: Kind
    var start: Date
    var end: Date
}

struct DashboardInsights: Sendable {
    var lastDrive: DriveRecord?
    var efficiency30dWhPerKm: Double?
    var activity48h: [DashboardActivitySegment]
}

enum DashboardInsightEngine {
    static func insights(drives: [DriveRecord], charges: [ChargeRecord], now: Date = Date()) -> DashboardInsights {
        let lastDrive = drives.sorted { $0.startDate > $1.startDate }.first
        let cutoff30 = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
        let recent = drives.filter { $0.startDate >= cutoff30 }
        let efficiency = EfficiencySummary.from(recent).avgWhPerKm
        return DashboardInsights(
            lastDrive: lastDrive,
            efficiency30dWhPerKm: efficiency > 0 ? efficiency : nil,
            activity48h: activitySegments(drives: drives, charges: charges, now: now)
        )
    }

    static func activitySegments(drives: [DriveRecord], charges: [ChargeRecord], now: Date = Date()) -> [DashboardActivitySegment] {
        let start = now.addingTimeInterval(-48 * 3600)
        var segments: [DashboardActivitySegment] = []
        for drive in drives {
            guard let end = drive.endDate else { continue }
            if let clipped = clip(start: drive.startDate, end: end, windowStart: start, windowEnd: now) {
                segments.append(DashboardActivitySegment(kind: .driving, start: clipped.0, end: clipped.1))
            }
        }
        for charge in charges {
            guard let end = charge.endDate else { continue }
            if let clipped = clip(start: charge.startDate, end: end, windowStart: start, windowEnd: now) {
                segments.append(DashboardActivitySegment(kind: .charging, start: clipped.0, end: clipped.1))
            }
        }
        return segments.sorted { $0.start < $1.start }
    }

    private static func clip(start: Date, end: Date, windowStart: Date, windowEnd: Date) -> (Date, Date)? {
        let a = max(start, windowStart)
        let b = min(end, windowEnd)
        return b > a ? (a, b) : nil
    }
}

/// The battery screen's degradation chart, unit-converted once instead of on every body pass
/// (and once more per frame while the chart is being scrubbed).
struct BatteryCurve: Sendable {
    struct Point: Identifiable, Sendable, Hashable {
        var date: Date
        /// Max range in the user's distance unit — already converted.
        var value: Double
        var id: Date { date }
    }

    var points: [Point] = []
    /// Max range lost across the whole history, in percent. Deliberately independent of the
    /// selected time range: it answers "how much has this pack aged", not "in the last 30 days".
    var lostPercent: Double?

    private static let kmPerMile = 1.609344

    static func make(points all: [BatteryHealthPoint], timeRange: TimeRange, imperial: Bool) -> BatteryCurve {
        var curve = BatteryCurve()
        curve.points = all
            .filter { timeRange.contains($0.date) }
            .map { Point(date: $0.date, value: imperial ? $0.maxRangeKm / kmPerMile : $0.maxRangeKm) }
        if let first = all.first?.maxRangeKm, let last = all.last?.maxRangeKm, first > 0 {
            curve.lostPercent = max(0, (1 - last / first) * 100)
        }
        return curve
    }
}

struct TripCost: Sendable, Equatable {
    var electricCost: Double
    var fuelEquivalentCost: Double
    var savings: Double
    var pricePerKwh: Double
}

struct TripEnergyCostAllocation: Sendable, Equatable {
    var costsByDriveID: [Int: TripCost]
    /// Weighted acquisition cost of the energy that is currently stored in the battery. When
    /// history starts halfway through a battery, this safely falls back to the configured price.
    var currentBatteryPricePerKwh: Double
    var currentStoredEnergyKwh: Double
}

enum TripCostEngine {
    static func cost(
        for drive: DriveRecord,
        pricePerKwh: Double,
        fuelPricePerLiter: Double,
        fuelConsumptionLPer100km: Double
    ) -> TripCost? {
        let energy = energyKwh(for: drive)
        guard energy.isFinite, energy > 0, pricePerKwh.isFinite, pricePerKwh >= 0 else { return nil }
        let electric = energy * pricePerKwh
        let liters = drive.distanceKm / 100 * max(0, fuelConsumptionLPer100km)
        let fuel = liters * max(0, fuelPricePerLiter)
        return TripCost(electricCost: electric, fuelEquivalentCost: fuel, savings: fuel - electric, pricePerKwh: pricePerKwh)
    }

    static func energyKwh(for drive: DriveRecord) -> Double {
        if let energy = drive.energyConsumedKwh, energy.isFinite, energy > 0 { return energy }
        if let wh = drive.consumptionWhPerKm, wh.isFinite, wh > 0, drive.distanceKm.isFinite, drive.distanceKm > 0 {
            return wh * drive.distanceKm / 1000
        }
        return 0
    }

    /// Missing energy is unknown, so its distance must not dilute measured consumption.
    static func averageConsumptionWhPerKm(for drives: [DriveRecord]) -> Double? {
        var energy = 0.0, distance = 0.0
        for drive in drives where drive.distanceKm.isFinite && drive.distanceKm > 0 {
            let used = energyKwh(for: drive)
            guard used > 0 else { continue }
            energy += used
            distance += drive.distanceKm
        }
        return distance > 0 ? energy * 1000 / distance : nil
    }
}

/// Assigns the real acquisition cost of charged energy to each drive. Battery energy is mixed,
/// so a moving weighted-average inventory is more faithful than simply applying the last tariff:
/// every partial charge adds stored kWh at that session's effective cost and each drive consumes
/// from the resulting balance. SoC boundaries reconcile unrecorded parked losses and incomplete
/// history without ever inventing free energy.
enum TripEnergyCostLedger {
    static func costs(
        drives: [DriveRecord],
        charges: [ChargeRecord],
        pricing: ChargePricing,
        fuelPricePerLiter: Double,
        fuelConsumptionLPer100km: Double,
        usableCapacityKwh: Double? = nil
    ) -> [Int: TripCost] {
        allocation(drives: drives,
                   charges: charges,
                   pricing: pricing,
                   fuelPricePerLiter: fuelPricePerLiter,
                   fuelConsumptionLPer100km: fuelConsumptionLPer100km,
                   usableCapacityKwh: usableCapacityKwh).costsByDriveID
    }

    static func allocation(
        drives: [DriveRecord],
        charges: [ChargeRecord],
        pricing: ChargePricing,
        fuelPricePerLiter: Double,
        fuelConsumptionLPer100km: Double,
        usableCapacityKwh: Double? = nil,
        currentSoc: Int? = nil
    ) -> TripEnergyCostAllocation {
        let fallbackPrice = finiteNonnegative(pricing.defaultPricePerKwh)
        let capacity = resolvedCapacity(drives: drives, charges: charges, preferred: usableCapacityKwh)
        var inventory = Inventory(fallbackPrice: fallbackPrice)
        var result: [Int: TripCost] = [:]

        let events = drives.map(Event.drive) + charges.map(Event.charge)
        for event in events.sorted(by: eventOrder) {
            inventory.reconcile(toSoc: event.startSoc, capacityKwh: capacity)

            switch event {
            case .charge(let charge):
                let stored = finiteNonnegative(charge.energyAddedKwh)
                guard stored > 0 else {
                    inventory.reconcile(toSoc: charge.endBattery, capacityKwh: capacity)
                    continue
                }
                let sessionCost = finiteNonnegative(pricing.cost(for: charge))
                inventory.add(energyKwh: stored, cost: sessionCost)
                inventory.reconcile(toSoc: charge.endBattery,
                                    capacityKwh: capacity,
                                    addedEnergyPrice: sessionCost / stored)

            case .drive(let drive):
                let energy = finiteNonnegative(TripCostEngine.energyKwh(for: drive))
                guard energy > 0 else {
                    inventory.reconcile(toSoc: drive.endBattery, capacityKwh: capacity)
                    continue
                }
                let electric = inventory.consume(energyKwh: energy)
                let liters = finiteNonnegative(drive.distanceKm) / 100
                    * finiteNonnegative(fuelConsumptionLPer100km)
                let fuel = liters * finiteNonnegative(fuelPricePerLiter)
                result[drive.id] = TripCost(
                    electricCost: electric,
                    fuelEquivalentCost: fuel,
                    savings: fuel - electric,
                    pricePerKwh: electric / energy
                )
                inventory.reconcile(toSoc: drive.endBattery, capacityKwh: capacity)
            }
        }
        inventory.reconcile(toSoc: currentSoc, capacityKwh: capacity)
        return TripEnergyCostAllocation(costsByDriveID: result,
                                        currentBatteryPricePerKwh: inventory.unitPrice,
                                        currentStoredEnergyKwh: inventory.energyKwh)
    }

    private enum Event {
        case drive(DriveRecord)
        case charge(ChargeRecord)

        var date: Date {
            switch self {
            case .drive(let value): value.startDate
            case .charge(let value): value.startDate
            }
        }
        var startSoc: Int? {
            switch self {
            case .drive(let value): value.startBattery
            case .charge(let value): value.startBattery
            }
        }
        var endBattery: Int? {
            switch self {
            case .drive(let value): value.endBattery
            case .charge(let value): value.endBattery
            }
        }
    }

    private static func eventOrder(_ lhs: Event, _ rhs: Event) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        // If imported data shares a timestamp, make charged energy available before a drive.
        if case .charge = lhs, case .drive = rhs { return true }
        return false
    }

    static func resolvedCapacity(drives: [DriveRecord],
                                         charges: [ChargeRecord],
                                         preferred: Double?) -> Double? {
        if let preferred, preferred.isFinite, (20...150).contains(preferred) { return preferred }
        var candidates: [Double] = []
        for charge in charges {
            guard let start = charge.startBattery, let end = charge.endBattery,
                  end - start >= 10 else { continue }
            let value = finiteNonnegative(charge.energyAddedKwh) / (Double(end - start) / 100)
            if (20...150).contains(value) { candidates.append(value) }
        }
        for drive in drives {
            guard let start = drive.startBattery, let end = drive.endBattery,
                  start - end >= 5 else { continue }
            let value = finiteNonnegative(TripCostEngine.energyKwh(for: drive)) / (Double(start - end) / 100)
            if (20...150).contains(value) { candidates.append(value) }
        }
        guard !candidates.isEmpty else { return nil }
        candidates.sort()
        let middle = candidates.count / 2
        return candidates.count.isMultiple(of: 2)
            ? (candidates[middle - 1] + candidates[middle]) / 2
            : candidates[middle]
    }

    private static func finiteNonnegative(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    private struct Inventory {
        var energyKwh = 0.0
        var cost = 0.0
        /// Starts as the configured fallback and then tracks the most recent defensible
        /// acquisition value, so a gap in old history never turns residual energy into zero-cost.
        var fallbackPrice: Double

        var unitPrice: Double {
            energyKwh > 0.000_001 ? max(0, cost / energyKwh) : fallbackPrice
        }

        mutating func add(energyKwh: Double, cost: Double) {
            guard energyKwh > 0 else { return }
            let acquisitionPrice = max(0, cost) / energyKwh
            self.energyKwh += energyKwh
            self.cost += max(0, cost)
            fallbackPrice = acquisitionPrice
        }

        mutating func consume(energyKwh requested: Double) -> Double {
            guard requested > 0 else { return 0 }
            let price = unitPrice
            let available = min(requested, energyKwh)
            let knownCost = available * price
            energyKwh = max(0, energyKwh - available)
            cost = max(0, cost - knownCost)
            if energyKwh < 0.000_001 { energyKwh = 0; cost = 0 }
            fallbackPrice = price
            return knownCost + (requested - available) * price
        }

        mutating func reconcile(toSoc soc: Int?, capacityKwh: Double?, addedEnergyPrice: Double? = nil) {
            guard let soc, (0...100).contains(soc), let capacityKwh else { return }
            let expected = capacityKwh * Double(soc) / 100
            if expected < energyKwh {
                _ = consume(energyKwh: energyKwh - expected)
            } else if expected > energyKwh {
                let price = addedEnergyPrice.flatMap { $0.isFinite ? max(0, $0) : nil } ?? unitPrice
                add(energyKwh: expected - energyKwh, cost: (expected - energyKwh) * price)
            }
        }
    }
}

struct ParkingSession: Identifiable, Sendable, Codable, Hashable {
    var id: String
    var locationName: String
    var startDate: Date
    var endDate: Date?
    var startBattery: Int?
    var endBattery: Int?
    var startRangeKm: Double?
    var endRangeKm: Double?
    var coordinate: Coordinate?
    var energyLostKwh: Double
    var cost: Double
    var isLive: Bool

    var durationMinutes: Int {
        let end = endDate ?? Date()
        return max(0, Int(end.timeIntervalSince(startDate) / 60))
    }

    var rangeLostKm: Double {
        guard let startRangeKm, let endRangeKm else { return 0 }
        return max(0, startRangeKm - endRangeKm)
    }

    var socDelta: Int? {
        guard let startBattery, let endBattery else { return nil }
        return endBattery - startBattery
    }

    var whPerHour: Double? {
        let hours = Double(durationMinutes) / 60
        guard hours > 0, energyLostKwh > 0 else { return nil }
        return energyLostKwh * 1000 / hours
    }
}

enum ParkingSessionEngine {
    static func derive(
        drives: [DriveRecord],
        charges: [ChargeRecord],
        currentState: VehicleState?,
        pricePerKwh: Double,
        efficiencyKwhPerKm: Double?,
        usableCapacityKwh: Double? = nil,
        now: Date = Date(),
        minimumMinutes: Int = 30
    ) -> [ParkingSession] {
        let ordered = drives.sorted { $0.startDate < $1.startDate }
        let capacity = TripEnergyCostLedger.resolvedCapacity(drives: drives, charges: charges, preferred: usableCapacityKwh)
        let chargeIntervals = charges.compactMap { charge -> (start: Date, end: Date)? in
            let end = charge.endDate ?? now
            guard end > charge.startDate else { return nil }
            return (charge.startDate, end)
        }.sorted { $0.start < $1.start }
        var chargeIndex = 0
        var sessions: [ParkingSession] = []
        for pair in zip(ordered, ordered.dropFirst()) {
            let previous = pair.0
            let next = pair.1
            guard let start = previous.endDate else { continue }
            let end = next.startDate
            let minutes = Int(end.timeIntervalSince(start) / 60)
            guard minutes >= minimumMinutes else { continue }
            // Both gaps and charge intervals are chronological. Advancing one cursor changes
            // this from O(drives × charges) to O(drives + charges) on multi-year histories.
            while chargeIndex < chargeIntervals.count, chargeIntervals[chargeIndex].end <= start {
                chargeIndex += 1
            }
            if chargeIndex < chargeIntervals.count {
                let charge = chargeIntervals[chargeIndex]
                if charge.start < end, charge.end > start { continue }
            }
            let lost = energyLostKwh(startBattery: previous.endBattery,
                                     endBattery: next.startBattery,
                                     startRangeKm: previous.endRangeKm,
                                     endRangeKm: next.startRangeKm,
                                     efficiencyKwhPerKm: efficiencyKwhPerKm,
                                     usableCapacityKwh: capacity)
            sessions.append(ParkingSession(
                id: "park-\(Int(start.timeIntervalSince1970))-\(Int(end.timeIntervalSince1970))",
                locationName: previous.destinationName,
                startDate: start,
                endDate: end,
                startBattery: previous.endBattery,
                endBattery: next.startBattery,
                startRangeKm: previous.endRangeKm,
                endRangeKm: next.startRangeKm,
                coordinate: previous.endCoord ?? previous.path.last,
                energyLostKwh: lost,
                cost: lost * max(0, pricePerKwh),
                isLive: false
            ))
        }
        if let live = liveSession(from: currentState, pricePerKwh: pricePerKwh, now: now, minimumMinutes: minimumMinutes) {
            sessions.append(live)
        }
        return sessions.sorted { $0.startDate > $1.startDate }
    }

    private static func liveSession(from state: VehicleState?, pricePerKwh: Double, now: Date, minimumMinutes: Int) -> ParkingSession? {
        guard let state, !state.isDriving, !state.isCharging, let start = state.since else { return nil }
        let minutes = Int(now.timeIntervalSince(start) / 60)
        guard minutes >= minimumMinutes else { return nil }
        return ParkingSession(
            id: "live-\(state.carID)",
            locationName: state.geofence ?? state.displayName ?? L("Current location"),
            startDate: start,
            endDate: nil,
            startBattery: state.batteryLevel,
            endBattery: state.batteryLevel,
            startRangeKm: state.range(for: .rated),
            endRangeKm: state.range(for: .rated),
            coordinate: state.coordinate,
            energyLostKwh: 0,
            cost: 0 * max(0, pricePerKwh),
            isLive: true
        )
    }

    private static func energyLostKwh(startBattery: Int?, endBattery: Int?, startRangeKm: Double?, endRangeKm: Double?, efficiencyKwhPerKm: Double?, usableCapacityKwh: Double?) -> Double {
        if let startBattery, let endBattery, (0...100).contains(startBattery), (0...100).contains(endBattery),
           startBattery > endBattery, let usableCapacityKwh {
            return Double(startBattery - endBattery) / 100 * usableCapacityKwh
        }
        if let startRangeKm, let endRangeKm, startRangeKm > endRangeKm, let efficiencyKwhPerKm, efficiencyKwhPerKm > 0 {
            return (startRangeKm - endRangeKm) * efficiencyKwhPerKm
        }
        return 0
    }

}

enum EventInboxCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case vehicle, tesstats

    var id: String { rawValue }
    var label: String {
        switch self {
        case .vehicle: L("Vehicle")
        case .tesstats: L("Tesstats")
        }
    }
}

struct EventInboxItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var date: Date
    var category: EventInboxCategory
    var title: String
    var body: String
    var symbol: String
    var chargeRoute: ChargeNotificationRoute? = nil
}
