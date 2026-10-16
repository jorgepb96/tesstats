import XCTest
@testable import Tesstats

final class StatsEngineTests: XCTestCase {

    func testChargeCurveCondensesRepeatedSamplesAndRejectsImpossibleACSpike() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let raw = [
            ChargeCurvePoint(date: start, soc: 85, powerKw: 2, voltage: 230, current: 10),
            ChargeCurvePoint(date: start.addingTimeInterval(1), soc: 85, powerKw: 2, voltage: 230, current: 10),
            ChargeCurvePoint(date: start.addingTimeInterval(2), soc: 85, powerKw: 250, voltage: 230, current: 10),
            ChargeCurvePoint(date: start.addingTimeInterval(3), soc: 86, powerKw: 2, voltage: 230, current: 10),
            ChargeCurvePoint(date: start.addingTimeInterval(4), soc: 86, powerKw: 2, voltage: 230, current: 10)
        ]

        let ac = ChargeCurve.displayPoints(from: raw, isFast: false, avgPowerKw: 2)
        XCTAssertEqual(ac.map(\.soc), [85, 86])
        XCTAssertEqual(ac.map(\.powerKw), [2, 2])

        let dc = ChargeCurve.displayPoints(from: [raw[2], raw[3]], isFast: true, avgPowerKw: 120)
        XCTAssertEqual(dc.map(\.powerKw), [250, 2],
                       "A legitimate high-power DC sample must remain in the chart")
    }

    func testCalendarHeatmapAggregatesDistanceAndDriveCount() {
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 12))!
        let today = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

        let drives = [
            makeDrive(id: 1, start: today.addingTimeInterval(9 * 3600), distance: 12),
            makeDrive(id: 2, start: today.addingTimeInterval(18 * 3600), distance: 8),
            makeDrive(id: 3, start: yesterday.addingTimeInterval(8 * 3600), distance: 30),
            // Outside the window — must be ignored.
            makeDrive(id: 4, start: cal.date(byAdding: .day, value: -400, to: today)!, distance: 99)
        ]

        let days = StatsEngine.calendarHeatmap(drives, weeks: 18, now: now)

        XCTAssertEqual(days.count, 18 * 7)
        let todayCell = days.last
        XCTAssertEqual(todayCell?.day, today)
        XCTAssertEqual(todayCell?.driveCount, 2)
        XCTAssertEqual(todayCell?.distanceKm ?? 0, 20, accuracy: 0.001)

        let yesterdayCell = days[days.count - 2]
        XCTAssertEqual(yesterdayCell.driveCount, 1)
        XCTAssertEqual(yesterdayCell.distanceKm, 30, accuracy: 0.001)

        // Every cell inside the window exists, including empty ones.
        XCTAssertTrue(days.contains { $0.driveCount == 0 && $0.distanceKm == 0 })
        // The out-of-window drive contributed nowhere.
        XCTAssertEqual(days.reduce(0) { $0 + $1.distanceKm }, 50, accuracy: 0.001)
    }

    func testYearOverYearPicksTwoMostRecentYearsSorted() {
        let cal = Calendar.current
        func month(_ y: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: 1))! }
        let monthly = [
            MonthlyStat(month: month(2024, 5), distanceKm: 100),
            MonthlyStat(month: month(2025, 2), distanceKm: 200),
            MonthlyStat(month: month(2025, 11), distanceKm: 250),
            MonthlyStat(month: month(2026, 1), distanceKm: 300),
            MonthlyStat(month: month(2026, 6), distanceKm: 350)
        ]

        let years = StatsEngine.yearOverYear(monthly)

        XCTAssertEqual(years.map(\.year), [2025, 2026])   // 2024 dropped, oldest first
        XCTAssertEqual(years[0].months.map(\.distanceKm), [200, 250])
        XCTAssertEqual(years[1].months.map(\.distanceKm), [300, 350])
        // Months within a year come back chronologically sorted.
        XCTAssertEqual(years[0].months.map { cal.component(.month, from: $0.month) }, [2, 11])
    }

    func testYearOverYearWithSingleYearReturnsOneEntry() {
        let cal = Calendar.current
        let m = MonthlyStat(month: cal.date(from: DateComponents(year: 2026, month: 3, day: 1))!, distanceKm: 10)
        XCTAssertEqual(StatsEngine.yearOverYear([m]).count, 1)
        XCTAssertTrue(StatsEngine.yearOverYear([]).isEmpty)
    }

    func testSocTimelineChainsDriveAndChargeBoundaries() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let drive = makeDrive(id: 1, start: now.addingTimeInterval(-7200), distance: 20)
        // Charge right after the drive: 75% → 90%.
        var charge = makeCharge(id: 1, start: now.addingTimeInterval(-4000), energy: 15)

        let samples = StatsEngine.socTimeline(drives: [drive], charges: [charge], days: 7, now: now)

        XCTAssertEqual(samples.map(\.soc), [80, 75, 75, 90])
        XCTAssertEqual(samples.map(\.kind), [.drive, .drive, .charge, .charge])
        XCTAssertEqual(samples, samples.sorted { $0.date < $1.date })

        // Outside the window → excluded.
        charge = makeCharge(id: 2, start: now.addingTimeInterval(-30 * 86_400), energy: 15)
        XCTAssertTrue(StatsEngine.socTimeline(drives: [], charges: [charge], days: 7, now: now).isEmpty)
    }

    // MARK: Phantom drain

    /// A drive that leaves the car at `endB` %, so the next drive starting lower means the car
    /// lost charge while parked (which is what phantom drain measures).
    private func drainDrive(id: Int, start: Date, startB: Int, endB: Int) -> DriveRecord {
        var d = makeDrive(id: id, start: start, distance: 10)
        d.startBattery = startB
        d.endBattery = endB
        d.startRangeKm = Double(startB) * 4
        d.endRangeKm = Double(endB) * 4
        return d
    }

    /// The "was the car charged during this parked gap?" test is a binary search over sorted
    /// charge dates. These pin the boundary behaviour it has to reproduce.
    func testPhantomDrainIgnoresGapsContainingACharge() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let day = 86_400.0
        // Two parked gaps of about a day, losing 10 points of charge in each.
        let drives = [
            drainDrive(id: 1, start: base, startB: 90, endB: 80),
            drainDrive(id: 2, start: base + day, startB: 70, endB: 60),
            drainDrive(id: 3, start: base + 2 * day, startB: 50, endB: 40)
        ]

        XCTAssertEqual(StatsEngine.phantomDrain(drives: drives, charges: [])?.idleSamples, 2)

        // A charge inside the first gap removes that sample only.
        let inFirstGap = makeCharge(id: 1, start: base + day / 2, energy: 10)
        XCTAssertEqual(StatsEngine.phantomDrain(drives: drives, charges: [inFirstGap])?.idleSamples, 1)

        // Charges outside every gap (before the first drive, after the last) change nothing.
        let outside = [makeCharge(id: 2, start: base - day, energy: 10),
                       makeCharge(id: 3, start: base + 5 * day, energy: 10)]
        XCTAssertEqual(StatsEngine.phantomDrain(drives: drives, charges: outside)?.idleSamples, 2)

        // A charge exactly on a gap boundary is not "inside" it.
        var onBoundary = makeCharge(id: 4, start: base + day, energy: 10)   // == drive 2 start
        onBoundary.endDate = onBoundary.startDate.addingTimeInterval(600)
        XCTAssertEqual(StatsEngine.phantomDrain(drives: drives, charges: [onBoundary])?.idleSamples, 2)

        // Unsorted charge input must give the same answer as sorted input.
        let shuffled = [outside[1], inFirstGap, outside[0]]
        XCTAssertEqual(StatsEngine.phantomDrain(drives: drives, charges: shuffled)?.idleSamples,
                       StatsEngine.phantomDrain(drives: drives,
                                                charges: shuffled.sorted { $0.startDate < $1.startDate })?.idleSamples)
    }

    func testPhantomDrainMatchesLinearScanOnRandomData() {
        // Reference implementation: the O(drives × charges) scan the binary search replaced.
        func referenceSamples(_ drives: [DriveRecord], _ charges: [ChargeRecord]) -> Int {
            let ordered = drives.sorted { $0.startDate < $1.startDate }
            var samples = 0
            for i in 0..<max(0, ordered.count - 1) {
                let a = ordered[i], b = ordered[i + 1]
                let aEnd = a.endDate ?? a.startDate
                let idle = b.startDate.timeIntervalSince(aEnd)
                guard idle >= 7_200, idle <= 1_209_600 else { continue }
                if charges.contains(where: { $0.startDate < b.startDate && ($0.endDate ?? $0.startDate) > aEnd }) { continue }
                if let ab = a.endBattery, let bb = b.startBattery, ab - bb >= 0, ab - bb <= 30 { samples += 1 }
            }
            return samples
        }

        var seed: UInt64 = 42
        func next(_ bound: Int) -> Int {                      // deterministic LCG, no Date/random
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(truncatingIfNeeded: seed >> 33) % bound
        }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let drives = (0..<200).map { i -> DriveRecord in
            let level = 40 + next(50)
            return drainDrive(id: i,
                              start: base + Double(i) * 86_400 + Double(next(40_000)),
                              startB: level, endB: level - next(20))
        }
        let charges = (0..<80).map { i in
            makeCharge(id: i, start: base + Double(next(200)) * 86_400 + Double(next(80_000)), energy: 10)
        }

        let fast = StatsEngine.phantomDrain(drives: drives, charges: charges)?.idleSamples ?? 0
        XCTAssertEqual(fast, referenceSamples(drives, charges))
        XCTAssertGreaterThan(fast, 0, "fixture should produce real samples, otherwise this proves nothing")
    }

    private func makeCharge(id: Int, start: Date, energy: Double) -> ChargeRecord {
        ChargeRecord(
            id: id,
            startDate: start,
            endDate: start.addingTimeInterval(1800),
            address: "Home", geofence: "Home",
            energyAddedKwh: energy,
            startBattery: 75, endBattery: 90,
            startRangeKm: 300, endRangeKm: 360,
            durationMin: 30, cost: nil,
            energyUsedKwh: nil, outsideTempAvg: nil, odometerKm: nil,
            avgPowerKw: 11, coord: nil, isFastCharger: false
        )
    }

    private func makeDrive(id: Int, start: Date, distance: Double) -> DriveRecord {
        DriveRecord(
            id: id,
            startDate: start,
            endDate: start.addingTimeInterval(1200),
            startAddress: "A", endAddress: "B",
            startGeofence: "A", endGeofence: "B",
            distanceKm: distance, durationMin: 20,
            startBattery: 80, endBattery: 75,
            startUsableBattery: nil, endUsableBattery: nil,
            startRangeKm: 320, endRangeKm: 300,
            avgSpeedKmh: 50, maxSpeedKmh: 80,
            maxPowerKw: nil, minPowerKw: nil,
            outsideTempAvg: 20, insideTempAvg: 22,
            energyConsumedKwh: distance * 0.15,
            startCoord: nil, endCoord: nil,
            path: [],
            consumptionWhPerKm: 150,
            elevationProfile: []
        )
    }
}
