import Foundation
import CryptoKit

/// One car's whole cached history, read in a single off-main pass.
struct CachedHistory: Sendable {
    var drives: [DriveRecord] = []
    var charges: [ChargeRecord] = []
    var batteryHealth: BatteryHealthSummary?
    var updates: [SoftwareUpdate] = []

    var isEmpty: Bool { drives.isEmpty && charges.isEmpty }
}

/// Lightweight, crash-proof offline cache. The iPhone is NOT a logger — this only
/// persists the last known live snapshot and most recently downloaded history as JSON
/// files in Application Support, keyed by car_id. Every operation is best-effort and
/// silently degrades if the filesystem is unavailable.
///
/// Deliberately NOT main-actor isolated: encoding or decoding a multi-year history is
/// hundreds of milliseconds of JSON work, and on the main actor that is a visible freeze.
/// Callers on the main actor use the `…Async` variants, which run the work on a background
/// task. Coders are built per call — they cost microseconds next to the (de)coding itself,
/// and keeping none stored is what makes this type `Sendable`.
final class CacheStore: Sendable {
    private let directory: URL?

    init(directory customDirectory: URL? = nil) {
        let fm = FileManager.default
        if let customDirectory {
            try? fm.createDirectory(at: customDirectory, withIntermediateDirectories: true)
            directory = customDirectory
        } else if let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                  appropriateFor: nil, create: true) {
            let dir = base.appendingPathComponent("TesstatsCache", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            directory = dir
        } else {
            directory = nil
        }
    }

    /// Serial IDs are unique only within one TeslaMate database. Keep different sources apart.
    /// Legacy unscoped files cannot be attributed safely and are refreshed from the server.
    func scoped(to config: ServerConfig) -> CacheStore {
        guard let directory else { return self }
        let digest = SHA256.hash(data: Data(config.historySourceIdentity.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return CacheStore(directory: directory.appendingPathComponent(digest, isDirectory: true))
    }

    private func url(_ name: String) -> URL? { directory?.appendingPathComponent(name) }

    private func write<T: Encodable>(_ value: T, to name: String) {
        guard let url = url(name), let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let url = url(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Snapshot

    func saveSnapshot(_ state: VehicleState) { write(state, to: "snapshot-\(state.carID).json") }

    func loadSnapshot(carID: Int) -> VehicleState? { read(VehicleState.self, from: "snapshot-\(carID).json") }

    func loadAllSnapshots() -> [VehicleState] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        let decoder = JSONDecoder()
        return files
            .filter { $0.lastPathComponent.hasPrefix("snapshot-") }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? decoder.decode(VehicleState.self, from: $0) }
    }

    /// Cache warming happens during launch. Reading it synchronously used to make the first
    /// frame wait for every snapshot file to be decoded.
    func loadAllSnapshotsAsync() async -> [VehicleState] {
        await Task.detached(priority: .userInitiated) { [self] in loadAllSnapshots() }.value
    }

    // MARK: Drives

    func saveDrives(_ drives: [DriveRecord], carID: Int) { write(drives, to: "drives-\(carID).json") }
    func loadDrives(carID: Int) -> [DriveRecord] { read([DriveRecord].self, from: "drives-\(carID).json") ?? [] }

    // MARK: Charges

    func saveCharges(_ charges: [ChargeRecord], carID: Int) { write(charges, to: "charges-\(carID).json") }
    func loadCharges(carID: Int) -> [ChargeRecord] { read([ChargeRecord].self, from: "charges-\(carID).json") ?? [] }

    // MARK: Software updates

    func saveUpdates(_ updates: [SoftwareUpdate], carID: Int) { write(updates, to: "updates-\(carID).json") }
    func loadUpdates(carID: Int) -> [SoftwareUpdate] { read([SoftwareUpdate].self, from: "updates-\(carID).json") ?? [] }

    // MARK: Battery health (official snapshot)

    func saveBatteryHealth(_ summary: BatteryHealthSummary, carID: Int) { write(summary, to: "battery-health-\(carID).json") }
    func loadBatteryHealth(carID: Int) -> BatteryHealthSummary? { read(BatteryHealthSummary.self, from: "battery-health-\(carID).json") }

    func loadLatestDrive(carID: Int) async -> DriveRecord? {
        await Task.detached(priority: .utility) { [self] in loadDrives(carID: carID).first }.value
    }

    // MARK: Off-main access

    /// Read everything the history screens need for one car, off the main thread.
    func loadHistoryAsync(carID: Int) async -> CachedHistory {
        await Task.detached(priority: .userInitiated) { [self] in
            CachedHistory(drives: loadDrives(carID: carID),
                          charges: loadCharges(carID: carID),
                          batteryHealth: loadBatteryHealth(carID: carID),
                          updates: loadUpdates(carID: carID))
        }.value
    }

    /// Persist a freshly downloaded history without ever blocking the caller. Fire-and-forget:
    /// a failed or superseded write only means the next launch re-downloads.
    func saveHistoryInBackground(drives: [DriveRecord], charges: [ChargeRecord], carID: Int) {
        Task.detached(priority: .utility) { [self] in
            saveDrives(drives, carID: carID)
            saveCharges(charges, carID: carID)
        }
    }

    func saveBatteryHealthInBackground(_ summary: BatteryHealthSummary, carID: Int) {
        Task.detached(priority: .utility) { [self] in saveBatteryHealth(summary, carID: carID) }
    }

    func saveUpdatesInBackground(_ updates: [SoftwareUpdate], carID: Int) {
        Task.detached(priority: .utility) { [self] in saveUpdates(updates, carID: carID) }
    }

    func saveSnapshotInBackground(_ state: VehicleState) {
        Task.detached(priority: .utility) { [self] in saveSnapshot(state) }
    }

    // MARK: Maintenance

    /// Delete every cached file (snapshots + downloaded history). Best-effort.
    func clearAll() {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    /// Approximate on-disk size of the cache, in bytes.
    func sizeBytes() -> Int {
        guard let directory,
              let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        return files.compactMap { $0 as? URL }.reduce(0) { total, file in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { return total }
            return total + (values.fileSize ?? 0)
        }
    }
}

extension ServerConfig {
    var historySourceIdentity: String {
        if demoMode { return "demo" }
        let fields = [normalizedAPIBaseURL, mqttHost.lowercased(), String(mqttPort), topicNamespace,
                      mqttUsername, usesBasicAuth ? basicAuthUsername : ""]
        return String(decoding: (try? JSONEncoder().encode(fields)) ?? Data(), as: UTF8.self)
    }
}
