import SwiftUI

// MARK: - Vehicle state (`state` topic)

enum CarState: String, Sendable, CaseIterable, Codable {
    case online, asleep, offline, charging, driving, updating, suspended, start, unknown

    init(raw: String) {
        self = CarState(rawValue: raw.lowercased()) ?? .unknown
    }

    var label: String {
        switch self {
        case .online: L("Online")
        case .asleep: L("Asleep")
        case .offline: L("Offline")
        case .charging: L("Charging status")
        case .driving: L("Driving")
        case .updating: L("Updating")
        case .suspended: L("Suspended")
        case .start: L("Waking")
        case .unknown: L("Unknown")
        }
    }

    var color: Color {
        switch self {
        case .online: Brand.online
        case .charging: Brand.charging
        case .driving: Brand.driving
        case .asleep, .suspended: Brand.asleep
        case .updating, .start: Brand.warning
        case .offline, .unknown: Brand.offline
        }
    }

    var symbol: String {
        switch self {
        case .online: "checkmark.circle.fill"
        case .charging: "bolt.fill"
        case .driving: "steeringwheel"
        case .asleep, .suspended: "moon.zzz.fill"
        case .updating: "arrow.down.circle.fill"
        case .start: "sunrise.fill"
        case .offline, .unknown: "wifi.slash"
        }
    }
}

// MARK: - Charging (`charging_state` topic)

enum ChargingState: String, Sendable, Codable, CaseIterable {
    case charging = "Charging"
    case complete = "Complete"
    case stopped = "Stopped"
    case disconnected = "Disconnected"
    case noPower = "NoPower"
    case starting = "Starting"
    case unknown

    /// Case-insensitive: MQTT publishes `Charging`, TeslaMateApi's `/status` lowercases it.
    init(raw: String) {
        self = Self.allCases.first { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame } ?? .unknown
    }

    var label: String {
        switch self {
        case .charging: L("Charging status")
        case .complete: L("Complete")
        case .stopped: L("Stopped")
        case .disconnected: L("Disconnected")
        case .noPower: L("No power")
        case .starting: L("Starting")
        case .unknown: L("—")
        }
    }
}

// MARK: - Shift state (`shift_state` topic)

enum ShiftState: String, Sendable, Codable {
    case park = "P"
    case reverse = "R"
    case neutral = "N"
    case drive = "D"
    case unknown

    init(raw: String) {
        let v = raw.uppercased()
        self = ShiftState(rawValue: v) ?? .unknown
    }

    var label: String {
        switch self {
        case .park: L("Park")
        case .reverse: L("Reverse")
        case .neutral: L("Neutral")
        case .drive: L("Drive")
        case .unknown: "—"
        }
    }
}

// MARK: - Connection status (UI surface)

enum ConnectionStatus: Equatable, Sendable {
    case notConfigured
    case disconnected
    case connecting
    case connected
    case demo
    /// API-only mode: live values arrive by polling TeslaMateApi, so they lag by up to one interval.
    case polling
    case failed(String)

    var label: String {
        switch self {
        case .notConfigured: L("Not configured")
        case .disconnected: L("Disconnected")
        case .connecting: L("Connecting…")
        case .connected: L("Live")
        case .demo: L("Demo")
        case .polling: L("Live (API)")
        case .failed: L("Connection error")
        }
    }

    var color: Color {
        switch self {
        case .connected, .polling: Brand.online
        case .connecting: Brand.warning
        case .demo: Brand.driving
        case .failed: Brand.danger
        case .notConfigured, .disconnected: Brand.offline
        }
    }

    var isLive: Bool { self == .connected || self == .polling }
}

// MARK: - Preferences

/// Where live vehicle values come from. MQTT pushes every change as it happens; API-only
/// polls TeslaMateApi's `/status` (itself fed by MQTT on the server), so only one URL has to
/// be exposed, at the cost of delayed values.
enum LiveDataSource: String, Codable, Sendable, CaseIterable, Identifiable {
    case mqtt
    case api
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mqtt: L("API + MQTT (recommended)")
        case .api: L("API only")
        }
    }
}

enum MQTTTransport: String, Codable, Sendable, CaseIterable, Identifiable {
    case tls          // mqtts, typically 8883
    case websocket    // wss, behind reverse proxy with optional Basic Auth
    var id: String { rawValue }
    var label: String {
        switch self {
        case .tls: L("MQTT over TLS (mqtts)")
        case .websocket: L("WebSocket Secure (wss)")
        }
    }
}

enum UnitsPreference: String, Codable, Sendable, CaseIterable, Identifiable {
    case metric, imperial
    var id: String { rawValue }
    var label: String {
        switch self {
        case .metric: L("Kilometers")
        case .imperial: L("Miles")
        }
    }
}

enum TempUnit: String, Codable, Sendable, CaseIterable, Identifiable {
    case celsius, fahrenheit
    var id: String { rawValue }
    var label: String {
        switch self {
        case .celsius: "°C"
        case .fahrenheit: "°F"
        }
    }
}

enum RangeKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case rated, estimated, ideal
    var id: String { rawValue }
    var label: String {
        switch self {
        case .rated: L("Rated")
        case .estimated: L("Estimated")
        case .ideal: L("Ideal")
        }
    }
}

// MARK: - Appearance

/// App color theme. Dark is the default; light gives a clean white-background theme.
enum AppAppearance: String, Codable, Sendable, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: L("Automatic")
        case .dark: L("Dark")
        case .light: L("Light")
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}

/// A selectable accent color. The hex (without `#`) is what gets persisted in `ServerConfig`.
struct AccentChoice: Identifiable, Hashable, Sendable {
    let name: String
    let hex: String
    var id: String { hex }
    var color: Color { Color(hex: hex) }
}

enum AccentPalette {
    static let defaultHex = "3E6AE1"
    static var options: [AccentChoice] {
        [
            AccentChoice(name: L("Blue"),    hex: "3E6AE1"),
            AccentChoice(name: L("Bright blue"), hex: "0A84FF"),
            AccentChoice(name: L("Crimson"), hex: "B30333"),
            AccentChoice(name: L("Red"),     hex: "FF453A"),
            AccentChoice(name: L("Orange"),  hex: "FF9F0A"),
            AccentChoice(name: L("Amber"),   hex: "FFC60A"),
            AccentChoice(name: L("Green"),   hex: "30D158"),
            AccentChoice(name: L("Teal"),    hex: "40C8E0"),
            AccentChoice(name: L("Indigo"),  hex: "5E5CE6"),
            AccentChoice(name: L("Purple"),  hex: "BF5AF2"),
            AccentChoice(name: L("Pink"),    hex: "FF375F"),
        ]
    }
}
