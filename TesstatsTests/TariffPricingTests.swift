import XCTest
@testable import Tesstats

final class TariffPricingTests: XCTestCase {

    private let cal = Calendar.current

    private func date(hour: Int, minute: Int = 0) -> Date {
        cal.date(bySettingHour: hour, minute: minute, second: 0, of: Date(timeIntervalSince1970: 1_750_000_000))!
    }

    // MARK: TariffPeriod

    func testPeriodContainsSimpleAndWrappingBands(){
        let day = TariffPeriod(startMinute: 8 * 60, endMinute: 20 * 60, pricePerKwh: 0.20)
        XCTAssertTrue(day.contains(minuteOfDay: 8 * 60))
        XCTAssertTrue(day.contains(minuteOfDay: 12 * 60))
        XCTAssertFalse(day.contains(minuteOfDay: 20 * 60))   // end exclusive
        XCTAssertFalse(day.contains(minuteOfDay: 3 * 60))

        let night = TariffPeriod(startMinute: 22 * 60, endMinute: 6 * 60, pricePerKwh: 0.08)
        XCTAssertTrue(night.contains(minuteOfDay: 23 * 60))
        XCTAssertTrue(night.contains(minuteOfDay: 0))
        XCTAssertTrue(night.contains(minuteOfDay: 5 * 60))
        XCTAssertFalse(night.contains(minuteOfDay: 6 * 60))
        XCTAssertFalse(night.contains(minuteOfDay: 12 * 60))

        let empty = TariffPeriod(startMinute: 300, endMinute: 300, pricePerKwh: 0.5)
        XCTAssertFalse(empty.contains(minuteOfDay: 300))
    }

    // MARK: TimeOfUseTariff

    func testAveragePriceWeightsBandsByOverlap() {
        // Night band 00:00–08:00 at 0.08; everything else falls to the 0.20 default.
        let tariff = TimeOfUseTariff(periods: [TariffPeriod(startMinute: 0, endMinute: 8 * 60, pricePerKwh: 0.08)])

        // Session 22:00 → 02:00: 120 min at 0.20 + 120 min at 0.08 → 0.14 average.
        let start = date(hour: 22)
        let interval = DateInterval(start: start, duration: 4 * 3600)
        let avg = tariff.averagePrice(for: interval, defaultPrice: 0.20, calendar: cal)
        XCTAssertEqual(avg, 0.14, accuracy: 0.005)

        // Session fully inside the band.
        let inside = DateInterval(start: date(hour: 1), duration: 2 * 3600)
        XCTAssertEqual(tariff.averagePrice(for: inside, defaultPrice: 0.20, calendar: cal), 0.08, accuracy: 0.001)
    }

    // MARK: ChargePricing resolution order

    private func makeCharge(cost: Double?, start: Date, minutes: Int, location: String = "Home") -> ChargeRecord {
        ChargeRecord(
            id: 1, startDate: start, endDate: start.addingTimeInterval(Double(minutes) * 60),
            address: location, geofence: location,
            energyAddedKwh: 10,
            startBattery: 50, endBattery: 80,
            startRangeKm: nil, endRangeKm: nil,
            durationMin: minutes, cost: cost,
            energyUsedKwh: nil, outsideTempAvg: nil, odometerKm: nil,
            avgPowerKw: 11, coord: nil, isFastCharger: false
        )
    }

    func testRecordedCostBeatsEverything() {
        let pricing = ChargePricing(defaultPricePerKwh: 0.20,
                                    perLocation: ["Home": 0.10],
                                    tariff: TimeOfUseTariff(periods: [TariffPeriod(startMinute: 0, endMinute: 1439, pricePerKwh: 0.01)]))
        let charge = makeCharge(cost: 4.20, start: date(hour: 1), minutes: 60)
        XCTAssertEqual(pricing.cost(for: charge), 4.20, accuracy: 0.001)
    }

    func testLocationOverrideBeatsTariff() {
        let pricing = ChargePricing(defaultPricePerKwh: 0.20,
                                    perLocation: ["Home": 0.10],
                                    tariff: TimeOfUseTariff(periods: [TariffPeriod(startMinute: 0, endMinute: 1439, pricePerKwh: 0.01)]))
        let charge = makeCharge(cost: nil, start: date(hour: 1), minutes: 60)
        XCTAssertEqual(pricing.cost(for: charge), 1.0, accuracy: 0.001)   // 10 kWh × 0.10
    }

    func testFreeLocationOverrideIsStoredAndBeatsEveryFallback() {
        XCTAssertEqual(ChargePriceInput.value(from: "0"), 0)
        XCTAssertEqual(ChargePriceInput.value(from: " 0,00 "), 0)
        XCTAssertNil(ChargePriceInput.value(from: ""))
        XCTAssertNil(ChargePriceInput.value(from: "-0.01"))
        XCTAssertNil(ChargePriceInput.value(from: "nan"))

        let pricing = ChargePricing(defaultPricePerKwh: 0.20,
                                    perLocation: ["Free charger": 0],
                                    tariff: TimeOfUseTariff(periods: [
                                        TariffPeriod(startMinute: 0, endMinute: 1439, pricePerKwh: 0.10)
                                    ]))
        let charge = makeCharge(cost: nil, start: date(hour: 12), minutes: 60,
                                location: "Free charger")
        XCTAssertEqual(pricing.price(for: "Free charger"), 0)
        XCTAssertEqual(pricing.cost(for: charge), 0)
    }

    func testTariffPricesUnpricedSessionByTimeOfDay() {
        // Night 00–08 at 0.08, default 0.20. Session 22:00→02:00, 10 kWh → 10 × 0.14.
        let pricing = ChargePricing(defaultPricePerKwh: 0.20,
                                    perLocation: [:],
                                    tariff: TimeOfUseTariff(periods: [TariffPeriod(startMinute: 0, endMinute: 8 * 60, pricePerKwh: 0.08)]))
        let charge = makeCharge(cost: nil, start: date(hour: 22), minutes: 240)
        XCTAssertEqual(pricing.cost(for: charge), 1.4, accuracy: 0.05)
    }

    func testNoTariffFallsBackToDefaultPrice() {
        let pricing = ChargePricing(defaultPricePerKwh: 0.20)
        let charge = makeCharge(cost: nil, start: date(hour: 22), minutes: 240)
        XCTAssertEqual(pricing.cost(for: charge), 2.0, accuracy: 0.001)
    }

    func testEstimatedChargeCostIncludesMeteredChargingLosses() {
        let pricing = ChargePricing(defaultPricePerKwh: 0.20)
        var charge = makeCharge(cost: nil, start: date(hour: 22), minutes: 60)
        charge.energyUsedKwh = 12

        XCTAssertEqual(pricing.cost(for: charge), 2.4, accuracy: 0.001)
        XCTAssertEqual(pricing.billedEnergyKwh(for: charge), 12, accuracy: 0.001)

        charge.energyUsedKwh = 8 // impossible: grid energy cannot be below stored energy
        XCTAssertEqual(pricing.cost(for: charge), 2.0, accuracy: 0.001)
    }

    func testPricingFromConfigRespectsEnableFlag() {
        var config = ServerConfig()
        config.chargePricePerKwh = 0.20
        config.tariffPeriods = [TariffPeriod(startMinute: 0, endMinute: 1439, pricePerKwh: 0.05)]

        config.tariffEnabled = false
        XCTAssertNil(ChargePricing(config: config).tariff)

        config.tariffEnabled = true
        XCTAssertNotNil(ChargePricing(config: config).tariff)
    }
}
