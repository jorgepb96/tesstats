import Foundation

struct ChargingCostFilter: Equatable, Sendable {
    enum Period: String, CaseIterable, Identifiable, Sendable {
        case days, months, years
        var id: String { rawValue }
        var component: Calendar.Component {
            switch self { case .days: .day; case .months: .month; case .years: .year }
        }
        var title: String {
            switch self { case .days: L("Days"); case .months: L("Months"); case .years: L("Years") }
        }
    }
    var period: Period = .months
    var start: Date
    var end: Date
    /// Empty means all places. Selection uses exact names, never the search text.
    var locations: Set<String> = []

    init(now: Date = Date(), calendar: Calendar = .current) {
        start = calendar.dateInterval(of: .year, for: now)?.start ?? now
        end = now
    }

    /// Inclusive days/months/years represented as a half-open interval, including DST.
    func interval(calendar: Calendar = .current) -> DateInterval? {
        guard let first = calendar.dateInterval(of: period.component, for: start),
              let last = calendar.dateInterval(of: period.component, for: end),
              first.start <= last.start else { return nil }
        return DateInterval(start: first.start, end: last.end)
    }
}

struct ChargingCostHistory: Sendable {
    struct Month: Identifiable, Sendable {
        let start: Date
        var cost: Double = 0
        var sessions: Int = 0
        var id: Date { start }
    }
    var months: [Month] = []
    var total: Double = 0
    var sessions: Int = 0
    var estimatedSessions: Int = 0

    static func make(charges: [ChargeRecord], pricing: ChargePricing,
                     filter: ChargingCostFilter, calendar: Calendar = .current) -> Self {
        guard let interval = filter.interval(calendar: calendar),
              var month = calendar.dateInterval(of: .month, for: interval.start)?.start else { return Self() }
        var result = Self()
        var buckets: [Date: Month] = [:]
        for charge in charges {
            guard charge.startDate >= interval.start, charge.startDate < interval.end,
                  filter.locations.isEmpty || filter.locations.contains(charge.locationName),
                  let key = calendar.dateInterval(of: .month, for: charge.startDate)?.start else { continue }
            let resolved = pricing.resolution(for: charge)
            var bucket = buckets[key] ?? Month(start: key)
            bucket.cost += resolved.cost
            bucket.sessions += 1
            buckets[key] = bucket
            result.total += resolved.cost
            result.sessions += 1
            if resolved.isEstimated { result.estimatedSessions += 1 }
        }
        // Include zero-cost months so missing activity cannot distort the time axis.
        while month < interval.end {
            result.months.append(buckets[month] ?? Month(start: month))
            guard let next = calendar.date(byAdding: .month, value: 1, to: month), next > month else { break }
            month = next
        }
        return result
    }
}
