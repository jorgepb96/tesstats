import XCTest
@testable import Tesstats

final class VisualInsightsTests: XCTestCase {
    func testDailyGroupingSortsNewestFirstAndSummarizes() {
        let cal = Calendar(identifier: .gregorian)
        let first = cal.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 9))!
        let second = cal.date(from: DateComponents(year: 2026, month: 6, day: 2, hour: 9))!
        let drives = [
            makeDrive(id: 1, start: first, distance: 10),
            makeDrive(id: 2, start: second, distance: 20)
        ]

        let groups = DailyHistoryGrouper.group(drives, calendar: cal, date: \.startDate) { _ in "day" } detail: { "\($0.count)" }

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].items.first?.id, 2)
        XCTAssertEqual(groups[1].items.first?.id, 1)
    }

    func testDashboardInsightsFindLastDriveEfficiencyAndActivity() {
        let now = Date(timeIntervalSince1970: 10_000)
        let drive = makeDrive(id: 1, start: now.addingTimeInterval(-3600), distance: 100, duration: 60, wh: 150)
        let charge = makeCharge(id: 1, start: now.addingTimeInterval(-7200), duration: 30, energy: 20)

        let insights = DashboardInsightEngine.insights(drives: [drive], charges: [charge], now: now)

        XCTAssertEqual(insights.lastDrive?.id, 1)
        XCTAssertEqual(Int(insights.efficiency30dWhPerKm ?? 0), 150)
        XCTAssertEqual(insights.activity48h.count, 2)
    }

    func testTripCostUsesEnergyAndFuelComparison() {
        let drive = makeDrive(id: 1, start: Date(), distance: 100, duration: 60, wh: 160)

        let cost = TripCostEngine.cost(for: drive, pricePerKwh: 0.20, fuelPricePerLiter: 1.70, fuelConsumptionLPer100km: 7)

        XCTAssertEqual(cost?.electricCost ?? 0, 3.2, accuracy: 0.01)
        XCTAssertEqual(cost?.fuelEquivalentCost ?? 0, 11.9, accuracy: 0.01)
        XCTAssertGreaterThan(cost?.savings ?? 0, 8)
    }

    func testTripCostsConsumeWeightedValueOfRemainingChargeEnergy() throws {
        let start = Date(timeIntervalSince1970: 20_000)
        var cheapCharge = makeCharge(id: 10, start: start, duration: 60, energy: 20)
        cheapCharge.startBattery = nil
        cheapCharge.endBattery = nil
        cheapCharge.cost = 2 // 0.10 per stored kWh
        cheapCharge.energyUsedKwh = 22

        var firstDrive = makeDrive(id: 11, start: start.addingTimeInterval(4_000), distance: 100, wh: 100)
        firstDrive.startBattery = nil
        firstDrive.endBattery = nil

        var expensiveCharge = makeCharge(id: 12, start: start.addingTimeInterval(8_000), duration: 60, energy: 10)
        expensiveCharge.startBattery = nil
        expensiveCharge.endBattery = nil
        expensiveCharge.cost = 3 // 0.30 per stored kWh
        expensiveCharge.energyUsedKwh = 11

        var secondDrive = makeDrive(id: 13, start: start.addingTimeInterval(12_000), distance: 100, wh: 100)
        secondDrive.startBattery = nil
        secondDrive.endBattery = nil

        let costs = TripEnergyCostLedger.costs(
            drives: [secondDrive, firstDrive],
            charges: [expensiveCharge, cheapCharge],
            pricing: ChargePricing(defaultPricePerKwh: 0.50),
            fuelPricePerLiter: 1.70,
            fuelConsumptionLPer100km: 7
        )

        XCTAssertEqual(try XCTUnwrap(costs[firstDrive.id]).electricCost, 1, accuracy: 0.001)
        // 10 kWh cheap remain and mix with 10 kWh expensive: 0.20/kWh.
        XCTAssertEqual(try XCTUnwrap(costs[secondDrive.id]).electricCost, 2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(costs[secondDrive.id]).pricePerKwh, 0.20, accuracy: 0.001)
    }

    func testTripCostFallsBackSafelyWhenHistoryStartsMidBattery() throws {
        let drive = makeDrive(id: 20, start: Date(), distance: 50, wh: 200)
        let costs = TripEnergyCostLedger.costs(
            drives: [drive], charges: [],
            pricing: ChargePricing(defaultPricePerKwh: 0.25),
            fuelPricePerLiter: 1.70,
            fuelConsumptionLPer100km: 7,
            usableCapacityKwh: 60
        )

        XCTAssertEqual(try XCTUnwrap(costs[drive.id]).electricCost, 2.5, accuracy: 0.001)
    }

    func testTripCostUsesChargeBillIncludingLossesButOnlyStoresAddedEnergy() throws {
        let start = Date(timeIntervalSince1970: 30_000)
        var charge = makeCharge(id: 30, start: start, duration: 60, energy: 10)
        charge.startBattery = nil
        charge.endBattery = nil
        charge.cost = nil
        charge.energyUsedKwh = 12
        var drive = makeDrive(id: 31, start: start.addingTimeInterval(4_000), distance: 100, wh: 100)
        drive.startBattery = nil
        drive.endBattery = nil

        let costs = TripEnergyCostLedger.costs(
            drives: [drive], charges: [charge],
            pricing: ChargePricing(defaultPricePerKwh: 0.20),
            fuelPricePerLiter: 1.70,
            fuelConsumptionLPer100km: 7
        )

        // 12 grid kWh cost 2.40 and yielded 10 stored kWh consumed by the trip.
        XCTAssertEqual(try XCTUnwrap(costs[drive.id]).electricCost, 2.4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(costs[drive.id]).pricePerKwh, 0.24, accuracy: 0.001)
    }

    func testCurrentBatteryPriceUsesRemainingWeightedChargeInventory() {
        let start = Date(timeIntervalSince1970: 40_000)
        var cheap = makeCharge(id: 40, start: start, duration: 60, energy: 20)
        cheap.startBattery = nil
        cheap.endBattery = nil
        cheap.cost = 2
        var drive = makeDrive(id: 41, start: start.addingTimeInterval(4_000), distance: 100, wh: 100)
        drive.startBattery = nil
        drive.endBattery = nil
        var expensive = makeCharge(id: 42, start: start.addingTimeInterval(8_000), duration: 60, energy: 10)
        expensive.startBattery = nil
        expensive.endBattery = nil
        expensive.cost = 3

        let allocation = TripEnergyCostLedger.allocation(
            drives: [drive], charges: [expensive, cheap],
            pricing: ChargePricing(defaultPricePerKwh: 0.50),
            fuelPricePerLiter: 1.70, fuelConsumptionLPer100km: 7
        )

        // The drive used half the cheap charge; 10 cheap + 10 expensive kWh remain in the pack.
        XCTAssertEqual(allocation.currentStoredEnergyKwh, 20, accuracy: 0.001)
        XCTAssertEqual(allocation.currentBatteryPricePerKwh, 0.20, accuracy: 0.001)
    }

    func testParkingSessionsDeriveIdleGapAndExcludeChargingGap() {
        let now = Date(timeIntervalSince1970: 10_000)
        let a = makeDrive(id: 1, start: now.addingTimeInterval(-12_000), distance: 20, duration: 30, startBattery: 80, endBattery: 75)
        let b = makeDrive(id: 2, start: now.addingTimeInterval(-8_000), distance: 20, duration: 30, startBattery: 72, endBattery: 68)
        let c = makeDrive(id: 3, start: now.addingTimeInterval(-3_000), distance: 20, duration: 30, startBattery: 90, endBattery: 84)
        let charge = makeCharge(id: 2, start: b.endDate!.addingTimeInterval(300), duration: 60, energy: 25)

        let sessions = ParkingSessionEngine.derive(
            drives: [a, b, c],
            charges: [charge],
            currentState: nil,
            pricePerKwh: 0.20,
            efficiencyKwhPerKm: 0.15,
            now: now
        )

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.locationName, a.destinationName)
        XCTAssertGreaterThan(sessions.first?.energyLostKwh ?? 0, 0)
    }

    func testParkingLiveSessionIsDerivedWhenParked() {
        let now = Date()
        var state = VehicleState(carID: 1)
        state.state = .online
        state.since = now.addingTimeInterval(-7200)
        state.batteryLevel = 70
        state.ratedBatteryRangeKm = 300
        state.geofence = "Home"

        let sessions = ParkingSessionEngine.derive(
            drives: [],
            charges: [],
            currentState: state,
            pricePerKwh: 0.20,
            efficiencyKwhPerKm: 0.15,
            now: now
        )

        XCTAssertEqual(sessions.first?.id, "live-1")
        XCTAssertGreaterThanOrEqual(sessions.first?.durationMinutes ?? 0, 119)
        XCTAssertLessThanOrEqual(sessions.first?.durationMinutes ?? 0, 121)
    }

    func testMapSamplingCapsWorkAndPreservesRouteEndpoints() {
        let route = (0..<10_000).map {
            Coordinate(latitude: Double($0) / 10_000, longitude: -Double($0) / 10_000)
        }

        let sampled = MapGeometry.sampled(route, maximumCount: 300)

        XCTAssertEqual(sampled.count, 300)
        XCTAssertEqual(sampled.first, route.first)
        XCTAssertEqual(sampled.last, route.last)
    }

    private func makeDrive(
        id: Int,
        start: Date,
        distance: Double,
        duration: Int = 20,
        wh: Double = 150,
        startBattery: Int = 80,
        endBattery: Int = 75
    ) -> DriveRecord {
        DriveRecord(
            id: id,
            startDate: start,
            endDate: start.addingTimeInterval(Double(duration) * 60),
            startAddress: "A",
            endAddress: "B",
            startGeofence: "A",
            endGeofence: "B",
            distanceKm: distance,
            durationMin: duration,
            startBattery: startBattery,
            endBattery: endBattery,
            startUsableBattery: nil,
            endUsableBattery: nil,
            startRangeKm: Double(startBattery) * 4,
            endRangeKm: Double(endBattery) * 4,
            avgSpeedKmh: 50,
            maxSpeedKmh: 80,
            maxPowerKw: nil,
            minPowerKw: -20,
            outsideTempAvg: 20,
            insideTempAvg: 22,
            energyConsumedKwh: wh * distance / 1000,
            startCoord: Coordinate(latitude: 40, longitude: -3),
            endCoord: Coordinate(latitude: 40.1, longitude: -3.1),
            path: [Coordinate(latitude: 40, longitude: -3), Coordinate(latitude: 40.1, longitude: -3.1)],
            consumptionWhPerKm: wh,
            elevationProfile: [100, 120]
        )
    }

    private func makeCharge(id: Int, start: Date, duration: Int, energy: Double) -> ChargeRecord {
        ChargeRecord(
            id: id,
            startDate: start,
            endDate: start.addingTimeInterval(Double(duration) * 60),
            address: "Home",
            geofence: "Home",
            energyAddedKwh: energy,
            startBattery: 40,
            endBattery: 80,
            startRangeKm: 160,
            endRangeKm: 320,
            durationMin: duration,
            cost: nil,
            energyUsedKwh: energy / 0.9,
            outsideTempAvg: 20,
            odometerKm: 10_000,
            avgPowerKw: energy / (Double(duration) / 60),
            coord: Coordinate(latitude: 40, longitude: -3),
            isFastCharger: false
        )
    }
}
