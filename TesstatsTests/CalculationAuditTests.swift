import XCTest
@testable import Tesstats

final class CalculationAuditTests: XCTestCase {
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 12))!

    func testChargingEfficiencyAndLossUseOnlyMatchingMeteredSessions() {
        var metered = charge(id: 1, added: 18)
        metered.energyUsedKwh = 20
        let unmetered = charge(id: 2, added: 40)
        let totals = ChargeAggregates.from([metered, unmetered])
        XCTAssertEqual(totals.totalEnergyKwh, 58)
        XCTAssertEqual(totals.totalEnergyUsedKwh, 20)
        XCTAssertEqual(totals.chargingEfficiency!, 0.9, accuracy: 0.000001)
        XCTAssertEqual(totals.lossKwh!, 2, accuracy: 0.000001)
        XCTAssertNil(ChargeAggregates.from([unmetered]).chargingEfficiency)
        XCTAssertNil(ChargeAggregates.from([unmetered]).lossKwh)
    }

    func testImpossibleGridMeasurementIsUnknownInsteadOfPerfectEfficiency() {
        var c = charge(added: 20)
        c.energyUsedKwh = 10
        XCTAssertNil(c.chargingEfficiency)
        XCTAssertNil(ChargeAggregates.from([c]).chargingEfficiency)
        c.energyUsedKwh = .infinity
        XCTAssertNil(c.chargingEfficiency)
    }

    func testMeteredSessionWithNoStoredEnergyIncludesAllItsLosses() {
        var c = charge(added: 0)
        c.energyUsedKwh = 2
        XCTAssertEqual(c.chargingEfficiency, 0)
        XCTAssertEqual(ChargeAggregates.from([c]).lossKwh, 2)
        XCTAssertEqual(ChargePricing(defaultPricePerKwh: 0.25).cost(for: c), 0.5)
    }

    func testMixedRecordedEstimatedAndFreeCostsShareBilledEnergyDenominator() {
        var paid = charge(id: 1, added: 18)
        paid.energyUsedKwh = 20
        paid.cost = 6
        var estimated = charge(id: 2, added: 9)
        estimated.energyUsedKwh = 10
        var free = charge(id: 3, added: 5)
        free.geofence = "Free"
        let pricing = ChargePricing(defaultPricePerKwh: 0.2, perLocation: ["Free": 0])
        let summary = StatsEngine.cost(drives: [drive(distance: 100)], charges: [paid, estimated, free], pricing: pricing, now: now)
        XCTAssertEqual(summary.totalCost, 8, accuracy: 0.000001)
        XCTAssertEqual(summary.costPer100Km!, 8, accuracy: 0.000001)
        XCTAssertEqual(summary.avgPricePerKwh!, 8 / 35, accuracy: 0.000001)
        XCTAssertTrue(summary.costIsEstimated)
        XCTAssertFalse(StatsEngine.cost(drives: [], charges: [paid], pricing: pricing).costIsEstimated)
        XCTAssertEqual(StatsEngine.cost(drives: [], charges: [free], pricing: pricing).avgPricePerKwh, 0)
    }

    func testEveryPositiveRecordedCostHasPrecedenceEvenOneCent() {
        var c = charge(added: 10)
        c.cost = 0.01
        let result = ChargePricing(defaultPricePerKwh: 0.5).resolution(for: c)
        XCTAssertEqual(result.cost, 0.01)
        XCTAssertEqual(result.source, "recorded")
        XCTAssertFalse(result.isEstimated)
    }

    func testTariffsWeightPartialMinutesAndSubMinuteSessionsExactly() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = cal.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 7, minute: 59, second: 45))!
        let interval = DateInterval(start: start, duration: 60)
        let tariff = TimeOfUseTariff(periods: [TariffPeriod(startMinute: 0, endMinute: 480, pricePerKwh: 0.1)])
        let plan = TariffPlan(bands: [
            TariffBand(startMinute: 0, buyPricePerKwh: 0.1),
            TariffBand(startMinute: 480, buyPricePerKwh: 0.3)
        ])
        XCTAssertEqual(tariff.averagePrice(for: interval, defaultPrice: 0.3, calendar: cal), 0.25, accuracy: 0.000001)
        XCTAssertEqual(plan.averageBuyPrice(for: interval, defaultPrice: 0.3, calendar: cal), 0.25, accuracy: 0.000001)
        XCTAssertEqual(tariff.averagePrice(for: DateInterval(start: start, duration: 30), defaultPrice: 0.3, calendar: cal), 0.2, accuracy: 0.000001)
    }

    func testTariffsWeightActualElapsedTimeThroughBothDSTTransitions() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let tariff = TimeOfUseTariff(periods: [TariffPeriod(startMinute: 0, endMinute: 180, pricePerKwh: 0.1)])
        for (month, day, cheapHours) in [(3, 29, 2.0), (10, 25, 4.0)] {
            let start = cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: 0))!
            let end = cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: 4))!
            let interval = DateInterval(start: start, end: end)
            XCTAssertEqual(tariff.averagePrice(for: interval, defaultPrice: 0.3, calendar: cal),
                           (cheapHours * 0.1 + 0.3) / (cheapHours + 1), accuracy: 0.000001)
        }
    }

    func testDistanceWeightedConsumptionIgnoresMissingMeasurements() {
        var short = drive(id: 1, distance: 10)
        short.consumptionWhPerKm = 300
        short.energyConsumedKwh = 3
        var long = drive(id: 2, distance: 90)
        long.consumptionWhPerKm = 100
        long.energyConsumedKwh = 9
        var missing = drive(id: 3, distance: 100)
        missing.consumptionWhPerKm = nil
        missing.energyConsumedKwh = nil
        let records = [short, long, missing]
        XCTAssertEqual(EfficiencySummary.from(records).avgWhPerKm, 120, accuracy: 0.000001)
        XCTAssertEqual(TripCostEngine.averageConsumptionWhPerKm(for: records)!, 120, accuracy: 0.000001)
        XCTAssertEqual(StatsEngine.monthly(drives: records, charges: [], pricing: .init(defaultPricePerKwh: 0.2))[0].avgConsumptionWhPerKm, 120, accuracy: 0.000001)
        XCTAssertNil(TripCostEngine.averageConsumptionWhPerKm(for: [missing]))
    }

    func testCostOfTripAtFreePriceIsZeroWithFuelSavings() {
        let cost = TripCostEngine.cost(for: drive(distance: 100), pricePerKwh: 0, fuelPricePerLiter: 2, fuelConsumptionLPer100km: 6)
        XCTAssertEqual(cost?.electricCost, 0)
        XCTAssertEqual(cost?.savings, 12)
    }

    func testSmallChargeStillProducesMonthComparison() {
        let comparison = StatsEngine.monthOverMonth(drives: [], charges: [charge(added: 0.2)], pricing: .init(defaultPricePerKwh: 0.2), now: now)
        XCTAssertEqual(comparison?.energyKwh.current, 0.2)
    }

    func testDigestUsesItsSuppliedDateForComparisonProjectionAndHeatmap() {
        var c = charge(added: 10)
        c.startDate = now.addingTimeInterval(-10 * 86400)
        c.cost = 10
        let digest = StatsDigest.make(allDrives: [drive(distance: 100)], allCharges: [c], range: StatsRange(), pricing: .init(defaultPricePerKwh: 0.2), fuelLPer100km: 6, now: now)
        XCTAssertEqual(digest.comparison?.distanceKm.current, 100)
        XCTAssertEqual(digest.cost.monthlyProjection!, 30.4, accuracy: 0.000001)
        XCTAssertEqual(digest.heatmap.last?.day, Calendar.current.startOfDay(for: now))
    }

    func testPhantomDrainIsTotalLossDividedByTotalObservedIdleTime() {
        let first = drive(id: 1, distance: 10)
        var second = drive(id: 2, distance: 10)
        second.startDate = first.endDate!.addingTimeInterval(86400)
        second.endDate = second.startDate.addingTimeInterval(600)
        second.startBattery = 74
        second.endBattery = 70
        second.startRangeKm = 296
        second.endRangeKm = 280
        var third = drive(id: 3, distance: 10)
        third.startDate = second.endDate!.addingTimeInterval(3 * 86400)
        third.startBattery = 64
        third.startRangeKm = 256
        let drain = StatsEngine.phantomDrain(drives: [third, first, second], charges: [])!
        XCTAssertEqual(drain.avgPercentPerDay, 3, accuracy: 0.000001)
        XCTAssertEqual(drain.avgRangeLossKmPerDay, 12, accuracy: 0.000001)
        XCTAssertEqual(drain.totalIdleDays, 4)
    }

    func testPhantomDrainExcludesChargeThatStartsAtOrBeforeParkingBoundary() {
        let first = drive(id: 1, distance: 10)
        var second = drive(id: 2, distance: 10)
        second.startDate = first.endDate!.addingTimeInterval(86400)
        second.startBattery = 70
        for offset in [0.0, -300.0] {
            var c = charge(added: 10)
            c.startDate = first.endDate!.addingTimeInterval(offset)
            c.endDate = first.endDate!.addingTimeInterval(1800)
            XCTAssertNil(StatsEngine.phantomDrain(drives: [first, second], charges: [c]))
        }
    }

    func testParkingUsesVehicleCapacityAndExcludesUnfinishedCharge() {
        let first = drive(id: 1, distance: 10)
        var second = drive(id: 2, distance: 10)
        second.startDate = first.endDate!.addingTimeInterval(7200)
        second.startBattery = 78
        let sessions = ParkingSessionEngine.derive(drives: [first, second], charges: [], currentState: nil, pricePerKwh: 0.2, efficiencyKwhPerKm: 0.15, usableCapacityKwh: 60, now: second.startDate)
        XCTAssertEqual(sessions[0].energyLostKwh, 1.2, accuracy: 0.000001)
        XCTAssertEqual(sessions[0].cost, 0.24, accuracy: 0.000001)
        var unfinished = charge(added: 5)
        unfinished.startDate = first.endDate!.addingTimeInterval(300)
        unfinished.endDate = nil
        XCTAssertTrue(ParkingSessionEngine.derive(drives: [first, second], charges: [unfinished], currentState: nil, pricePerKwh: 0.2, efficiencyKwhPerKm: 0.15, now: second.startDate).isEmpty)
    }

    func testSocTimelineRejectsFutureAndImpossibleSamples() {
        var future = drive(distance: 10)
        future.startDate = now.addingTimeInterval(3600)
        future.endDate = now.addingTimeInterval(7200)
        var invalid = charge(added: 10)
        invalid.startBattery = -1
        invalid.endBattery = 101
        XCTAssertTrue(StatsEngine.socTimeline(drives: [future], charges: [invalid], days: 7, now: now).isEmpty)
        XCTAssertTrue(StatsEngine.tempBins([], width: 0).isEmpty)
    }

    func testBatteryDerivationKeepsCapacityAssociatedWithMaximumRangeRegardlessOfInputOrder() {
        var high = charge(id: 1, added: 30)
        high.startBattery = 40
        high.endBattery = 80
        high.endRangeKm = 400
        var low = charge(id: 2, added: 20)
        low.startDate = now.addingTimeInterval(3600)
        low.startBattery = 40
        low.endBattery = 80
        low.endRangeKm = 320
        for records in [[high, low], [low, high]] {
            let point = HistoryViewModel.deriveBattery(charges: records, drives: [], efficiency: nil)[0]
            XCTAssertEqual(point.maxRangeKm, 500)
            XCTAssertEqual(point.usableCapacityKwh, 75)
        }
    }

    func testMetricImperialConsumptionAndTemperatureConversions() {
        var config = ServerConfig()
        config.languageCode = "en"
        var units = Units(config: config)
        XCTAssertEqual(units.consumption(whPerKm: 150, unit: .kwhPer100km), "15 kWh/100km")
        config.units = .imperial
        config.temperatureUnit = .fahrenheit
        units = Units(config: config)
        XCTAssertEqual(units.distance(km: 1.609344), "1 mi")
        XCTAssertEqual(units.speed(kmh: 96.56064), "60 mph")
        XCTAssertEqual(units.consumption(whPerKm: 150, unit: .whPerKm), "241 Wh/mi")
        XCTAssertEqual(units.consumption(whPerKm: 150, unit: .kwhPer100km), "24.1 kWh/100mi")
        XCTAssertEqual(units.temperature(c: 0), "32°F")
    }

    func testHistoricalCustomRangeProjectionStopsAtEndOfSelectedPeriod() {
        let cal = Calendar.current
        var range = StatsRange(preset: .custom)
        range.customStart = cal.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        range.customEnd = cal.date(from: DateComponents(year: 2026, month: 6, day: 30))!
        var c = charge(added: 10)
        c.startDate = cal.date(from: DateComponents(year: 2026, month: 6, day: 15))!
        c.cost = 16
        let digest = StatsDigest.make(allDrives: [], allCharges: [c], range: range, pricing: .init(defaultPricePerKwh: 0.2), fuelLPer100km: 6, now: now)
        XCTAssertEqual(digest.cost.monthlyProjection!, 30.4, accuracy: 0.000001)
    }

    func testDatePresetsExcludeFutureAndReversedCustomIntervalIsSafe() {
        XCTAssertFalse(StatsRange(preset: .month).contains(now + 60, now: now))
        XCTAssertFalse(TimeRange.month.contains(now + 60, now: now))
        var reversed = StatsRange(preset: .custom)
        reversed.customStart = now
        reversed.customEnd = now - 2 * 86400
        XCTAssertNil(reversed.interval(now: now))
        XCTAssertFalse(reversed.contains(now, now: now))
    }

    func testChargingLocationAveragePowerWeightsSessionDurations() {
        var slow = charge(id: 1, added: 10)
        slow.endDate = slow.startDate + 3600
        slow.avgPowerKw = 10
        var fast = charge(id: 2, added: 10)
        fast.endDate = fast.startDate + 360
        fast.avgPowerKw = 100
        let location = StatsEngine.chargingLocations([slow, fast], pricing: .init(defaultPricePerKwh: 0.2))[0]
        XCTAssertEqual(location.avgPowerKw, 20 / 1.1, accuracy: 0.000001)
    }

    func testLivePowerExpiresIndependentlyOfOtherVehicleUpdatesAndAllowsRegen() {
        XCTAssertEqual(DriverPowerSample(powerKw: -20, date: now).value(at: now + 5), -20)
        XCTAssertNil(DriverPowerSample(powerKw: 20, date: now).value(at: now + 6))
        XCTAssertNil(DriverPowerSample(powerKw: .infinity, date: now).value(at: now))
        XCTAssertNil(DriverPowerSample(powerKw: 20, date: now + 2).value(at: now))
    }

    func testParkedStateCannotReviveAnOldMovingSpeed() {
        let staleMoving = DriverSpeedSample(speedKmh: 60, date: now - 6, source: .teslaMate, accuracyKmh: nil)
        XCTAssertNil(DriverSpeedFusion.resolve(phone: nil, teslaMate: staleMoving,
                                               at: now, allowStationaryTeslaMate: true))
        let staleStopped = DriverSpeedSample(speedKmh: 0, date: now - 6, source: .teslaMate, accuracyKmh: nil)
        XCTAssertEqual(DriverSpeedFusion.resolve(phone: nil, teslaMate: staleStopped,
                                                 at: now, allowStationaryTeslaMate: true)?.speedKmh, 0)
    }

    private func charge(id: Int = 1, added: Double) -> ChargeRecord {
        ChargeRecord(id: id, startDate: now, endDate: now.addingTimeInterval(1800), address: "Home", geofence: "Home", energyAddedKwh: added, startBattery: 40, endBattery: 80, startRangeKm: 160, endRangeKm: 320, durationMin: 30, cost: nil, energyUsedKwh: nil, outsideTempAvg: 20, odometerKm: nil, avgPowerKw: 11, coord: nil, isFastCharger: false)
    }

    private func drive(id: Int = 1, distance: Double) -> DriveRecord {
        DriveRecord(id: id, startDate: now, endDate: now.addingTimeInterval(600), startAddress: "A", endAddress: "B", startGeofence: nil, endGeofence: nil, distanceKm: distance, durationMin: 10, startBattery: 85, endBattery: 80, startUsableBattery: nil, endUsableBattery: nil, startRangeKm: 340, endRangeKm: 320, avgSpeedKmh: 60, maxSpeedKmh: 80, maxPowerKw: nil, minPowerKw: nil, outsideTempAvg: 20, insideTempAvg: 22, energyConsumedKwh: distance * 0.15, startCoord: nil, endCoord: nil, path: [], consumptionWhPerKm: 150, elevationProfile: [])
    }
}
