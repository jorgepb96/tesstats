import Foundation

/// Ephemeral motion metrics derived from TeslaMate's speed samples. This never claims to
/// represent pedal or hydraulic-brake position; it only describes the change in reported speed.
struct MotionSnapshot: Equatable, Sendable {
    var speedKmh: Double?
    var powerKw: Double?
    var accelerationMetersPerSecondSquared: Double?
    var sampleDate: Date?

    func isFresh(at date: Date = Date(), maximumAge: TimeInterval = 5) -> Bool {
        guard let sampleDate else { return false }
        return date.timeIntervalSince(sampleDate) <= maximumAge
    }

    var isAccelerating: Bool { (accelerationMetersPerSecondSquared ?? 0) > 0.08 }
    var isDecelerating: Bool { (accelerationMetersPerSecondSquared ?? 0) < -0.08 }
    var isRegenerating: Bool { (powerKw ?? 0) < -0.5 }
}

@MainActor
@Observable
final class MotionEstimator {
    private(set) var snapshot = MotionSnapshot()
    private var previousSpeedKmh: Double?
    private var previousSpeedDate: Date?

    func ingest(speedKmh: Double?, powerKw: Double?, speedChanged: Bool, at date: Date = Date()) {
        snapshot.powerKw = powerKw
        guard speedChanged, let speedKmh else { return }

        var acceleration: Double?
        if let previousSpeedKmh, let previousSpeedDate {
            let dt = date.timeIntervalSince(previousSpeedDate)
            if dt >= 0.25, dt <= 5 {
                let raw = ((speedKmh - previousSpeedKmh) / 3.6) / dt
                let limited = min(8, max(-8, raw))
                if let old = snapshot.accelerationMetersPerSecondSquared {
                    acceleration = old * 0.65 + limited * 0.35
                } else {
                    acceleration = limited
                }
                if abs(acceleration ?? 0) < 0.03 { acceleration = 0 }
            }
        }

        previousSpeedKmh = speedKmh
        previousSpeedDate = date
        snapshot.speedKmh = speedKmh
        snapshot.accelerationMetersPerSecondSquared = acceleration
        snapshot.sampleDate = date
    }

    func reset() {
        snapshot = MotionSnapshot()
        previousSpeedKmh = nil
        previousSpeedDate = nil
    }
}

/// Tracks distance from the first odometer sample observed for the current drive.
/// The baseline survives view presentation changes and resets on the next driving transition.
@MainActor
@Observable
final class DriverTripDistanceEstimator {
    private(set) var distancesKm: [Int: Double] = [:]
    private var startOdometersKm: [Int: Double] = [:]

    func ingest(previous: VehicleState?, current: VehicleState) {
        let carID = current.carID
        guard current.isDriving else {
            if previous?.isDriving == true { startOdometersKm[carID] = nil }
            return
        }

        if previous?.isDriving != true || startOdometersKm[carID] == nil {
            if let odometer = current.odometer { startOdometersKm[carID] = odometer }
            distancesKm[carID] = 0
        }
        guard let start = startOdometersKm[carID], let odometer = current.odometer else { return }
        distancesKm[carID] = max(0, odometer - start)
    }

    func distance(for carID: Int?) -> Double? {
        carID.flatMap { distancesKm[$0] }
    }

    func reset() {
        distancesKm.removeAll()
        startOdometersKm.removeAll()
    }
}

/// Keeps each car's trip energy accumulator alive independently of Driver Display presentation.
/// This lets the display show the average from the beginning of the observed journey instead of
/// restarting the calculation whenever the driver opens or rotates the instrument screen.
@MainActor
@Observable
final class DriverTripConsumptionStore {
    private(set) var estimators: [Int: DriverTripConsumptionEstimator] = [:]

    func ingest(previous: VehicleState?, current: VehicleState) {
        var estimator = estimators[current.carID] ?? .init()
        estimator.ingest(isDriving: current.isDriving,
                         speedKmh: current.speed,
                         powerKw: current.power,
                         at: current.lastUpdated)
        estimators[current.carID] = estimator
    }

    func estimator(for carID: Int?) -> DriverTripConsumptionEstimator {
        carID.flatMap { estimators[$0] } ?? .init()
    }

    func reset() { estimators.removeAll() }
}

/// Integrates the power and speed samples visible during the current drive. Using time-integrated
/// energy and distance makes this value update continuously instead of waiting for a completed
/// drive to appear in history.
struct DriverTripConsumptionEstimator: Equatable, Sendable {
    /// A traffic light, a short stop or an intermittent source must not turn the current drive
    /// into a new trip. Five minutes parked is long enough to treat the next movement as a new
    /// journey while still preserving the average across ordinary pauses.
    static let tripBreakInterval: TimeInterval = 5 * 60

    private(set) var energyKWh: Double = 0
    private(set) var distanceKm: Double = 0
    private var previous: Sample?
    private var wasDriving = false
    private var inactiveSince: Date?

    var averageWhPerKm: Double? {
        guard distanceKm >= 0.05 else { return nil }
        return max(0, energyKWh * 1_000 / distanceKm)
    }

    mutating func ingest(isDriving: Bool,
                         speedKmh: Double?,
                         powerKw: Double?,
                         at date: Date) {
        guard isDriving else {
            previous = nil
            if wasDriving, inactiveSince == nil { inactiveSince = date }
            wasDriving = false
            return
        }

        if !wasDriving {
            if let inactiveSince,
               date.timeIntervalSince(inactiveSince) >= Self.tripBreakInterval {
                energyKWh = 0
                distanceKm = 0
            }
            previous = nil
        }
        wasDriving = true
        inactiveSince = nil

        guard let speedKmh, speedKmh.isFinite, speedKmh >= 0,
              let powerKw, powerKw.isFinite else {
            previous = nil
            return
        }

        let current = Sample(date: date, speedKmh: speedKmh, powerKw: powerKw)
        defer { previous = current }
        guard let previous else { return }
        let elapsed = date.timeIntervalSince(previous.date)
        guard elapsed > 0, elapsed <= 5 else { return }

        let hours = elapsed / 3_600
        distanceKm += ((previous.speedKmh + speedKmh) / 2) * hours
        energyKWh += ((previous.powerKw + powerKw) / 2) * hours
    }

    mutating func reset() {
        self = .init()
    }

    private struct Sample: Equatable, Sendable {
        let date: Date
        let speedKmh: Double
        let powerKw: Double
    }
}
