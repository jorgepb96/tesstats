import XCTest
@testable import Tesstats

/// The editor only ever lets the user set a band's START time; ends are derived so the day is
/// always fully covered. These pin that contract.
final class TariffPlanTests: XCTestCase {

    private func band(_ start: Int, _ buy: Double = 0.1, kind: TariffBandKind = .flat) -> TariffBand {
        TariffBand(kind: kind, startMinute: start, endMinute: 0, buyPricePerKwh: buy)
    }

    func testBandsTileTheWholeDay() {
        let plan = TariffPlan(name: "P", bands: [band(22 * 60), band(0), band(8 * 60)]).normalized()
        XCTAssertEqual(plan.bands.map(\.startMinute), [0, 8 * 60, 22 * 60])
        XCTAssertEqual(plan.bands.map(\.endMinute), [8 * 60, 22 * 60, 0])
        // Every minute of the day belongs to exactly one band.
        for minute in stride(from: 0, to: 1440, by: 7) {
            let owners = plan.bands.filter { $0.contains(minuteOfDay: minute) }
            XCTAssertEqual(owners.count, 1, "minute \(minute) owned by \(owners.count) bands")
        }
        XCTAssertEqual(plan.bands.reduce(0) { $0 + $1.durationMinutes }, 1440)
    }

    func testSingleBandCoversEverything() {
        let plan = TariffPlan(name: "P", bands: [band(9 * 60, 0.21)]).normalized()
        XCTAssertEqual(plan.bands.count, 1)
        for minute in stride(from: 0, to: 1440, by: 13) {
            XCTAssertTrue(plan.bands[0].contains(minuteOfDay: minute))
        }
        XCTAssertEqual(plan.bands[0].durationMinutes, 1440)
    }

    func testAddingABandRetilesTheRest() {
        var plan = TariffPlan(name: "P", bands: [band(0, 0.08), band(12 * 60, 0.25)]).normalized()
        XCTAssertEqual(plan.bands.map(\.endMinute), [12 * 60, 0])

        plan.bands.append(band(plan.suggestedStartForNewBand(), 0.15))
        plan = plan.normalized()

        XCTAssertEqual(plan.bands.count, 3)
        XCTAssertEqual(plan.bands.reduce(0) { $0 + $1.durationMinutes }, 1440, "day must stay fully covered")
        for minute in stride(from: 0, to: 1440, by: 11) {
            XCTAssertEqual(plan.bands.filter { $0.contains(minuteOfDay: minute) }.count, 1)
        }
    }

    func testRemovingABandRetilesTheRest() {
        var plan = TariffPlan(name: "P", bands: [band(0), band(8 * 60), band(20 * 60)]).normalized()
        plan.bands.remove(at: 1)
        plan = plan.normalized()
        XCTAssertEqual(plan.bands.map(\.startMinute), [0, 20 * 60])
        XCTAssertEqual(plan.bands.reduce(0) { $0 + $1.durationMinutes }, 1440)
    }

    func testDuplicateStartsCollapse() {
        let plan = TariffPlan(name: "P", bands: [band(60), band(60), band(600)]).normalized()
        XCTAssertEqual(plan.bands.count, 2)
        XCTAssertEqual(plan.bands.reduce(0) { $0 + $1.durationMinutes }, 1440)
    }

    func testSellPriceDefaultsToBuy() {
        var b = band(0, 0.19)
        XCTAssertEqual(b.effectiveSellPrice, 0.19, accuracy: 0.0001)
        b.sellPricePerKwh = 0.05
        XCTAssertEqual(b.effectiveSellPrice, 0.05, accuracy: 0.0001)
    }

    func testBuyPriceLooksUpTheRightBandAcrossMidnight() {
        let cal = Calendar(identifier: .gregorian)
        let plan = TariffPlan(name: "P", bands: [
            band(0, 0.08, kind: .valley),
            band(8 * 60, 0.15, kind: .flat),
            band(20 * 60, 0.30, kind: .peak)
        ]).normalized()
        func priceAt(_ hour: Int) -> Double {
            let date = cal.date(from: DateComponents(year: 2026, month: 7, day: 30, hour: hour, minute: 30))!
            return plan.buyPrice(at: date, defaultPrice: 0.99, calendar: cal)
        }
        XCTAssertEqual(priceAt(3), 0.08, accuracy: 0.0001)
        XCTAssertEqual(priceAt(12), 0.15, accuracy: 0.0001)
        XCTAssertEqual(priceAt(23), 0.30, accuracy: 0.0001)
        XCTAssertEqual(priceAt(7), 0.08, accuracy: 0.0001)
    }

    func testActivePlanDrivesChargePricing() {
        var config = ServerConfig()
        config.chargePricePerKwh = 0.99
        config.tariffEnabled = true
        let plan = TariffPlan(name: "Night", bands: [
            band(0, 0.05, kind: .valley), band(8 * 60, 0.40, kind: .peak)
        ]).normalized()
        config.tariffPlans = [plan]
        config.activeTariffPlanID = plan.id.uuidString

        let pricing = ChargePricing(config: config)
        let cal = Calendar(identifier: .gregorian)
        let start = cal.date(from: DateComponents(year: 2026, month: 7, day: 30, hour: 2))!
        let charge = ChargeRecord(id: 1, startDate: start, endDate: start.addingTimeInterval(3600),
                                  address: "Home", geofence: "Home", energyAddedKwh: 10,
                                  startBattery: 40, endBattery: 60, startRangeKm: 200, endRangeKm: 300,
                                  durationMin: 60, cost: nil, energyUsedKwh: nil, outsideTempAvg: nil,
                                  odometerKm: nil, avgPowerKw: 10, coord: nil, isFastCharger: false)
        // Charged entirely inside the off-peak band.
        XCTAssertEqual(pricing.cost(for: charge), 0.5, accuracy: 0.01)
    }

    func testLegacyBandsMigrateIntoAPlan() {
        var config = ServerConfig()
        config.tariffEnabled = true
        config.tariffPeriods = [TariffPeriod(startMinute: 0, endMinute: 480, pricePerKwh: 0.07),
                                TariffPeriod(startMinute: 480, endMinute: 1440, pricePerKwh: 0.2)]
        // Before migrating, the old list still prices charges.
        XCTAssertNotNil(config.activeTariff)

        config.migrateLegacyTariffIfNeeded()
        XCTAssertEqual(config.tariffPlans.count, 1)
        XCTAssertEqual(config.tariffPlans[0].bands.count, 2)
        XCTAssertEqual(config.activeTariffPlanID, config.tariffPlans[0].id.uuidString)
        XCTAssertEqual(config.tariffPlans[0].bands.map(\.buyPricePerKwh), [0.07, 0.2])
        // Migrating twice must not duplicate.
        config.migrateLegacyTariffIfNeeded()
        XCTAssertEqual(config.tariffPlans.count, 1)
    }
}
