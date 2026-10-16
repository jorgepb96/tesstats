import Foundation
import CryptoKit

/// Local, device-only label for a drive (e.g. to separate business mileage for expenses).
/// Read-only towards TeslaMate: tags never leave the device except inside user exports.
enum TripTag: String, Codable, CaseIterable, Identifiable, Sendable {
    case work, personal

    var id: String { rawValue }
    var label: String {
        switch self {
        case .work: L("Work")
        case .personal: L("Personal")
        }
    }
    var icon: String {
        switch self {
        case .work: "briefcase.fill"
        case .personal: "person.fill"
        }
    }
}

/// Persists the drive-ID → tag map as JSON in UserDefaults. Drive IDs are TeslaMate's
/// own serial IDs, so they are stable across re-downloads and unique per install.
@MainActor
@Observable
final class TripTagStore {
    private(set) var tags: [Int: TripTag] = [:]
    /// Bumped on every tag change so views can cache tag-dependent work.
    private(set) var revision = 0

    private let defaults: UserDefaults
    private var key: String
    private let rootKey: String
    private var sourceIdentity: String?

    init(defaults: UserDefaults = .standard, key: String = "tesstats.triptags") {
        self.defaults = defaults
        self.key = key
        self.rootKey = key
        if let data = defaults.data(forKey: key),
           let raw = try? JSONDecoder().decode([String: TripTag].self, from: data) {
            tags = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })
        }
    }

    func tag(for driveID: Int) -> TripTag? { tags[driveID] }

    /// Different TeslaMate databases can reuse drive IDs. Migrate legacy tags once to the
    /// currently configured source, then keep each source's labels independently.
    func scope(to identity: String) {
        guard sourceIdentity != identity else { return }
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let scopedKey = "\(rootKey).\(digest)"
        let stored = defaults.data(forKey: scopedKey).flatMap {
            try? JSONDecoder().decode([String: TripTag].self, from: $0)
        }
        let migrate = sourceIdentity == nil && !defaults.bool(forKey: "\(rootKey).scopeMigration")
        if let stored {
            tags = Dictionary(uniqueKeysWithValues: stored.compactMap { k, v in Int(k).map { ($0, v) } })
        } else if !migrate {
            tags = [:]
        }
        key = scopedKey
        sourceIdentity = identity
        if migrate { defaults.set(true, forKey: "\(rootKey).scopeMigration") }
        persist()
    }

    /// Assign or clear (nil) the tag for a drive.
    func setTag(_ tag: TripTag?, for driveID: Int) {
        if let tag {
            tags[driveID] = tag
        } else {
            tags.removeValue(forKey: driveID)
        }
        persist()
    }

    func clear() {
        tags = [:]
        for storedKey in defaults.dictionaryRepresentation().keys
            where storedKey == rootKey || storedKey.hasPrefix(rootKey + ".") {
            defaults.removeObject(forKey: storedKey)
        }
        revision += 1
    }

    private func persist() {
        revision += 1
        let raw = Dictionary(uniqueKeysWithValues: tags.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: key)
        }
    }
}
