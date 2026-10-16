import Foundation

enum DriverSpeedSource: Equatable, Sendable {
    case vehicleBluetooth
    case iphoneGPS
    case teslaMate
}

struct DriverPowerSample: Equatable, Sendable {
    let powerKw: Double
    let date: Date

    func value(at now: Date, maximumAge: TimeInterval = 5) -> Double? {
        let age = now.timeIntervalSince(date)
        guard powerKw.isFinite, age >= -1, age <= maximumAge else { return nil }
        return powerKw
    }
}

struct DriverSpeedSample: Equatable, Sendable {
    let speedKmh: Double
    let date: Date
    let source: DriverSpeedSource
    /// Core Location's reported uncertainty, converted to km/h. TeslaMate has no
    /// equivalent field, so its samples leave this nil.
    let accuracyKmh: Double?

    func isFresh(at now: Date, maximumAge: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= -1 && age <= maximumAge
    }
}

struct DriverResolvedSpeed: Equatable, Sendable {
    let speedKmh: Double
    let source: DriverSpeedSource
    let isReducedAccuracy: Bool
}

/// Selects the best absolute speed without integrating accelerometer samples. Core Location
/// already fuses the phone's positioning sensors and reports an explicit speed uncertainty.
/// TeslaMate remains the fallback in tunnels, poor GPS conditions, or denied permission.
enum DriverSpeedFusion {
    /// Long enough to cover a single slow vehicle response, but short enough to leave a frozen
    /// reading behind once the service marks the BLE stream unstable.
    static let bluetoothMaximumAge: TimeInterval = 2.5
    static let preferredPhoneMaximumAge: TimeInterval = 2.5
    static let teslaMateMaximumAge: TimeInterval = 5
    static let preferredPhoneAccuracyKmh = 7.2       // 2 m/s
    static let degradedPhoneAccuracyKmh = 14.4       // 4 m/s

    static func applyingDisplayAdjustment(
        to reading: DriverResolvedSpeed?,
        enabled: Bool,
        adjustmentKmh: Double
    ) -> DriverResolvedSpeed? {
        guard let reading, enabled, reading.source == .iphoneGPS,
              adjustmentKmh.isFinite else { return reading }
        // An offset must never make a stationary vehicle appear to be moving.
        let adjusted = reading.speedKmh < 1
            ? 0
            : max(0, reading.speedKmh + min(10, max(-10, adjustmentKmh)))
        return DriverResolvedSpeed(speedKmh: adjusted,
                                   source: reading.source,
                                   isReducedAccuracy: reading.isReducedAccuracy)
    }

    static func resolve(
        bluetooth: DriverSpeedSample? = nil,
        phone: DriverSpeedSample?,
        teslaMate: DriverSpeedSample?,
        at now: Date,
        mode: DriverTelemetryMode = .automatic,
        allowStationaryTeslaMate: Bool = false
    ) -> DriverResolvedSpeed? {
        if mode != .iphoneAndTeslaMate, let bluetooth,
           bluetooth.isFresh(at: now, maximumAge: bluetoothMaximumAge) {
            return DriverResolvedSpeed(speedKmh: bluetooth.speedKmh, source: .vehicleBluetooth,
                                       isReducedAccuracy: false)
        }
        if mode == .bluetooth { return nil }
        let phoneFresh = phone?.isFresh(at: now, maximumAge: preferredPhoneMaximumAge) == true
        let phoneAccuracy = phone?.accuracyKmh ?? .infinity

        if let phone, phoneFresh, phoneAccuracy <= preferredPhoneAccuracyKmh {
            return DriverResolvedSpeed(speedKmh: phone.speedKmh, source: .iphoneGPS,
                                       isReducedAccuracy: false)
        }

        // A current, moderately degraded GPS reading remains temporally closer to the car than a
        // server sample. Prefer it before TeslaMate and surface the lower confidence explicitly.
        if let phone, phoneFresh, phoneAccuracy <= degradedPhoneAccuracyKmh {
            return DriverResolvedSpeed(speedKmh: phone.speedKmh, source: .iphoneGPS,
                                       isReducedAccuracy: true)
        }

        if let teslaMate,
           teslaMate.isFresh(at: now, maximumAge: teslaMateMaximumAge)
            || (allowStationaryTeslaMate && teslaMate.speedKmh == 0) {
            return DriverResolvedSpeed(speedKmh: teslaMate.speedKmh, source: .teslaMate,
                                       isReducedAccuracy: false)
        }

        return nil
    }
}

enum DriverMapPositionPolicy {
    /// The mounted phone is the only local position source. Once it has a valid coordinate, a
    /// momentary gap must not reveal the remote TeslaMate coordinate underneath it.
    static func resolve(phone: Coordinate?, teslaMate: Coordinate?) -> Coordinate? {
        phone ?? teslaMate
    }
}

/// A light, accuracy-adaptive validator on top of CLLocation.speed. High-confidence fixes pass
/// through unchanged because Core Location has already fused the device sensors for navigation.
/// Only moderately uncertain fixes receive minimal smoothing, and impossible jumps are rejected.
struct DriverGPSSpeedFilter: Sendable {
    private var filteredMetersPerSecond: Double?
    private var previousRawMetersPerSecond: Double?
    private var previousAccuracyMetersPerSecond: Double?
    private var previousDate: Date?

    mutating func ingest(
        measuredMetersPerSecond: Double,
        accuracyMetersPerSecond: Double,
        at date: Date
    ) -> Double? {
        guard measuredMetersPerSecond.isFinite, measuredMetersPerSecond >= 0,
              accuracyMetersPerSecond.isFinite, accuracyMetersPerSecond >= 0,
              accuracyMetersPerSecond <= DriverSpeedFusion.degradedPhoneAccuracyKmh / 3.6 else {
            return nil
        }

        if let previousDate, let previousRawMetersPerSecond, let previousAccuracyMetersPerSecond {
            let elapsed = date.timeIntervalSince(previousDate)
            if elapsed <= 0 { return nil }
            if elapsed <= 5 {
                // 12 m/s² is above normal road acceleration and emergency braking. The
                // accuracy allowance avoids rejecting a legitimate correction after GPS drift.
                let accuracyAllowance = max(2, accuracyMetersPerSecond + previousAccuracyMetersPerSecond)
                let maximumDelta = 12 * elapsed + accuracyAllowance
                guard abs(measuredMetersPerSecond - previousRawMetersPerSecond) <= maximumDelta else {
                    return nil
                }
            } else {
                filteredMetersPerSecond = nil
            }
        }

        let alpha: Double
        switch accuracyMetersPerSecond {
        case ...2.0: alpha = 1.0
        default: alpha = 0.90
        }

        var filtered = filteredMetersPerSecond.map {
            $0 + (measuredMetersPerSecond - $0) * alpha
        } ?? measuredMetersPerSecond

        if measuredMetersPerSecond < 0.55, accuracyMetersPerSecond <= 1.2 {
            filtered = 0
        }

        filteredMetersPerSecond = filtered
        previousRawMetersPerSecond = measuredMetersPerSecond
        previousAccuracyMetersPerSecond = accuracyMetersPerSecond
        previousDate = date
        return filtered
    }
}
