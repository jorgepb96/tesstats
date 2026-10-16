import Foundation
import Observation

struct DriverWeatherAttribution: Equatable, Sendable {
    let lightMarkURL: URL
    let darkMarkURL: URL
    let legalPageURL: URL
}

#if os(iOS)
import CoreLocation
import CoreMotion
import WeatherKit

/// Foreground-only telemetry used by Driver Display. GPS provides the preferred absolute speed
/// when its reported accuracy is good; Core Motion is used only for the separate acceleration
/// indicator. TeslaMate remains the fallback for vehicle-only values and unavailable GPS.
@MainActor
@Observable
final class DriverPhoneTelemetry: NSObject, @preconcurrency CLLocationManagerDelegate {
    private(set) var coordinate: Coordinate?
    private(set) var speedKmh: Double?
    private(set) var speedAccuracyKmh: Double?
    private(set) var heading: Int?
    private(set) var accelerationMetersPerSecondSquared: Double?
    private(set) var tripDistanceKm: Double = 0
    private(set) var outsideTemperatureC: Double?
    private(set) var weatherAttribution: DriverWeatherAttribution?
    private(set) var speedSampleDate: Date?
    private(set) var coordinateSampleDate: Date?
    private(set) var isRunning = false

    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionManager()
    private var previousLocation: CLLocation?
    private var previousSpeedSample: (metersPerSecond: Double, date: Date)?
    private var speedFilter = DriverGPSSpeedFilter()
    private var latestMotionMagnitude: Double?
    private var weatherTask: Task<Void, Never>?
    private var lastWeatherRequest: (location: CLLocation, date: Date)?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.activityType = .automotiveNavigation
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        if ProcessInfo.processInfo.environment["TESSTATS_PHONE_TELEMETRY_DEMO"] == "1" {
            coordinate = Coordinate(latitude: 40.4258, longitude: -3.6991)
            speedKmh = 72
            speedAccuracyKmh = 1.2
            heading = 18
            accelerationMetersPerSecondSquared = -1.15
            tripDistanceKm = 12.4
            outsideTemperatureC = 22
            speedSampleDate = Date()
            coordinateSampleDate = Date()
            return
        }

        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.startUpdatingLocation()
        default:
            break
        }
        startMotionUpdates()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        locationManager.stopUpdatingLocation()
        motionManager.stopDeviceMotionUpdates()
        weatherTask?.cancel()
        weatherTask = nil
        previousSpeedSample = nil
        speedFilter = DriverGPSSpeedFilter()
    }

    func isSpeedFresh(at date: Date = Date(), maximumAge: TimeInterval = 2.5) -> Bool {
        if ProcessInfo.processInfo.environment["TESSTATS_PHONE_TELEMETRY_DEMO"] == "1" { return true }
        guard let speedSampleDate else { return false }
        let age = date.timeIntervalSince(speedSampleDate)
        return age >= -1 && age <= maximumAge
    }

    func hasFreshLocation(at date: Date = Date(), maximumAge: TimeInterval = 3) -> Bool {
        if ProcessInfo.processInfo.environment["TESSTATS_PHONE_TELEMETRY_DEMO"] == "1" { return true }
        guard let coordinateSampleDate else { return false }
        let age = date.timeIntervalSince(coordinateSampleDate)
        return age >= -1 && age <= maximumAge
    }

    func speedSample(at date: Date = Date()) -> DriverSpeedSample? {
        guard let speedKmh, let speedAccuracyKmh, isSpeedFresh(at: date) else { return nil }
        let effectiveDate = ProcessInfo.processInfo.environment["TESSTATS_PHONE_TELEMETRY_DEMO"] == "1"
            ? date : (speedSampleDate ?? date)
        return DriverSpeedSample(speedKmh: speedKmh, date: effectiveDate, source: .iphoneGPS,
                                 accuracyKmh: speedAccuracyKmh)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isRunning else { return }
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isRunning, let location = locations.last,
              location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 80,
              abs(Date().timeIntervalSince(location.timestamp)) <= 15 else { return }

        coordinate = location.coordinate.coordinate
        coordinateSampleDate = location.timestamp
        if location.course >= 0 { heading = Int(location.course.rounded()) }

        if location.speed >= 0, location.speedAccuracy >= 0,
           let filtered = speedFilter.ingest(measuredMetersPerSecond: location.speed,
                                             accuracyMetersPerSecond: location.speedAccuracy,
                                             at: location.timestamp) {
            // `CLLocation.speed` is Apple's instantaneous, sensor-fused ground speed. Do not add
            // the vehicle cluster's legal display allowance or extrapolate between fixes: both
            // make a phone GPS speedometer less truthful and can overshoot during speed changes.
            speedKmh = filtered * 3.6
            speedAccuracyKmh = location.speedAccuracy * 3.6
            speedSampleDate = location.timestamp
            updateAcceleration(speedMetersPerSecond: location.speed, at: location.timestamp)
        }

        if let previousLocation {
            let elapsed = location.timestamp.timeIntervalSince(previousLocation.timestamp)
            let segment = location.distance(from: previousLocation)
            if elapsed > 0, elapsed <= 15, segment >= 1, segment <= 500 {
                tripDistanceKm += segment / 1_000
            }
        }
        previousLocation = location
        requestWeatherIfNeeded(for: location)
    }

    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 20.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let value = motion.userAcceleration
            let magnitude = sqrt(value.x * value.x + value.y * value.y + value.z * value.z) * 9.80665
            self.latestMotionMagnitude = min(8, magnitude)
        }
    }

    private func updateAcceleration(speedMetersPerSecond: Double, at date: Date) {
        defer { previousSpeedSample = (speedMetersPerSecond, date) }
        guard let previousSpeedSample else { return }
        let elapsed = date.timeIntervalSince(previousSpeedSample.date)
        guard elapsed >= 0.25, elapsed <= 5 else { return }

        let gpsAcceleration = (speedMetersPerSecond - previousSpeedSample.metersPerSecond) / elapsed
        let signedMotion = latestMotionMagnitude.map { gpsAcceleration < 0 ? -$0 : $0 }
        let measured = signedMotion.map { gpsAcceleration * 0.7 + $0 * 0.3 } ?? gpsAcceleration
        let limited = min(8, max(-8, measured))
        let smoothed = accelerationMetersPerSecondSquared.map { $0 * 0.55 + limited * 0.45 } ?? limited
        accelerationMetersPerSecondSquared = abs(smoothed) < 0.04 ? 0 : smoothed
    }

    private func requestWeatherIfNeeded(for location: CLLocation) {
        if let lastWeatherRequest,
           Date().timeIntervalSince(lastWeatherRequest.date) < 600,
           location.distance(from: lastWeatherRequest.location) < 5_000 { return }

        lastWeatherRequest = (location, Date())
        weatherTask?.cancel()
        weatherTask = Task { @MainActor [weak self] in
            do {
                async let weather = WeatherService.shared.weather(for: location, including: .current)
                async let attribution = WeatherService.shared.attribution
                let (current, source) = try await (weather, attribution)
                guard let self, !Task.isCancelled else { return }
                self.outsideTemperatureC = current.temperature.converted(to: .celsius).value
                self.weatherAttribution = DriverWeatherAttribution(
                    lightMarkURL: source.combinedMarkLightURL,
                    darkMarkURL: source.combinedMarkDarkURL,
                    legalPageURL: source.legalPageURL)
            } catch {
                // Location, speed and motion remain fully usable if WeatherKit is unavailable.
            }
        }
    }
}

#else

@MainActor
@Observable
final class DriverPhoneTelemetry {
    private(set) var coordinate: Coordinate?
    private(set) var speedKmh: Double?
    private(set) var speedAccuracyKmh: Double?
    private(set) var heading: Int?
    private(set) var accelerationMetersPerSecondSquared: Double?
    private(set) var tripDistanceKm: Double = 0
    private(set) var outsideTemperatureC: Double?
    private(set) var weatherAttribution: DriverWeatherAttribution?
    private(set) var speedSampleDate: Date?
    private(set) var coordinateSampleDate: Date?
    private(set) var isRunning = false

    func start() { isRunning = true }
    func stop() { isRunning = false }
    func isSpeedFresh(at date: Date = Date(), maximumAge: TimeInterval = 2.5) -> Bool { false }
    func hasFreshLocation(at date: Date = Date(), maximumAge: TimeInterval = 3) -> Bool { false }
    func speedSample(at date: Date = Date()) -> DriverSpeedSample? { nil }
}

#endif
