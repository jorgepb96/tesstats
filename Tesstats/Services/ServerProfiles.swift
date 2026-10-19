import Foundation

/// A named, switchable connection profile (e.g. "Home TeslaMate" vs "Garage server").
/// Holds only non-secret configuration; each profile's passwords live in the Keychain under
/// per-profile accounts (`<account>.<id>`).
struct ServerProfile: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var config: ServerConfig
}

@MainActor
extension SettingsStore {

    // MARK: - Profiles

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: "tesstats.profiles")
        }
        defaults.set(activeProfileID, forKey: "tesstats.activeProfile")
    }

    private func secretAccounts(_ id: String) -> (mqtt: String, basic: String, cloudflare: String, push: String) {
        ("mqtt.password.\(id)", "basicauth.password.\(id)", "cloudflare.clientsecret.\(id)", "push.secret.\(id)")
    }

    /// Copy the live global secrets into a profile's per-profile Keychain slots.
    private func stashSecrets(into id: String) {
        let acc = secretAccounts(id)
        keychain.setRaw(mqttPassword, account: acc.mqtt)
        keychain.setRaw(basicAuthPassword, account: acc.basic)
        keychain.setRaw(cloudflareAccessClientSecret, account: acc.cloudflare)
        keychain.setRaw(pushSecret, account: acc.push)
    }

    /// Load a profile's per-profile secrets into the live global slots.
    private func restoreSecrets(from id: String) {
        let acc = secretAccounts(id)
        mqttPassword = keychain.getRaw(account: acc.mqtt) ?? ""
        basicAuthPassword = keychain.getRaw(account: acc.basic) ?? ""
        cloudflareAccessClientSecret = keychain.getRaw(account: acc.cloudflare) ?? ""
        pushSecret = keychain.getRaw(account: acc.push) ?? ""
    }

    /// Save the current configuration as a new named profile (and make it active).
    func saveCurrentAsProfile(name: String) {
        let id = UUID().uuidString
        var c = config
        c.demoMode = false
        profiles.append(ServerProfile(id: id, name: name, config: c))
        stashSecrets(into: id)
        activeProfileID = id
        persistProfiles()
    }

    /// Persist edits made to the currently-active profile.
    func updateActiveProfile() {
        guard let id = activeProfileID, let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx].config = config
        stashSecrets(into: id)
        persistProfiles()
    }

    /// Switch to another profile: stash current edits, load the target's config + secrets.
    func switchToProfile(_ id: String) {
        guard let target = profiles.first(where: { $0.id == id }) else { return }
        if let current = activeProfileID, profiles.contains(where: { $0.id == current }) {
            updateActiveProfile()                 // don't lose unsaved edits to the old one
        }
        config = target.config
        restoreSecrets(from: id)
        activeProfileID = id
        save()
        persistProfiles()
    }

    func deleteProfile(_ id: String) {
        let acc = secretAccounts(id)
        keychain.setRaw(nil, account: acc.mqtt)
        keychain.setRaw(nil, account: acc.basic)
        keychain.setRaw(nil, account: acc.cloudflare)
        keychain.setRaw(nil, account: acc.push)
        profiles.removeAll { $0.id == id }
        if activeProfileID == id { activeProfileID = nil }
        persistProfiles()
    }

    func renameProfile(_ id: String, to name: String) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx].name = name
        persistProfiles()
    }

    // MARK: - Backup / restore (includes secrets)

    func makeBackup() -> ConfigBackup {
        ConfigBackup(config: config,
                     mqttPassword: mqttPassword.isEmpty ? nil : mqttPassword,
                     basicAuthPassword: basicAuthPassword.isEmpty ? nil : basicAuthPassword,
                     cloudflareAccessClientSecret: cloudflareAccessClientSecret.isEmpty ? nil : cloudflareAccessClientSecret,
                     pushSecret: pushSecret.isEmpty ? nil : pushSecret)
    }

    /// Apply a restored backup to the live configuration (caller reconnects afterwards).
    func restore(_ backup: ConfigBackup) {
        config = backup.config
        config.demoMode = false
        mqttPassword = backup.mqttPassword ?? ""
        basicAuthPassword = backup.basicAuthPassword ?? ""
        cloudflareAccessClientSecret = backup.cloudflareAccessClientSecret ?? ""
        pushSecret = backup.pushSecret ?? ""
        save()
    }
}
