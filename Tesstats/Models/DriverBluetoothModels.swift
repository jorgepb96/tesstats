import Foundation

/// Stable, privacy-preserving identity for one physical Tesla. The identifier is a SHA-256
/// digest of the normalized VIN; the VIN itself is kept in the device-only Keychain.
struct DriverBluetoothVehicleIdentity: Equatable, Sendable {
    let carID: Int
    let vehicleID: String
    let vin: String
    let displayName: String
    let model: String?

    var maskedVIN: String {
        guard vin.count >= 6 else { return "••••••" }
        return "•••••••••••" + vin.suffix(6)
    }

    var isInitiallySupported: Bool {
        guard let model = model?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return model == "3" || model == "Y" || model.contains("MODEL 3") || model.contains("MODEL Y")
    }
}

enum DriverBluetoothPairingState: Equatable, Sendable {
    case unavailable(String)
    case unpaired
    case connecting
    case awaitingVehicleApproval
    case pairedDisabled
    case paired
    case failed(String)

    var isPaired: Bool {
        switch self {
        case .paired, .pairedDisabled: true
        default: false
        }
    }
}

enum DriverBluetoothConnectionState: Equatable, Sendable {
    case idle
    case scanning
    case connecting
    case authenticating
    case connected
    case failed(String)

    var isConnected: Bool { self == .connected }
}

enum DriverBluetoothLinkPolicy {
    /// Auto mode requires a short run of valid authenticated replies before returning to BLE.
    /// This is the hysteresis that prevents a single sporadic packet from toggling the UI.
    static let responsesRequiredForStableTelemetry = 3
    /// Missing one or two application replies does not mean CoreBluetooth disconnected.
    static let timeoutsBeforeSessionReconnect = 6
}

struct DriverBluetoothTelemetryStability: Equatable, Sendable {
    private(set) var consecutiveResponses = 0
    private(set) var consecutiveTimeouts = 0
    private(set) var isStable = false

    mutating func recordResponse() {
        consecutiveTimeouts = 0
        consecutiveResponses += 1
        if consecutiveResponses >= DriverBluetoothLinkPolicy.responsesRequiredForStableTelemetry {
            isStable = true
        }
    }

    /// Returns true only when the authenticated session has been silent long enough to rebuild.
    mutating func recordTimeout() -> Bool {
        consecutiveResponses = 0
        consecutiveTimeouts += 1
        let shouldReconnect = consecutiveTimeouts >= DriverBluetoothLinkPolicy.timeoutsBeforeSessionReconnect
        if shouldReconnect { isStable = false }
        return shouldReconnect
    }

    mutating func reset() {
        self = .init()
    }
}

/// The deliberately small set of fields the read-only BLE module may publish.
struct DriverBluetoothTelemetrySnapshot: Equatable, Sendable {
    let vehicleID: String
    let date: Date
    var speedKmh: Double?
    var powerKw: Double?
    var shiftState: ShiftState?
    var odometerKm: Double?

    func isFresh(at now: Date, maximumAge: TimeInterval = 1.5) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= -1 && age <= maximumAge
    }
}

enum DriverBluetoothError: Error, LocalizedError, Equatable {
    case unavailable
    case bluetoothDisabled
    case permissionDenied
    case unsupportedVehicle
    case vinUnavailable
    case invalidVIN
    case vehicleNotFound
    case connectionLimitReached
    case connectionFailed
    case pairingTimedOut
    case keyRejected
    case protocolViolation
    case disconnected
    case responseTimedOut
    case responseTooLarge
    case sessionOutOfSync
    case temporaryVehicleFault(UInt32)

    var errorDescription: String? {
        switch self {
        case .unavailable: L("Secure Bluetooth is unavailable on this device.")
        case .bluetoothDisabled: L("Turn on Bluetooth to connect to the vehicle.")
        case .permissionDenied: L("Bluetooth permission is disabled in iOS Settings.")
        case .unsupportedVehicle: L("Direct Bluetooth is currently available for Model 3 and Model Y.")
        case .vinUnavailable: L("The VIN could not be obtained from TeslaMate API.")
        case .invalidVIN: L("TeslaMate returned an invalid VIN.")
        case .vehicleNotFound: L("The selected vehicle was not found nearby. Wake and unlock it, keep this iPhone inside the vehicle, and try again.")
        case .connectionLimitReached: L("The vehicle is already using all available Bluetooth connections. Move other phone keys or key fobs away, then try again.")
        case .connectionFailed: L("The secure Bluetooth connection could not be established.")
        case .pairingTimedOut: L("Pairing timed out before the vehicle approved the read-only key.")
        case .keyRejected: L("The vehicle did not accept the read-only key.")
        case .protocolViolation: L("The vehicle returned an invalid secure response.")
        case .disconnected: L("The vehicle disconnected from Bluetooth.")
        case .responseTimedOut: L("The vehicle did not answer in time.")
        case .responseTooLarge: L("The vehicle response is too large for Bluetooth. Tesstats will keep the secure session ready and use iPhone GPS meanwhile.")
        case .sessionOutOfSync: L("The secure Bluetooth session needs to be refreshed.")
        case .temporaryVehicleFault: L("The vehicle is temporarily busy. Tesstats will retry without disconnecting Bluetooth.")
        }
    }
}
