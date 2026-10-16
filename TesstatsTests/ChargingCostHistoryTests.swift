import XCTest
@testable import Tesstats

final class ChargingCostHistoryTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return value
    }
    private func date(_ year: Int, _ month: Int, _ day: Int = 1, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    private func charge(_ id: Int, _ date: Date, place: String = "Home", cost: Double? = 10) -> ChargeRecord {
        ChargeRecord(id: id, startDate: date, endDate: date.addingTimeInterval(3600),
                     geofence: place, energyAddedKwh: 10, durationMin: 60,
                     cost: cost, energyUsedKwh: 12, isFastCharger: false)
    }

    func testMultipleExactPlacesAndMissingMonthsSumToPeriodTotal() {
        var filter = ChargingCostFilter(now: date(2026, 3), calendar: calendar)
        filter.locations = ["Home", "Work"]
        let result = ChargingCostHistory.make(charges: [
            charge(1, date(2026, 1), cost: 7),
            charge(2, date(2026, 1, 2), place: "Work", cost: 5),
            charge(3, date(2026, 3), cost: 9),
            charge(4, date(2026, 3), place: "Homework", cost: 100),
            charge(5, date(2025, 12), cost: 100)
        ], pricing: ChargePricing(defaultPricePerKwh: 0.3), filter: filter, calendar: calendar)
        XCTAssertEqual(result.months.map(\.cost), [12, 0, 9])
        XCTAssertEqual(result.total, 21)
        XCTAssertEqual(result.sessions, 3)
        XCTAssertEqual(result.months.reduce(0) { $0 + $1.cost }, result.total)
    }

    func testDayRangeIncludesLastDayButNotFollowingMidnightAcrossDST() {
        var filter = ChargingCostFilter(now: date(2026, 3, 29), calendar: calendar)
        filter.period = .days
        filter.start = date(2026, 3, 29)
        filter.end = filter.start
        let interval = filter.interval(calendar: calendar)!
        XCTAssertEqual(interval.duration, 23 * 3600)
        let result = ChargingCostHistory.make(charges: [
            charge(1, interval.start), charge(2, interval.end.addingTimeInterval(-1)),
            charge(3, interval.end), charge(4, interval.start.addingTimeInterval(-1))
        ], pricing: ChargePricing(defaultPricePerKwh: 0.3), filter: filter, calendar: calendar)
        XCTAssertEqual(result.sessions, 2)
        XCTAssertEqual(result.total, 20)
    }

    func testMonthAndYearSelectionsIncludeEntireFinalUnit() {
        var filter = ChargingCostFilter(now: date(2026, 2, 3), calendar: calendar)
        filter.start = date(2025, 12, 20)
        let interval = filter.interval(calendar: calendar)!
        XCTAssertEqual(interval.start, date(2025, 12, 1, 0))
        XCTAssertEqual(interval.end, date(2026, 3, 1, 0))
        filter.period = .years
        XCTAssertEqual(filter.interval(calendar: calendar)?.start, date(2025, 1, 1, 0))
        XCTAssertEqual(filter.interval(calendar: calendar)?.end, date(2027, 1, 1, 0))
        let result = ChargingCostHistory.make(charges: [], pricing: ChargePricing(defaultPricePerKwh: 0.3),
                                             filter: filter, calendar: calendar)
        XCTAssertEqual(result.months.count, 24)
        XCTAssertEqual(result.sessions, 0)
    }

    func testSameMonthIgnoresDayOrderingButReversedMonthsAreInvalid() {
        var filter = ChargingCostFilter(now: date(2026, 2, 1), calendar: calendar)
        filter.start = date(2026, 2, 28)
        XCTAssertNotNil(filter.interval(calendar: calendar))
        filter.start = date(2026, 3)
        XCTAssertNil(filter.interval(calendar: calendar))
        XCTAssertTrue(ChargingCostHistory.make(charges: [], pricing: ChargePricing(defaultPricePerKwh: 0.3),
                                              filter: filter, calendar: calendar).months.isEmpty)
    }

    func testEffectiveCostsPreserveRecordedFreeAndLocationPrices() {
        let filter = ChargingCostFilter(now: date(2026, 1), calendar: calendar)
        let pricing = ChargePricing(defaultPricePerKwh: 0.3, perLocation: ["Free": 0, "Home": 0.2])
        let result = ChargingCostHistory.make(charges: [
            charge(1, date(2026, 1), cost: nil),
            charge(2, date(2026, 1), place: "Free", cost: nil),
            charge(3, date(2026, 1), place: "Free", cost: 5),
            charge(4, date(2026, 1), place: "Other", cost: nil)
        ], pricing: pricing, filter: filter, calendar: calendar)
        XCTAssertEqual(result.total, 11, accuracy: 0.0001)
        XCTAssertEqual(result.estimatedSessions, 3)
        XCTAssertEqual(result.sessions, 4)
    }

    func testNewBlockAppearsInExistingCustomLayoutsAndCanBeHidden() {
        let old = SectionLayoutState(order: ["filters", "totals", "list", "map", "places"])
        XCTAssertEqual(SectionLayout.resolved(ChargingBlock.self, layout: old)[1], .monthlyCost)
        var hidden = old
        hidden.hidden = ["monthlyCost"]
        XCTAssertFalse(SectionLayout.visible(ChargingBlock.self, layout: hidden).contains(.monthlyCost))
    }
}
