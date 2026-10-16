import XCTest
#if os(iOS)
import UIKit
#endif
@testable import Tesstats

@MainActor
final class DriverDisplayTests: XCTestCase {
    #if os(iOS)
    func testPlatformClipboardCopiesTheCompleteVIN() {
        let vin = "5YJ3E1EA7KF000000"

        PlatformClipboard.copy(vin)

        XCTAssertEqual(UIPasteboard.general.string, vin)
    }
    #endif

    func testActiveRouteParsesCurrentTeslaMatePayload() {
        var state = VehicleState(carID: 1)
        state.apply(metric: "active_route", value: #"""
        {
          "destination":"Work",
          "energy_at_arrival":54,
          "miles_to_arrival":6.5,
          "minutes_to_arrival":14.25,
          "traffic_minutes_delay":2.0,
          "location":{"latitude":40.45,"longitude":-3.68},
          "error":null
        }
        """#)

        XCTAssertEqual(state.activeRouteDestination, "Work")
        XCTAssertEqual(state.activeRouteEnergyAtArrival, 54)
        XCTAssertEqual(state.activeRouteMilesToArrival ?? 0, 6.5, accuracy: 0.001)
        XCTAssertEqual(state.activeRouteMinutesToArrival ?? 0, 14.25, accuracy: 0.001)
        XCTAssertEqual(state.routeCoordinate, Coordinate(latitude: 40.45, longitude: -3.68))
        XCTAssertNil(state.activeRouteError)
        XCTAssertNotNil(state.activeRouteUpdatedAt)
    }

    func testActiveRouteErrorClearsStaleGuidance() {
        var state = VehicleState(carID: 1)
        state.activeRouteDestination = "Old destination"
        state.activeRouteMilesToArrival = 12
        state.apply(metric: "active_route", value: #"{"error":"No active route available"}"#)

        XCTAssertNil(state.activeRouteDestination)
        XCTAssertNil(state.activeRouteMilesToArrival)
        XCTAssertEqual(state.activeRouteError, "No active route available")
    }

    func testMotionEstimatorCalculatesAndSmoothsAcceleration() {
        let estimator = MotionEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        estimator.ingest(speedKmh: 36, powerKw: 20, speedChanged: true, at: start)
        estimator.ingest(speedKmh: 43.2, powerKw: 30, speedChanged: true, at: start.addingTimeInterval(2))

        XCTAssertEqual(estimator.snapshot.accelerationMetersPerSecondSquared ?? 0, 1, accuracy: 0.001)
        XCTAssertTrue(estimator.snapshot.isAccelerating)
        XCTAssertTrue(estimator.snapshot.isFresh(at: start.addingTimeInterval(4)))
        XCTAssertFalse(estimator.snapshot.isFresh(at: start.addingTimeInterval(8)))
    }

    func testMotionEstimatorRejectsLargeSampleGapAndTracksRegen() {
        let estimator = MotionEstimator()
        let start = Date(timeIntervalSince1970: 2_000)
        estimator.ingest(speedKmh: 80, powerKw: 10, speedChanged: true, at: start)
        estimator.ingest(speedKmh: 20, powerKw: -35, speedChanged: true, at: start.addingTimeInterval(8))

        XCTAssertNil(estimator.snapshot.accelerationMetersPerSecondSquared)
        XCTAssertTrue(estimator.snapshot.isRegenerating)
    }

    func testSpeedFusionPrefersAccurateFreshPhoneGPS() {
        let now = Date(timeIntervalSince1970: 3_000)
        let phone = DriverSpeedSample(speedKmh: 81, date: now.addingTimeInterval(-0.4),
                                      source: .iphoneGPS, accuracyKmh: 3.6)
        let teslaMate = DriverSpeedSample(speedKmh: 76, date: now.addingTimeInterval(-0.1),
                                          source: .teslaMate, accuracyKmh: nil)

        let resolved = DriverSpeedFusion.resolve(phone: phone, teslaMate: teslaMate, at: now)

        XCTAssertEqual(resolved?.source, .iphoneGPS)
        XCTAssertEqual(resolved?.speedKmh, 81)
        XCTAssertEqual(resolved?.isReducedAccuracy, false)
    }

    func testSpeedFusionPrefersCurrentModerateGPSOverDelayedTeslaMate() {
        let now = Date(timeIntervalSince1970: 4_000)
        let phone = DriverSpeedSample(speedKmh: 94, date: now.addingTimeInterval(-0.2),
                                      source: .iphoneGPS, accuracyKmh: 10.8)
        let teslaMate = DriverSpeedSample(speedKmh: 88, date: now.addingTimeInterval(-2),
                                          source: .teslaMate, accuracyKmh: nil)

        let resolved = DriverSpeedFusion.resolve(phone: phone, teslaMate: teslaMate, at: now)

        XCTAssertEqual(resolved?.source, .iphoneGPS)
        XCTAssertEqual(resolved?.speedKmh, 94)
        XCTAssertEqual(resolved?.isReducedAccuracy, true)
    }

    func testSpeedFusionUsesDegradedGPSOnlyWithoutFreshTeslaMate() {
        let now = Date(timeIntervalSince1970: 5_000)
        let phone = DriverSpeedSample(speedKmh: 52, date: now.addingTimeInterval(-1),
                                      source: .iphoneGPS, accuracyKmh: 10.8)
        let teslaMate = DriverSpeedSample(speedKmh: 47, date: now.addingTimeInterval(-8),
                                          source: .teslaMate, accuracyKmh: nil)

        let resolved = DriverSpeedFusion.resolve(phone: phone, teslaMate: teslaMate, at: now)

        XCTAssertEqual(resolved?.source, .iphoneGPS)
        XCTAssertEqual(resolved?.isReducedAccuracy, true)
    }

    func testTelemetryModesNeverUseAnUnselectedSpeedSource() {
        let now = Date(timeIntervalSince1970: 5_500)
        let bluetooth = DriverSpeedSample(speedKmh: 91, date: now,
                                          source: .vehicleBluetooth, accuracyKmh: nil)
        let phone = DriverSpeedSample(speedKmh: 88, date: now,
                                      source: .iphoneGPS, accuracyKmh: 1)
        let teslaMate = DriverSpeedSample(speedKmh: 84, date: now,
                                          source: .teslaMate, accuracyKmh: nil)

        XCTAssertEqual(DriverSpeedFusion.resolve(bluetooth: bluetooth, phone: phone,
                                                 teslaMate: teslaMate, at: now,
                                                 mode: .bluetooth)?.source,
                       .vehicleBluetooth)
        XCTAssertEqual(DriverSpeedFusion.resolve(bluetooth: bluetooth, phone: phone,
                                                 teslaMate: teslaMate, at: now,
                                                 mode: .iphoneAndTeslaMate)?.source,
                       .iphoneGPS)

        let staleBluetooth = DriverSpeedSample(
            speedKmh: 91,
            date: now.addingTimeInterval(-(DriverSpeedFusion.bluetoothMaximumAge + 0.1)),
            source: .vehicleBluetooth,
            accuracyKmh: nil
        )
        XCTAssertNil(DriverSpeedFusion.resolve(bluetooth: staleBluetooth, phone: phone,
                                               teslaMate: teslaMate, at: now,
                                               mode: .bluetooth))
    }

    func testMapPositionKeepsPhoneCoordinateInsteadOfRemoteVehicle() {
        let phone = Coordinate(latitude: 40.4168, longitude: -3.7038)
        let remoteVehicle = Coordinate(latitude: 48.8566, longitude: 2.3522)

        XCTAssertEqual(DriverMapPositionPolicy.resolve(phone: phone, teslaMate: remoteVehicle), phone)
        XCTAssertEqual(DriverMapPositionPolicy.resolve(phone: nil, teslaMate: remoteVehicle), remoteVehicle)
    }

    func testGPSSpeedFilterAdaptsToAccuracyAndRejectsImpossibleJump() {
        var filter = DriverGPSSpeedFilter()
        let start = Date(timeIntervalSince1970: 6_000)

        XCTAssertEqual(filter.ingest(measuredMetersPerSecond: 20, accuracyMetersPerSecond: 0.5,
                                     at: start) ?? -1, 20, accuracy: 0.001)
        XCTAssertEqual(filter.ingest(measuredMetersPerSecond: 21, accuracyMetersPerSecond: 0.5,
                                     at: start.addingTimeInterval(1)) ?? -1, 21, accuracy: 0.001)
        XCTAssertNil(filter.ingest(measuredMetersPerSecond: 60, accuracyMetersPerSecond: 0.5,
                                   at: start.addingTimeInterval(1.1)))
        XCTAssertNil(filter.ingest(measuredMetersPerSecond: 21, accuracyMetersPerSecond: 5,
                                   at: start.addingTimeInterval(2)))
    }

    func testOptionalPhoneSpeedAdjustmentDefaultsToTwoAndOnlyChangesGPS() throws {
        let defaults = DriverDisplayConfiguration()
        XCTAssertTrue(defaults.iphoneSpeedAdjustmentEnabled)
        XCTAssertEqual(defaults.iphoneSpeedAdjustmentKmh, 2)

        let gps = DriverResolvedSpeed(speedKmh: 50, source: .iphoneGPS, isReducedAccuracy: false)
        let stationaryGPS = DriverResolvedSpeed(speedKmh: 0, source: .iphoneGPS, isReducedAccuracy: false)
        let bluetooth = DriverResolvedSpeed(speedKmh: 50, source: .vehicleBluetooth, isReducedAccuracy: false)
        XCTAssertEqual(try XCTUnwrap(DriverSpeedFusion.applyingDisplayAdjustment(
            to: gps, enabled: true, adjustmentKmh: 2
        )).speedKmh, 52)
        XCTAssertEqual(try XCTUnwrap(DriverSpeedFusion.applyingDisplayAdjustment(
            to: gps, enabled: true, adjustmentKmh: -2
        )).speedKmh, 48)
        XCTAssertEqual(try XCTUnwrap(DriverSpeedFusion.applyingDisplayAdjustment(
            to: gps, enabled: false, adjustmentKmh: 2
        )).speedKmh, 50)
        XCTAssertEqual(try XCTUnwrap(DriverSpeedFusion.applyingDisplayAdjustment(
            to: bluetooth, enabled: true, adjustmentKmh: 2
        )).speedKmh, 50)
        XCTAssertEqual(try XCTUnwrap(DriverSpeedFusion.applyingDisplayAdjustment(
            to: stationaryGPS, enabled: true, adjustmentKmh: 2
        )).speedKmh, 0)
    }

    func testVehicleStateRejectsUnsafeExternalNumbersAndCoordinates() {
        var state = VehicleState(carID: 1)
        state.speed = 42
        state.latitude = 40
        state.longitude = -3

        state.apply(metric: "speed", value: "nan")
        state.apply(metric: "latitude", value: "inf")
        state.apply(metric: "longitude", value: "-inf")

        XCTAssertNil(state.speed)
        XCTAssertNil(state.latitude)
        XCTAssertNil(state.longitude)
        XCTAssertNil(Coordinate(latitude: Optional(91), longitude: Optional(0)))
        XCTAssertNil(Coordinate(latitude: Optional(0), longitude: Optional(181)))
    }

    func testMapInterpolationMovesContinuouslyAndClampsProgress() {
        let start = Coordinate(latitude: 40, longitude: -4)
        let end = Coordinate(latitude: 42, longitude: -2)

        XCTAssertEqual(DriverMapInterpolation.coordinate(from: start, to: end, fraction: 0.5),
                       Coordinate(latitude: 41, longitude: -3))
        XCTAssertEqual(DriverMapInterpolation.coordinate(from: start, to: end, fraction: -1), start)
        XCTAssertEqual(DriverMapInterpolation.coordinate(from: start, to: end, fraction: 2), end)
    }

    func testMapCameraOffsetKeepsVehicleAtSameReferencePointAcrossZoom() {
        let portraitNear = DriverMapCameraPolicy.offsetMeters(layout: .portrait, zoomFactor: 0.5)
        let portraitFar = DriverMapCameraPolicy.offsetMeters(layout: .portrait, zoomFactor: 2)
        let landscapeNear = DriverMapCameraPolicy.offsetMeters(layout: .landscape, zoomFactor: 0.5)
        let landscapeFar = DriverMapCameraPolicy.offsetMeters(layout: .landscape, zoomFactor: 2)

        XCTAssertEqual(portraitFar / portraitNear, 4, accuracy: 0.001)
        XCTAssertEqual(landscapeFar / landscapeNear, 4, accuracy: 0.001)
        XCTAssertLessThan(portraitNear / (820 * 0.5), landscapeNear / (850 * 0.5),
                          "Portrait should place the vehicle higher than the landscape map offset")
        XCTAssertEqual(DriverMapCameraPolicy.offsetMeters(layout: .portrait, zoomFactor: .nan), 68)
    }

    func testCurrentTripConsumptionIntegratesLiveSpeedAndPower() {
        var estimator = DriverTripConsumptionEstimator()
        let start = Date(timeIntervalSince1970: 6_500)
        estimator.ingest(isDriving: true, speedKmh: 36, powerKw: 10, at: start)
        estimator.ingest(isDriving: true, speedKmh: 36, powerKw: 20,
                         at: start.addingTimeInterval(5))

        XCTAssertEqual(estimator.distanceKm, 0.05, accuracy: 0.0001)
        XCTAssertEqual(estimator.averageWhPerKm ?? -1, 416.666, accuracy: 0.01)

        estimator.ingest(isDriving: false, speedKmh: 0, powerKw: 0,
                         at: start.addingTimeInterval(6))
        estimator.ingest(isDriving: true, speedKmh: 18, powerKw: 4,
                         at: start.addingTimeInterval(10))
        XCTAssertEqual(estimator.distanceKm, 0.05, accuracy: 0.0001)
        XCTAssertNotNil(estimator.averageWhPerKm)
        estimator.ingest(isDriving: true, speedKmh: 18, powerKw: 4,
                         at: start.addingTimeInterval(15))
        XCTAssertEqual(estimator.distanceKm, 0.075, accuracy: 0.0001)
        XCTAssertEqual(estimator.averageWhPerKm ?? -1, 351.851, accuracy: 0.01,
                       "The display must retain the whole-trip weighted average, not the latest sample")

        estimator.ingest(isDriving: false, speedKmh: 0, powerKw: 0,
                         at: start.addingTimeInterval(16))
        estimator.ingest(isDriving: true, speedKmh: 18, powerKw: 4,
                         at: start.addingTimeInterval(16 + DriverTripConsumptionEstimator.tripBreakInterval))
        XCTAssertEqual(estimator.distanceKm, 0)
        XCTAssertNil(estimator.averageWhPerKm)
    }

    func testTripConsumptionStorePreservesAverageBeforeDriverDisplayOpens() {
        let store = DriverTripConsumptionStore()
        let startDate = Date(timeIntervalSince1970: 7_000)
        var start = VehicleState(carID: 42)
        start.state = .driving
        start.shiftState = .drive
        start.speed = 36
        start.power = 10
        start.lastUpdated = startDate
        store.ingest(previous: nil, current: start)

        var later = start
        later.power = 20
        later.lastUpdated = startDate.addingTimeInterval(5)
        store.ingest(previous: start, current: later)

        let valueVisibleWhenDisplayOpens = store.estimator(for: 42)
        XCTAssertEqual(valueVisibleWhenDisplayOpens.distanceKm, 0.05, accuracy: 0.0001)
        XCTAssertEqual(valueVisibleWhenDisplayOpens.averageWhPerKm ?? -1, 416.666, accuracy: 0.01)
    }

    func testEveryDriverElementCanBeHiddenAndRestoredIndependently() throws {
        for module in DriverDisplayModule.allCases {
            var config = DriverDisplayConfiguration()
            config.hiddenModules = [module]
            let decoded = try JSONDecoder().decode(DriverDisplayConfiguration.self,
                                                   from: JSONEncoder().encode(config))
            XCTAssertEqual(Set(decoded.visibleModules), Set(DriverDisplayModule.allCases).subtracting([module]))
        }
        var config = DriverDisplayConfiguration()
        config.hiddenModules = DriverDisplayModule.allCases
        XCTAssertTrue(config.visibleModules.isEmpty)
        config.hiddenModules = []
        XCTAssertEqual(Set(config.visibleModules), Set(DriverDisplayModule.allCases))
    }

    func testLegacyGroupedVisibilityMigratesWithoutRevealingHiddenData() throws {
        let data = Data(#"{"preset":"custom","modules":["speed","battery","environment"],"hiddenModules":["speed","battery","environment"]}"#.utf8)
        let decoded = try JSONDecoder().decode(DriverDisplayConfiguration.self, from: data)
        for hidden: DriverDisplayModule in [.speed, .gear, .speedActivity, .battery, .range, .environment, .outsideTemperature] {
            XCTAssertFalse(decoded.visibleModules.contains(hidden))
        }
        XCTAssertEqual(Set(decoded.modules), Set(DriverDisplayModule.allCases))
        XCTAssertTrue(decoded.visibleModules.contains(.odometer))
    }

    func testDriverTripDistanceUsesOdometerAndResetsForNextDrive() {
        let estimator = DriverTripDistanceEstimator()
        var start = VehicleState(carID: 7)
        start.state = .driving
        start.odometer = 10_000
        estimator.ingest(previous: nil, current: start)

        var later = start
        later.odometer = 10_012.6
        estimator.ingest(previous: start, current: later)
        XCTAssertEqual(estimator.distance(for: 7) ?? -1, 12.6, accuracy: 0.001)

        var parked = later
        parked.state = .online
        parked.shiftState = .park
        estimator.ingest(previous: later, current: parked)

        var nextDrive = parked
        nextDrive.state = .driving
        nextDrive.shiftState = .drive
        nextDrive.odometer = 10_050
        estimator.ingest(previous: parked, current: nextDrive)
        XCTAssertEqual(estimator.distance(for: 7) ?? -1, 0, accuracy: 0.001)
    }
}
