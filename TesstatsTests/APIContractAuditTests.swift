import XCTest
@testable import Tesstats

private final class AuditURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    private static let lock = NSLock()

    static func register(host: String, handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers[host] = handler
    }

    private static func handler(for host: String) -> Handler? {
        lock.lock(); defer { lock.unlock() }
        return handlers[host]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = Self.handler(for: request.url!.host!)!
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class APIContractAuditTests: XCTestCase {
    func testImperialHistoryIsNormalizedBeforeAggregationAndExport() async throws {
        let json = #"{"data":{"units":{"unit_of_length":"mi","unit_of_temperature":"F"},"drives":[{"drive_id":1,"start_date":"2026-07-10T10:00:00Z","odometer_details":{"odometer_distance":10},"speed_avg":60,"speed_max":70,"range_rated":{"start_range":200,"end_range":180},"outside_temp_avg":68,"inside_temp_avg":77,"energy_consumed_net":3,"consumption_net":115.8339}]}}"#
        let api = service { _ in (200, Data(json.utf8)) }
        let d = try await api.fetchDrives(carID: 1)[0]
        XCTAssertEqual(d.distanceKm, 16.09344, accuracy: 0.000001)
        XCTAssertEqual(d.avgSpeedKmh!, 96.56064, accuracy: 0.000001)
        XCTAssertEqual(d.startRangeKm!, 321.8688, accuracy: 0.000001)
        XCTAssertEqual(d.outsideTempAvg, 20)
        XCTAssertEqual(d.insideTempAvg, 25)
        XCTAssertEqual(d.consumptionWhPerKm!, 3000 / 16.09344, accuracy: 0.000001)
        XCTAssertEqual(TripCostEngine.energyKwh(for: d), 3)
        XCTAssertTrue(ExportService.drivesCSV([d]).contains("16.09"))
    }

    func testImperialChargeRangesOdometerAndTemperatureAreNormalized() async throws {
        let json = #"{"data":{"units":{"unit_of_length":"mi","unit_of_temperature":"F"},"charges":[{"charge_id":1,"start_date":"2026-07-10T10:00:00Z","charge_energy_added":10,"charge_energy_used":12,"duration_min":60,"odometer":10000,"outside_temp_avg":68,"range_rated":{"start_range":100,"end_range":150}}]}}"#
        let c = try await service { _ in (200, Data(json.utf8)) }.fetchCharges(carID: 1)[0]
        XCTAssertEqual(c.startRangeKm!, 160.9344, accuracy: 0.000001)
        XCTAssertEqual(c.odometerKm!, 16093.44, accuracy: 0.000001)
        XCTAssertEqual(c.outsideTempAvg, 20)
        XCTAssertEqual(c.energyAddedKwh, 10)
        XCTAssertEqual(c.chargingEfficiency!, 10 / 12, accuracy: 0.000001)
    }

    func testOlderMetricResponseWithoutUnitMetadataRetainsPrecisionGate() async throws {
        let json = #"{"data":{"drives":[{"drive_id":1,"start_date":"2026-07-10T10:00:00Z","odometer_details":{"odometer_distance":10},"outside_temp_avg":20,"energy_consumed_net":2,"consumption_net":null}]}}"#
        let d = try await service { _ in (200, Data(json.utf8)) }.fetchDrives(carID: 1)[0]
        XCTAssertEqual(d.distanceKm, 10)
        XCTAssertEqual(d.outsideTempAvg, 20)
        XCTAssertNil(d.consumptionWhPerKm)
    }

    func testFullHistoryContinuesBeyondFiveThousandDrives() async throws {
        let api = service { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            guard query.first(where: { $0.name == "show" })?.value == "100" else { throw APIError.badURL }
            let page = Int(query.first(where: { $0.name == "page" })!.value!)!
            let ids = page <= 50 ? Array(((page - 1) * 100 + 1)...(page * 100)) : [5001]
            let rows = ids.map { #"{"drive_id":\#($0),"start_date":"2026-07-10T10:00:00Z"}"# }.joined(separator: ",")
            return (200, Data("{\"data\":{\"drives\":[\(rows)]}}".utf8))
        }
        let records = try await api.fetchDrives(carID: 1)
        XCTAssertEqual(records.count, 5001)
        XCTAssertTrue(records.contains { $0.id == 5001 })
    }

    func testFullHistoryContinuesBeyondFiveThousandCharges() async throws {
        let api = service { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let page = Int(query.first(where: { $0.name == "page" })!.value!)!
            let ids = page <= 50 ? Array(((page - 1) * 100 + 1)...(page * 100)) : [5001]
            let rows = ids.map { #"{"charge_id":\#($0),"start_date":"2026-07-10T10:00:00Z"}"# }.joined(separator: ",")
            return (200, Data("{\"data\":{\"charges\":[\(rows)]}}".utf8))
        }
        let records = try await api.fetchCharges(carID: 1)
        XCTAssertEqual(records.count, 5001)
    }

    func testRepeatedFullPageFailsInsteadOfLoopingOrSilentlyTruncating() async {
        let rows = (1...100).map { #"{"drive_id":\#($0),"start_date":"2026-07-10T10:00:00Z"}"# }.joined(separator: ",")
        let api = service { _ in (200, Data("{\"data\":{\"drives\":[\(rows)]}}".utf8)) }
        do {
            _ = try await api.fetchDrives(carID: 1)
            XCTFail("Repeated pagination must fail explicitly")
        } catch {
            guard case APIError.underlying = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testPartialNewestFirstOrderingIsNotSafeForIncrementalSync() {
        let a = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(HistorySync.isNewestFirst(dates: [a + 30, a, a + 20, a - 10]))
        XCTAssertTrue(HistorySync.isNewestFirst(dates: [a + 30, a + 20, a, a - 10]))
    }

    func testDriveElevationStaysAlignedWhenInvalidCoordinatesAreSkipped() async throws {
        let json = #"{"data":{"drive":{"drive_details":[{"latitude":40,"longitude":-3,"elevation":100},{"latitude":999,"longitude":-3,"elevation":200},{"latitude":41,"longitude":-4,"elevation":300}]}}}"#
        let trace = try await service { _ in (200, Data(json.utf8)) }.fetchDriveDetails(carID: 1, driveID: 1)
        XCTAssertEqual(trace.path.count, 2)
        XCTAssertEqual(trace.elevationProfile, [100, 300])
        XCTAssertTrue(trace.isUsable)
    }

    func testAuthorizationAndServerFailuresAreNotDecodedAsEmptyHistory() async {
        for status in [401, 403, 503] {
            do {
                _ = try await service { _ in (status, Data("{}".utf8)) }.fetchCharges(carID: 1)
                XCTFail("HTTP \(status) must fail")
            } catch {
                switch error {
                case APIError.unauthorized: XCTAssertTrue([401, 403].contains(status))
                case APIError.http(let code): XCTAssertEqual(code, status)
                default: XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    private func service(handler: @escaping AuditURLProtocol.Handler) -> HistoryAPIService {
        let host = "audit-\(UUID().uuidString.lowercased()).invalid"
        AuditURLProtocol.register(host: host, handler: handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuditURLProtocol.self]
        return HistoryAPIService(config: .init(baseURL: "https://\(host)", basicAuth: nil, trust: .init(allowSelfSigned: false, pinnedPublicKeySHA256: nil), allowInsecure: false), session: URLSession(configuration: config))
    }
}
