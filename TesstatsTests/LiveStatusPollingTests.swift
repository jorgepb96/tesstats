import XCTest
@testable import Tesstats

private final class StatusURLProtocol: URLProtocol, @unchecked Sendable {
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

/// API-only live mode reads TeslaMateApi's `/v1/cars/{id}/status`. The payloads below follow
/// the JSON that TeslaMateApi's Go structs produce: every field is always present, unknown
/// values are Go zero values, and lengths/pressures/temperatures use TeslaMate's units.
@MainActor
final class LiveStatusPollingTests: XCTestCase {
    private let metricStatus = #"""
    {"data":{"car":{"car_id":1,"car_name":"Blue Thunder"},"status":{"display_name":"Blue Thunder","state":"charging","state_since":"2026-10-17T09:00:07+02:00","odometer":12345.6,
    "car_status":{"healthy":true,"locked":true,"sentry_mode":false,"windows_open":false,"doors_open":false,"driver_front_door_open":false,"driver_rear_door_open":false,"passenger_front_door_open":false,"passenger_rear_door_open":false,"trunk_open":false,"frunk_open":false,"is_user_present":false,"center_display_state":0},
    "car_details":{"model":"3","trim_badging":"P74D"},
    "car_exterior":{"exterior_color":"DeepBlue","spoiler_type":"None","wheel_type":"Pinwheel18"},
    "car_geodata":{"geofence":"Home","location":{"latitude":40.4168,"longitude":-3.7038},"latitude":40.4168,"longitude":-3.7038},
    "car_versions":{"version":"2026.32.1","update_available":false,"update_version":""},
    "driving_details":{"active_route":{"destination":"","energy_at_arrival":0,"distance_to_arrival":0,"minutes_to_arrival":0,"traffic_minutes_delay":0,"location":{"latitude":0,"longitude":0}},"active_route_destination":"","active_route_latitude":0,"active_route_longitude":0,"shift_state":"P","power":-11,"speed":0,"heading":180,"elevation":650},
    "climate_details":{"is_climate_on":false,"inside_temp":21.5,"outside_temp":12,"is_preconditioning":false,"climate_keeper_mode":"off"},
    "battery_details":{"est_battery_range":300.5,"rated_battery_range":350.25,"ideal_battery_range":340,"battery_level":72,"usable_battery_level":71},
    "charging_details":{"plugged_in":true,"charging_state":"charging","charge_energy_added":5.06,"charge_limit_soc":90,"charge_port_door_open":true,"charger_actual_current":15.6,"charger_phases":3,"charger_power":11,"charger_voltage":230,"charge_current_request":16,"charge_current_request_max":16,"scheduled_charging_start_time":"0001-01-01T00:00:00Z","time_to_full_charge":1.83},
    "tpms_details":{"tpms_pressure_fl":2.9,"tpms_pressure_fr":2.8,"tpms_pressure_rl":0,"tpms_pressure_rr":2.85,"tpms_soft_warning_fl":false,"tpms_soft_warning_fr":true,"tpms_soft_warning_rl":false,"tpms_soft_warning_rr":false}},
    "units":{"unit_of_length":"km","unit_of_pressure":"bar","unit_of_temperature":"C"}}}
    """#

    private let imperialDriving = #"""
    {"data":{"car":{"car_id":2,"car_name":null},"status":{"display_name":"Red","state":"driving","state_since":"2026-10-17T07:00:00Z","odometer":1000,
    "car_status":{"healthy":true,"locked":true,"sentry_mode":false,"windows_open":false,"doors_open":false,"driver_front_door_open":false,"driver_rear_door_open":false,"passenger_front_door_open":false,"passenger_rear_door_open":false,"trunk_open":false,"frunk_open":false,"is_user_present":true,"center_display_state":2},
    "car_details":{"model":"Y","trim_badging":""},"car_exterior":{"exterior_color":"","spoiler_type":"","wheel_type":""},
    "car_geodata":{"geofence":"","location":{"latitude":37.77,"longitude":-122.42},"latitude":37.77,"longitude":-122.42},
    "car_versions":{"version":"2026.32.1","update_available":true,"update_version":"2026.38.2"},
    "driving_details":{"active_route":{"destination":"Work","energy_at_arrival":61,"distance_to_arrival":10,"minutes_to_arrival":14.5,"traffic_minutes_delay":2,"location":{"latitude":37.79,"longitude":-122.4}},"active_route_destination":"Work","active_route_latitude":37.79,"active_route_longitude":-122.4,"shift_state":"D","power":24,"speed":60,"heading":90,"elevation":20},
    "climate_details":{"is_climate_on":true,"inside_temp":77,"outside_temp":59,"is_preconditioning":false,"climate_keeper_mode":"off"},
    "battery_details":{"est_battery_range":180,"rated_battery_range":200,"ideal_battery_range":190,"battery_level":60,"usable_battery_level":60},
    "charging_details":{"plugged_in":false,"charging_state":"disconnected","charge_energy_added":0,"charge_limit_soc":80,"charge_port_door_open":false,"charger_actual_current":0,"charger_phases":0,"charger_power":0,"charger_voltage":0,"charge_current_request":0,"charge_current_request_max":0,"scheduled_charging_start_time":"","time_to_full_charge":0},
    "tpms_details":{"tpms_pressure_fl":42,"tpms_pressure_fr":42,"tpms_pressure_rl":41,"tpms_pressure_rr":41,"tpms_soft_warning_fl":false,"tpms_soft_warning_fr":false,"tpms_soft_warning_rl":false,"tpms_soft_warning_rr":false}},
    "units":{"unit_of_length":"mi","unit_of_pressure":"psi","unit_of_temperature":"F"}}}
    """#

    private func decode(_ json: String) throws -> LiveStatusDTO {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try XCTUnwrap(decoder.decode(LiveStatusEnvelope.self, from: Data(json.utf8)).data)
    }

    func testMetricStatusMapsOntoVehicleState() throws {
        var state = VehicleState(carID: 1)
        let now = Date()
        try decode(metricStatus).apply(to: &state, at: now)

        XCTAssertEqual(state.lastUpdated, now)
        XCTAssertEqual(state.displayName, "Blue Thunder")
        XCTAssertEqual(state.state, .charging)
        XCTAssertEqual(state.since, VehicleState.parseDate("2026-10-17T07:00:07Z"))
        XCTAssertEqual(state.odometer, 12345.6)
        XCTAssertEqual(state.model, "3")
        XCTAssertEqual(state.trimBadging, "P74D")
        XCTAssertEqual(state.version, "2026.32.1")
        XCTAssertEqual(state.updateAvailable, false)
        XCTAssertNil(state.updateVersion)

        XCTAssertEqual(state.batteryLevel, 72)
        XCTAssertEqual(state.usableBatteryLevel, 71)
        XCTAssertEqual(state.ratedBatteryRangeKm, 350.25)
        XCTAssertEqual(state.estBatteryRangeKm, 300.5)

        // TeslaMateApi lowercases charging_state; it must still read as charging.
        XCTAssertEqual(state.chargingState, .charging)
        XCTAssertTrue(state.isCharging)
        XCTAssertEqual(state.pluggedIn, true)
        XCTAssertEqual(state.chargerPower, 11)
        XCTAssertEqual(state.chargerVoltage, 230)
        XCTAssertEqual(state.chargerActualCurrent, 16)
        XCTAssertEqual(state.chargerPhases, 3)
        XCTAssertEqual(state.chargeLimitSoc, 90)
        XCTAssertEqual(state.timeToFullCharge, 1.83)
        XCTAssertNil(state.scheduledChargingStartTime, "Go's zero time means no schedule")

        XCTAssertEqual(state.latitude, 40.4168)
        XCTAssertEqual(state.longitude, -3.7038)
        XCTAssertEqual(state.geofence, "Home")
        XCTAssertEqual(state.heading, 180)
        XCTAssertEqual(state.elevation, 650)
        XCTAssertEqual(state.shiftState, .park)
        XCTAssertEqual(state.power, -11)
        XCTAssertNil(state.speed, "A parked car has no speed, as with MQTT")

        XCTAssertEqual(state.insideTemp, 21.5)
        XCTAssertEqual(state.outsideTemp, 12)
        XCTAssertEqual(state.locked, true)
        XCTAssertEqual(state.sentryMode, false)

        XCTAssertEqual(state.tpmsPressureFL, 2.9)
        XCTAssertEqual(state.tpmsPressureFR, 2.8)
        XCTAssertNil(state.tpmsPressureRL, "0 bar is a missing reading")
        XCTAssertEqual(state.tpmsSoftWarningFR, true)

        XCTAssertNil(state.activeRouteDestination)
        XCTAssertNil(state.activeRouteMilesToArrival)
    }

    func testImperialStatusIsNormalizedToMetric() throws {
        var state = VehicleState(carID: 2)
        try decode(imperialDriving).apply(to: &state)

        XCTAssertEqual(state.state, .driving)
        XCTAssertEqual(state.odometer!, 1609.344, accuracy: 0.0001)
        XCTAssertEqual(state.ratedBatteryRangeKm!, 321.8688, accuracy: 0.0001)
        XCTAssertEqual(state.speed!, 96.56064, accuracy: 0.0001)
        XCTAssertEqual(state.insideTemp!, 25, accuracy: 0.0001)
        XCTAssertEqual(state.outsideTemp!, 15, accuracy: 0.0001)
        XCTAssertEqual(state.tpmsPressureFL!, 42 / 14.503773800722, accuracy: 0.0001)
        XCTAssertEqual(state.chargingState, .disconnected)
        XCTAssertEqual(state.updateVersion, "2026.38.2")
        XCTAssertNil(state.geofence)
        XCTAssertNil(state.trimBadging)

        // With miles configured TeslaMateApi reports the route distance in miles.
        XCTAssertEqual(state.activeRouteDestination, "Work")
        XCTAssertEqual(state.activeRouteMilesToArrival!, 10, accuracy: 0.0001)
        XCTAssertEqual(state.activeRouteMinutesToArrival, 14.5)
        XCTAssertEqual(state.activeRouteEnergyAtArrival, 61)
        XCTAssertEqual(state.activeRouteLatitude, 37.79)
        XCTAssertNotNil(state.activeRouteUpdatedAt)
    }

    func testMetricRouteDistanceIsConvertedBackToMiles() throws {
        let json = metricStatus.replacingOccurrences(
            of: #""active_route":{"destination":"","energy_at_arrival":0,"distance_to_arrival":0"#,
            with: #""active_route":{"destination":"Home","energy_at_arrival":40,"distance_to_arrival":16.09344"#)
        var state = VehicleState(carID: 1)
        try decode(json).apply(to: &state)
        XCTAssertEqual(state.activeRouteDestination, "Home")
        XCTAssertEqual(state.activeRouteMilesToArrival!, 10, accuracy: 0.0001)
    }

    func testZeroValuesKeepPreviouslyKnownReadings() throws {
        var state = VehicleState(carID: 1)
        try decode(metricStatus).apply(to: &state)

        // What TeslaMateApi returns for topics it has not (re)received: Go zero values.
        let empty = #"""
        {"data":{"status":{"display_name":"","state":"","state_since":"","odometer":0,
        "car_geodata":{"geofence":"Home","location":{"latitude":0,"longitude":0},"latitude":0,"longitude":0},
        "battery_details":{"est_battery_range":0,"rated_battery_range":0,"ideal_battery_range":0,"battery_level":0,"usable_battery_level":0},
        "tpms_details":{"tpms_pressure_fl":0,"tpms_pressure_fr":0,"tpms_pressure_rl":0,"tpms_pressure_rr":0}},
        "units":{"unit_of_length":"km","unit_of_pressure":"bar","unit_of_temperature":"C"}}}
        """#
        try decode(empty).apply(to: &state)

        XCTAssertEqual(state.displayName, "Blue Thunder")
        XCTAssertEqual(state.state, .charging)
        XCTAssertEqual(state.odometer, 12345.6)
        XCTAssertEqual(state.batteryLevel, 72)
        XCTAssertEqual(state.ratedBatteryRangeKm, 350.25)
        XCTAssertEqual(state.latitude, 40.4168)
        XCTAssertEqual(state.tpmsPressureFL, 2.9)
    }

    func testStatusEndpointDecodesThroughTheAPIService() async throws {
        let json = metricStatus
        let api = service { request in
            XCTAssertEqual(request.url?.path, "/api/v1/cars/1/status")
            return (200, Data(json.utf8))
        }
        let status = try await api.fetchLiveStatus(carID: 1)
        var state = VehicleState(carID: 1)
        try XCTUnwrap(status).apply(to: &state)
        XCTAssertEqual(state.batteryLevel, 72)
        XCTAssertEqual(state.chargingState, .charging)
    }

    func testCarWithoutDataYetIsNotAnError() async throws {
        // TeslaMateApi answers HTTP 200 + error until the first MQTT topic for the car arrives.
        let api = service { _ in (200, Data(#"{"error":"no info on this car ID"}"#.utf8)) }
        let status = try await api.fetchLiveStatus(carID: 1)
        XCTAssertNil(status)
    }

    func testMQTTProblemsInsideTeslaMateApiAreExplained() async {
        let cases: [(Int, String, String)] = [
            (501, #"{"error":"mqtt disabled.. status not accessible!"}"#, "DISABLE_MQTT"),
            (500, #"{"error":"mqtt disconnected.. status not accessible!"}"#, "MQTT"),
        ]
        for (code, body, expected) in cases {
            do {
                _ = try await service { _ in (code, Data(body.utf8)) }.fetchLiveStatus(carID: 1)
                XCTFail("HTTP \(code) must fail")
            } catch {
                let message = (error as? APIError)?.errorDescription ?? ""
                XCTAssertTrue(message.contains(expected), message)
            }
        }
    }

    func testUnauthorizedStatusIsReportedAsAuthFailure() async {
        do {
            _ = try await service { _ in (401, Data("{}".utf8)) }.fetchLiveStatus(carID: 1)
            XCTFail("HTTP 401 must fail")
        } catch APIError.unauthorized {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLiveSourceDefaultsToMQTTForExistingConfigurations() throws {
        let legacy = try JSONDecoder().decode(ServerConfig.self, from: Data(#"{"mqttHost":"tesla.example.com"}"#.utf8))
        XCTAssertEqual(legacy.liveSource, .mqtt)
        XCTAssertEqual(legacy.apiPollingSeconds, 15)
        XCTAssertTrue(legacy.hasLiveSourceConfigured)

        var apiOnly = ServerConfig()
        apiOnly.liveSource = .api
        apiOnly.apiPollingSeconds = 30
        XCTAssertFalse(apiOnly.hasLiveSourceConfigured)
        apiOnly.apiBaseURL = "tesla.example.com/api"
        XCTAssertTrue(apiOnly.hasLiveSourceConfigured)

        let roundTrip = try JSONDecoder().decode(ServerConfig.self, from: JSONEncoder().encode(apiOnly))
        XCTAssertEqual(roundTrip.liveSource, .api)
        XCTAssertEqual(roundTrip.apiPollingSeconds, 30)

        apiOnly.apiPollingSeconds = 0
        XCTAssertEqual(apiOnly.effectiveAPIPollingSeconds, 5)
    }

    func testChargingStateParsingIgnoresCase() {
        XCTAssertEqual(ChargingState(raw: "Charging"), .charging)
        XCTAssertEqual(ChargingState(raw: "charging"), .charging)
        XCTAssertEqual(ChargingState(raw: "nopower"), .noPower)
        XCTAssertEqual(ChargingState(raw: "bogus"), .unknown)
        XCTAssertTrue(ConnectionStatus.polling.isLive)
    }

    private func service(handler: @escaping StatusURLProtocol.Handler) -> HistoryAPIService {
        let host = "status-\(UUID().uuidString.lowercased()).invalid"
        StatusURLProtocol.register(host: host, handler: handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StatusURLProtocol.self]
        return HistoryAPIService(config: .init(baseURL: "https://\(host)/api", basicAuth: nil, trust: .init(allowSelfSigned: false, pinnedPublicKeySHA256: nil), allowInsecure: false), session: URLSession(configuration: config))
    }
}
