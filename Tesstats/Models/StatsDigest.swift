import Foundation

/// Everything the Stats screen draws, computed in one pass.
///
/// These aggregations used to live on `StatsView` as computed properties, so a single SwiftUI
/// body evaluation re-filtered the history eleven times and re-ran every engine — about a
/// second of main-thread work on a multi-year history, on every redraw. Now the view holds a
/// digest in `@State` and only rebuilds it when `StatsDigestKey` changes, off the main actor.
struct StatsDigest: Sendable {
    var drives: [DriveRecord] = []
    var charges: [ChargeRecord] = []
    var comparison: PeriodComparison?
    var monthly: [MonthlyStat] = []
    /// Whole-history months — the year-over-year overlay compares calendar years, so it must
    /// not depend on the range filter.
    var monthlyAllTime: [MonthlyStat] = []
    var cost: CostSummary = .init()
    var eco: EcoImpact = .init()
    var tempPoints: [TempConsumptionPoint] = []
    var tempBins: [TempBin] = []
    var weekdays: [WeekdayUsage] = []
    var hours: [HourUsage] = []
    var heatmap: [CalendarDay] = []
    var drain: PhantomDrain?
    var chargingLocations: [ChargingLocation] = []
    var records: Superlatives = .init()

    var isEmpty: Bool { drives.isEmpty && charges.isEmpty }

    static func make(allDrives: [DriveRecord],
                     allCharges: [ChargeRecord],
                     range: StatsRange,
                     pricing: ChargePricing,
                     fuelLPer100km: Double,
                     now: Date = Date()) -> StatsDigest {
        // Filter once — every engine below reuses these two arrays.
        let drives = allDrives.filter { range.contains($0.startDate, now: now) }
        let charges = allCharges.filter { range.contains($0.startDate, now: now) }

        var digest = StatsDigest()
        digest.drives = drives
        digest.charges = charges
        digest.comparison = StatsEngine.monthOverMonth(drives: allDrives, charges: allCharges, pricing: pricing, now: now)
        digest.monthly = StatsEngine.monthly(drives: drives, charges: charges, pricing: pricing)
        digest.monthlyAllTime = StatsEngine.monthly(drives: allDrives, charges: allCharges, pricing: pricing)
        let observationEnd = min(now, range.interval(now: now)?.end ?? now)
        digest.cost = StatsEngine.cost(drives: drives, charges: charges, pricing: pricing, now: observationEnd)
        digest.eco = StatsEngine.eco(drives: drives, fuelLPer100km: fuelLPer100km)
        digest.tempPoints = StatsEngine.tempConsumption(drives)
        digest.tempBins = StatsEngine.tempBins(digest.tempPoints)
        digest.weekdays = StatsEngine.weekdayUsage(drives)
        digest.hours = StatsEngine.hourUsage(drives)
        digest.heatmap = StatsEngine.calendarHeatmap(drives, now: now)
        digest.drain = StatsEngine.phantomDrain(drives: drives, charges: charges)
        digest.chargingLocations = StatsEngine.chargingLocations(charges, pricing: pricing)
        digest.records = StatsEngine.superlatives(drives: drives, charges: charges)
        return digest
    }
}

/// Identity of a digest: change any of these and the digest must be rebuilt, nothing else does.
struct StatsDigestKey: Equatable, Sendable {
    var revision: Int
    var range: StatsRange
    var pricing: ChargePricing
    var fuelLPer100km: Double
}
