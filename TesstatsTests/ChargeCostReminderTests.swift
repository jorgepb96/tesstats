import XCTest
@testable import Tesstats

final class ChargeCostReminderTests: XCTestCase {
    private func charge(_ id: Int, location: String = "New point", cost: Double? = nil) -> ChargeRecord {
        return ChargeRecord(id: id, startDate: Date().addingTimeInterval(-3600), endDate: Date().addingTimeInterval(-60),
                            address: location, geofence: nil, energyAddedKwh: 12, durationMin: 30,
                            cost: cost, isFastCharger: false)
    }

    func testBaselineAndNewPointDeduplication() throws {
        var state = ChargeCostReminderState()
        XCTAssertTrue(state.inspect([charge(1, location: "Home")], prices: [:]).isEmpty)
        XCTAssertEqual(state.inspect([charge(2)], prices: [:]).map(\.id), [2])
        let data = try JSONEncoder().encode(state)
        state = try JSONDecoder().decode(ChargeCostReminderState.self, from: data)
        XCTAssertTrue(state.inspect([charge(2), charge(3)], prices: [:]).isEmpty)
    }

    func testFreeAndPaidLocationsDoNotNotify() {
        var state = ChargeCostReminderState(initialized: true)
        XCTAssertTrue(state.inspect([charge(1)], prices: ["New point": 0]).isEmpty)
        XCTAssertTrue(state.inspect([charge(2, location: "Paid", cost: 0.01)], prices: [:]).isEmpty)
    }

    func testIncompleteAndOldChargesDoNotNotify() {
        var state = ChargeCostReminderState(initialized: true)
        var unfinished = charge(1)
        unfinished.endDate = nil
        XCTAssertTrue(state.inspect([unfinished], prices: [:]).isEmpty)
        unfinished.endDate = Date().addingTimeInterval(-1)
        XCTAssertEqual(state.inspect([unfinished], prices: [:]).count, 1)
        var old = charge(2, location: "Old")
        old.endDate = Date().addingTimeInterval(-8 * 86400)
        XCTAssertTrue(state.inspect([old], prices: [:]).isEmpty)
    }

    func testTwoExtraZoomLevelsKeepAnchorProportional() {
        let first = DriverMapCameraPolicy.zoomIn(0.46)
        let second = DriverMapCameraPolicy.zoomIn(first)
        XCTAssertLessThan(second, first)
        XCTAssertEqual(DriverMapCameraPolicy.zoomIn(second), second)
        for zoom in [first, second, 1, 2.6] {
            XCTAssertEqual(DriverMapCameraPolicy.offsetMeters(layout: .portrait, zoomFactor: zoom), 68 * zoom, accuracy: 0.001)
            XCTAssertEqual(DriverMapCameraPolicy.offsetMeters(layout: .landscape, zoomFactor: zoom), 220 * zoom, accuracy: 0.001)
        }
    }
}
