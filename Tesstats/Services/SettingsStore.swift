import Foundation

/// Single source of truth for connection configuration + preferences. Non-secret values
/// persist as JSON in UserDefaults; passwords live only in the Keychain.
@MainActor
@Observable
final class SettingsStore {
    var config: ServerConfig
    /// Saved, switchable connection profiles (e.g. two TeslaMate installs).
    var profiles: [ServerProfile] = []
    var activeProfileID: String?

    let defaults: UserDefaults
    let keychain: KeychainStore
    private let configKey = "tesstats.serverconfig"
    private let profilesKey = "tesstats.profiles"
    private let activeProfileKey = "tesstats.activeProfile"

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
        if let data = defaults.data(forKey: configKey),
           let loaded = try? JSONDecoder().decode(ServerConfig.self, from: data) {
            self.config = loaded
        } else {
            self.config = ServerConfig()
        }
        if let data = defaults.data(forKey: profilesKey),
           let loaded = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            self.profiles = loaded
        }
        self.activeProfileID = defaults.string(forKey: activeProfileKey)
    }

    func save() {
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: configKey)
        }
    }

    var isConfigured: Bool {
        config.demoMode || config.hasMQTTConfigured || config.hasAPIConfigured
    }

    // MARK: Secrets (Keychain-backed)

    var mqttPassword: String {
        get { keychain.get(.mqttPassword) ?? "" }
        set { keychain.set(newValue, for: .mqttPassword) }
    }

    var basicAuthPassword: String {
        get { keychain.get(.basicAuthPassword) ?? "" }
        set { keychain.set(newValue, for: .basicAuthPassword) }
    }

    var pushSecret: String {
        get { keychain.get(.pushSecret) ?? "" }
        set { keychain.set(newValue, for: .pushSecret) }
    }

    // MARK: Builders for services

    var trustConfig: TrustConfig {
        TrustConfig(allowSelfSigned: config.trustCustomCertificate,
                    pinnedPublicKeySHA256: config.pinnedPublicKeySHA256.isEmpty ? nil : config.pinnedPublicKeySHA256)
    }

    var basicAuth: BasicAuth? {
        guard config.usesBasicAuth, !config.basicAuthUsername.isEmpty else { return nil }
        return BasicAuth(user: config.basicAuthUsername, pass: basicAuthPassword)
    }

    /// Accept a bare hostname even if the user pasted a scheme or path
    /// (e.g. "https://host/" or "wss://host:443/mqtt" → "host"). The MQTT host is a
    /// hostname, not a URL — a scheme there causes a DNS "NoSuchRecord" failure.
    static func hostOnly(_ raw: String) -> String {
        var h = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        // Strip an embedded :port (the port comes from the dedicated field).
        if let colon = h.lastIndex(of: ":"), !h.contains("]") { h = String(h[..<colon]) }
        return h
    }

    func makeMQTTConfig() -> MQTTClient.Config {
        MQTTClient.Config(
            host: Self.hostOnly(config.mqttHost),
            port: config.mqttPort,
            transport: config.mqttTransport,
            websocketPath: config.mqttWebsocketPath,
            username: config.mqttUsername.isEmpty ? nil : config.mqttUsername,
            password: mqttPassword.isEmpty ? nil : mqttPassword,
            // Unique per connection: MQTT brokers disconnect an existing client when a new
            // one connects with the same client-ID. A random suffix prevents that collision
            // (and avoids the "Test connection" client fighting the live one).
            clientID: (config.mqttClientID.isEmpty ? "tesstats-ios" : config.mqttClientID)
                + "-" + String(format: "%06x", UInt32.random(in: 0...0xFFFFFF)),
            basicAuth: config.mqttTransport == .websocket ? basicAuth : nil,
            trust: trustConfig,
            keepAlive: 30)
    }

    func makeAPIConfig() -> HistoryAPIService.Config {
        HistoryAPIService.Config(
            baseURL: config.normalizedAPIBaseURL,
            basicAuth: basicAuth,
            trust: trustConfig,
            allowInsecure: config.allowInsecureTransport)
    }

    /// Wipe ALL persisted configuration: settings, every Keychain secret, and saved profiles.
    func eraseAll() {
        keychain.deleteAll()
        config = ServerConfig()
        profiles = []
        activeProfileID = nil
        defaults.removeObject(forKey: configKey)
        defaults.removeObject(forKey: profilesKey)
        defaults.removeObject(forKey: activeProfileKey)
    }
}
