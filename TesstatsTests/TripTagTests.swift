import XCTest
@testable import Tesstats

@MainActor
final class TripTagTests: XCTestCase {

    func testStorePersistsAndClearsTags() {
        let defaults = UserDefaults(suiteName: "TripTagTests-\(UUID().uuidString)")!
        let store = TripTagStore(defaults: defaults, key: "tags")

        store.setTag(.work, for: 42)
        store.setTag(.personal, for: 7)
        XCTAssertEqual(store.tag(for: 42), .work)
        XCTAssertEqual(store.tag(for: 7), .personal)
        XCTAssertNil(store.tag(for: 99))

        // Survives a reload.
        let reloaded = TripTagStore(defaults: defaults, key: "tags")
        XCTAssertEqual(reloaded.tag(for: 42), .work)

        // Clearing one tag and everything.
        reloaded.setTag(nil, for: 42)
        XCTAssertNil(reloaded.tag(for: 42))
        reloaded.clear()
        XCTAssertTrue(reloaded.tags.isEmpty)
        XCTAssertTrue(TripTagStore(defaults: defaults, key: "tags").tags.isEmpty)
    }

    func testTagFilterMatching() {
        XCTAssertTrue(TripTagFilter.all.matches(nil))
        XCTAssertTrue(TripTagFilter.all.matches(.work))
        XCTAssertTrue(TripTagFilter.work.matches(.work))
        XCTAssertFalse(TripTagFilter.work.matches(.personal))
        XCTAssertFalse(TripTagFilter.work.matches(nil))
        XCTAssertTrue(TripTagFilter.untagged.matches(nil))
        XCTAssertFalse(TripTagFilter.untagged.matches(.personal))
    }

    func testCSVExportIncludesTagColumn() {
        let drive = makeDrive(id: 5)
        let csv = ExportService.drivesCSV([drive], tags: [5: .work])
        let lines = csv.split(separator: "\n").map(String.init)

        XCTAssertTrue(lines[0].hasSuffix(",tag"))
        XCTAssertTrue(lines[1].hasSuffix(",work"))

        // Untagged drives leave the column empty.
        let untagged = ExportService.drivesCSV([drive]).split(separator: "\n").map(String.init)
        XCTAssertTrue(untagged[1].hasSuffix(","))
    }

    func testJSONExportKeepsLegacyShapeWithoutTags() {
        let drive = makeDrive(id: 5)
        XCTAssertFalse(ExportService.drivesJSON([drive]).contains("\"tag\""))
        let tagged = ExportService.drivesJSON([drive], tags: [5: .personal])
        XCTAssertTrue(tagged.contains("\"tag\" : \"personal\""))
    }

    private func makeDrive(id: Int) -> DriveRecord {
        DriveRecord(
            id: id,
            startDate: Date(timeIntervalSince1970: 1_000_000),
            endDate: Date(timeIntervalSince1970: 1_001_200),
            startAddress: "A", endAddress: "B",
            startGeofence: "A", endGeofence: "B",
            distanceKm: 10, durationMin: 20,
            startBattery: 80, endBattery: 75,
            startUsableBattery: nil, endUsableBattery: nil,
            startRangeKm: 320, endRangeKm: 300,
            avgSpeedKmh: 50, maxSpeedKmh: 80,
            maxPowerKw: nil, minPowerKw: nil,
            outsideTempAvg: 20, insideTempAvg: 22,
            energyConsumedKwh: 1.5,
            startCoord: nil, endCoord: nil,
            path: [],
            consumptionWhPerKm: 150,
            elevationProfile: []
        )
    }
}
