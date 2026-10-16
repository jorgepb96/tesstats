import XCTest
import Foundation
@testable import Tesstats

final class ChargeExportTests: XCTestCase {
    private func charge() -> ChargeRecord {
        let start = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 22))!
        return ChargeRecord(id: 42, startDate: start, endDate: start.addingTimeInterval(4 * 3600),
            address: "Calle Uno, 2", geofence: "Casa", energyAddedKwh: 10,
            startBattery: 40, endBattery: 60, startRangeKm: 160, endRangeKm: 240,
            durationMin: 240, cost: nil, energyUsedKwh: 12, outsideTempAvg: 21,
            odometerKm: 12345, avgPowerKw: 3, coord: Coordinate(latitude: 40, longitude: -3),
            isFastCharger: false)
    }

    private func json(_ charge: ChargeRecord, pricing: ChargePricing) throws -> [String: Any] {
        let data = Data(ExportService.chargesJSON([charge], pricing: pricing, currencyCode: "EUR").utf8)
        return try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first)
    }

    func testLocationPriceExportsSameTotalAsScreenIncludingLosses() throws {
        let c = charge()
        let pricing = ChargePricing(defaultPricePerKwh: 0.5, perLocation: ["Casa": 0.2])
        let result = try json(c, pricing: pricing)
        XCTAssertEqual(try XCTUnwrap(result["cost"] as? Double), 2.4, accuracy: 0.0001)
        XCTAssertEqual(result["address"] as? String, c.address)
        XCTAssertEqual(result["locationName"] as? String, "Casa")
        XCTAssertEqual(result["currencyCode"] as? String, "EUR")
        XCTAssertEqual(result["odometerKm"] as? Double, 12345)
        XCTAssertEqual(result["energyUsedKwh"] as? Double, 12)
        let detail = try XCTUnwrap(result["pricing"] as? [String: Any])
        XCTAssertEqual(detail["source"] as? String, "location_override")
        XCTAssertEqual(detail["billedEnergyKwh"] as? Double, 12)
        XCTAssertEqual(detail["cost"] as? Double, pricing.cost(for: c))
        let csv = ExportService.chargesCSV([c], pricing: pricing, currencyCode: "EUR")
        XCTAssertTrue(csv.contains("Casa,10.00,2.40,"))
        XCTAssertTrue(csv.contains("\"Calle Uno, 2\""))
        XCTAssertTrue(csv.contains("location_override,1,0.200000"))
    }

    func testRecordedAndFreePricesKeepTheirPrecedence() throws {
        var c = charge()
        let pricing = ChargePricing(defaultPricePerKwh: 0.5, perLocation: ["Casa": 0])
        XCTAssertEqual(try json(c, pricing: pricing)["cost"] as? Double, 0)
        c.cost = 7.25
        let result = try json(c, pricing: pricing)
        XCTAssertEqual(result["cost"] as? Double, 7.25)
        XCTAssertEqual(result["recordedCost"] as? Double, 7.25)
        XCTAssertEqual((result["pricing"] as? [String: Any])?["isEstimated"] as? Bool, false)
    }

    func testCrossMidnightTariffExportsAppliedPlanAndWeightedPrice() throws {
        let plan = TariffPlan(name: "Night & day", bands: [
            TariffBand(kind: .flat, startMinute: 0, endMinute: 8 * 60, buyPricePerKwh: 0.1),
            TariffBand(kind: .flat, startMinute: 8 * 60, endMinute: 0, buyPricePerKwh: 0.3)
        ]).normalized()
        let pricing = ChargePricing(defaultPricePerKwh: 0.9, plan: plan)
        let result = try json(charge(), pricing: pricing)
        XCTAssertEqual(try XCTUnwrap(result["cost"] as? Double), 2.4, accuracy: 0.001)
        XCTAssertEqual((result["tariffPlan"] as? [String: Any])?["name"] as? String, "Night & day")
        XCTAssertEqual((result["pricing"] as? [String: Any])?["source"] as? String, "time_of_use")
        XCTAssertEqual(result["pricingTimeZone"] as? String, Calendar.current.timeZone.identifier)
    }

    func testLegacyAndDefaultPricingAreExported() throws {
        let legacy = ChargePricing(defaultPricePerKwh: 0.3,
            tariff: TimeOfUseTariff(periods: [TariffPeriod(startMinute: 0, endMinute: 480, pricePerKwh: 0.1)]))
        let result = try json(charge(), pricing: legacy)
        XCTAssertNotNil(result["legacyTariff"])
        XCTAssertEqual(try XCTUnwrap(result["cost"] as? Double), 2.4, accuracy: 0.001)
        var c = charge()
        c.energyUsedKwh = nil
        c.endDate = nil
        let fallback = try json(c, pricing: ChargePricing(defaultPricePerKwh: 0.3))
        XCTAssertEqual(fallback["cost"] as? Double, 3)
        XCTAssertEqual((fallback["pricing"] as? [String: Any])?["source"] as? String, "default_price")
    }

    func testGPXPreservesDetailsAndChargesWithoutCoordinates() {
        var c = charge()
        c.geofence = "A & B <charger>"
        var unlocated = c
        unlocated.coord = nil
        let gpx = ExportService.chargesGPX([c, unlocated],
            pricing: ChargePricing(defaultPricePerKwh: 0.2), currencyCode: "EUR")
        XCTAssertTrue(XMLParser(data: Data(gpx.utf8)).parse())
        XCTAssertTrue(gpx.contains("A &amp; B &lt;charger&gt;"))
        XCTAssertTrue(gpx.contains("2.40 EUR"))
        XCTAssertTrue(gpx.contains("tesstats:unlocatedCharges"))
        XCTAssertTrue(gpx.contains("energyUsedKwh"))
    }

    func testCSVQuotesMultilineLocationsAndEmptyExportsRemainValid() {
        var c = charge()
        c.geofence = "Place, \"A\"\r\nSecond line"
        let pricing = ChargePricing(defaultPricePerKwh: 0.2)
        let csv = ExportService.chargesCSV([c], pricing: pricing, currencyCode: "EUR")
        XCTAssertTrue(csv.contains("\"Place, \"\"A\"\"\r\nSecond line\""))
        XCTAssertEqual(ExportService.chargesJSON([], pricing: pricing, currencyCode: "EUR"), "[\n\n]")
        XCTAssertTrue(XMLParser(data: Data(ExportService.chargesGPX([], pricing: pricing, currencyCode: "EUR").utf8)).parse())
    }
}
