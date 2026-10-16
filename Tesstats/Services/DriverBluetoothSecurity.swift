import Foundation
import CryptoKit
import Security

enum DriverBluetoothIdentity {
    static func normalizedVIN(_ value: String) -> String? {
        let vin = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard vin.count == 17,
              vin.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90)
              }),
              !vin.contains("I"), !vin.contains("O"), !vin.contains("Q") else { return nil }
        return vin
    }

    static func identifier(forVIN vin: String) -> String {
        SHA256.hash(data: Data(vin.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func scopeIdentifier(profileID: String?, config: ServerConfig) -> String {
        let source = profileID ?? [config.normalizedAPIBaseURL, config.mqttHost, config.topicRoot]
            .joined(separator: "|")
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct DriverBluetoothPreferencePayload: Codable, Equatable {
    var enabledVehicleIDs: Set<String> = []
    var aliases: [String: String] = [:]
}

/// Only hashes and source aliases are stored in UserDefaults. VINs and key handles are kept in
/// the device-only Keychain by `TeslaBLEKeyStore`.
@MainActor
struct DriverBluetoothPreferencesStore {
    private let defaults: UserDefaults
    private let key = "tesstats.driverBluetooth.preferences.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func isEnabled(vehicleID: String) -> Bool { load().enabledVehicleIDs.contains(vehicleID) }

    func setEnabled(_ enabled: Bool, vehicleID: String) {
        var payload = load()
        if enabled { payload.enabledVehicleIDs.insert(vehicleID) }
        else { payload.enabledVehicleIDs.remove(vehicleID) }
        save(payload)
    }

    func remember(vehicleID: String, carID: Int, scopeID: String) {
        var payload = load()
        payload.aliases[aliasKey(carID: carID, scopeID: scopeID)] = vehicleID
        save(payload)
    }

    func vehicleID(carID: Int, scopeID: String) -> String? {
        load().aliases[aliasKey(carID: carID, scopeID: scopeID)]
    }

    func delete(vehicleID: String) {
        var payload = load()
        payload.enabledVehicleIDs.remove(vehicleID)
        payload.aliases = payload.aliases.filter { $0.value != vehicleID }
        save(payload)
    }

    func deleteAll() { defaults.removeObject(forKey: key) }

    private func aliasKey(carID: Int, scopeID: String) -> String { "\(scopeID):\(carID)" }

    private func load() -> DriverBluetoothPreferencePayload {
        guard let data = defaults.data(forKey: key),
              let payload = try? JSONDecoder().decode(DriverBluetoothPreferencePayload.self, from: data) else {
            return DriverBluetoothPreferencePayload()
        }
        return payload
    }

    private func save(_ payload: DriverBluetoothPreferencePayload) {
        if let data = try? JSONEncoder().encode(payload) { defaults.set(data, forKey: key) }
    }
}

#if os(iOS)
import LocalAuthentication

struct TeslaBLEStoredKey: Sendable {
    let vehicleID: String
    let vin: String
    let publicKey: Data
    let createdAt: Date
    fileprivate let privateKey: SecureEnclave.P256.KeyAgreement.PrivateKey

    func sharedSecret(with remotePublicKey: Data) throws -> Data {
        let remote = try P256.KeyAgreement.PublicKey(x963Representation: remotePublicKey)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: remote)
        return secret.withUnsafeBytes { Data($0) }
    }
}

private struct TeslaBLEStoredKeyPayload: Codable {
    let vin: String
    let publicKey: Data
    let secureEnclaveRepresentation: Data
    let createdAt: Date
}

struct TeslaBLEKeyStore: Sendable {
    private let service: String

    init(service: String = (Bundle.main.bundleIdentifier ?? "com.tesstats.app") + ".vehicle-monitor") {
        self.service = service
    }

    var isHardwareProtectionAvailable: Bool { SecureEnclave.isAvailable }

    func createProvisional(vin: String) throws -> TeslaBLEStoredKey {
        guard SecureEnclave.isAvailable else { throw DriverBluetoothError.unavailable }
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage],
            &accessError
        ) else {
            if let error = accessError?.takeRetainedValue() { throw error }
            throw DriverBluetoothError.unavailable
        }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(
            compactRepresentable: false,
            accessControl: access,
            authenticationContext: nil
        )
        let vehicleID = DriverBluetoothIdentity.identifier(forVIN: vin)
        return TeslaBLEStoredKey(vehicleID: vehicleID,
                                 vin: vin,
                                 publicKey: key.publicKey.x963Representation,
                                 createdAt: Date(),
                                 privateKey: key)
    }

    func save(_ key: TeslaBLEStoredKey) throws {
        let payload = TeslaBLEStoredKeyPayload(vin: key.vin,
                                               publicKey: key.publicKey,
                                               secureEnclaveRepresentation: key.privateKey.dataRepresentation,
                                               createdAt: key.createdAt)
        let data = try JSONEncoder().encode(payload)
        delete(vehicleID: key.vehicleID)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(key.vehicleID),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    func load(vehicleID: String) -> TeslaBLEStoredKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(vehicleID),
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let payload = try? JSONDecoder().decode(TeslaBLEStoredKeyPayload.self, from: data),
              let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey(
                  dataRepresentation: payload.secureEnclaveRepresentation,
                  authenticationContext: nil
              ) else { return nil }
        return TeslaBLEStoredKey(vehicleID: vehicleID,
                                 vin: payload.vin,
                                 publicKey: payload.publicKey,
                                 createdAt: payload.createdAt,
                                 privateKey: key)
    }

    func delete(vehicleID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(vehicleID),
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(query as CFDictionary)
    }

    func deleteAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func account(_ vehicleID: String) -> String { "vehicle.\(vehicleID)" }
}
#endif
