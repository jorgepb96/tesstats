import Foundation

/// Everything the history screens read, derived in one off-main pass and published in one
/// assignment. Deriving these piecemeal on the main actor is what used to stall the UI on a
/// multi-year history.
struct HistoryPayload: Sendable {
    var drives: [DriveRecord] = []
    var charges: [ChargeRecord] = []
    var battery: [BatteryHealthPoint] = []
    var batteryHealthSummary: BatteryHealthSummary?
    var updates: [SoftwareUpdate] = []
    var aggregates: ChargeAggregates = .init()
    var efficiency: EfficiencySummary = .init()

    var isEmpty: Bool { drives.isEmpty && charges.isEmpty }

    /// Build the derived figures from raw records. `nonisolated` and `Sendable` on purpose —
    /// callers run it inside `Task.detached`.
    static func derive(drives: [DriveRecord],
                       charges: [ChargeRecord],
                       batteryHealthSummary: BatteryHealthSummary?,
                       updates: [SoftwareUpdate],
                       efficiencyKwhPerKm: Double?) -> HistoryPayload {
        HistoryPayload(drives: drives,
                       charges: charges,
                       battery: HistoryViewModel.deriveBattery(charges: charges, drives: drives,
                                                              efficiency: efficiencyKwhPerKm),
                       batteryHealthSummary: batteryHealthSummary,
                       updates: updates,
                       aggregates: ChargeAggregates.from(charges),
                       efficiency: EfficiencySummary.from(drives))
    }
}

@MainActor
@Observable
final class HistoryViewModel {
    enum Phase: Equatable {
        case idle, loading, loaded, empty(String), failed(String)
    }

    private(set) var drives: [DriveRecord] = []
    private(set) var charges: [ChargeRecord] = []
    private(set) var battery: [BatteryHealthPoint] = []
    /// Official battery-health snapshot from TeslaMateApi (preferred over the derived curve).
    private(set) var batteryHealthSummary: BatteryHealthSummary?
    /// Firmware update history (newest first).
    private(set) var updates: [SoftwareUpdate] = []
    private(set) var carInfo: CarInfo?
    private(set) var phase: Phase = .idle
    private(set) var usingCache = false
    /// True while a load runs in the background. `phase` stays `.loaded` whenever there is
    /// anything to show, so screens keep their content interactive and only add a badge.
    private(set) var isRefreshing = false
    /// Bumped whenever the record sets change. Views key their cached aggregations off this
    /// so a redraw never re-derives analytics that did not change.
    private(set) var revision = 0

    /// Whole-history aggregates. Stored, not computed: they were being recomputed on every
    /// body pass (a full scan of every charge/drive) just to build a `.task` id.
    private(set) var chargeAggregates: ChargeAggregates = .init()
    private(set) var efficiency: EfficiencySummary = .init()

    private let settings: SettingsStore
    private let cache: CacheStore
    private var loadedCarID: Int?
    var onChargesLoaded: (([ChargeRecord], Int) -> Void)?
    /// Guards against two screens' `.task` blocks starting the same load at once.
    private var inFlight: Task<Void, Never>?
    private var inFlightCarID: Int?
    /// Identifies the load that owns `inFlight` (`Task` is a value type, so it cannot be
    /// compared by identity).
    private var loadGeneration = 0

    init(settings: SettingsStore, cache: CacheStore) {
        self.settings = settings
        self.cache = cache
    }

    var hasData: Bool { !drives.isEmpty || !charges.isEmpty }

    func loadIfNeeded(carID: Int) async {
        // Reload on first use, on car change, and after a failure — otherwise switching
        // tabs after a failed load would keep showing the error until a manual retry.
        let shouldRetry: Bool = if case .failed = phase { true } else { false }
        guard loadedCarID != carID || phase == .idle || shouldRetry else { return }
        await load(carID: carID, incremental: true)
    }

    /// Drop all in-memory history so the next view re-fetches (used after clearing data/cache).
    func reset() {
        inFlight?.cancel()
        inFlight = nil
        inFlightCarID = nil
        loadGeneration &+= 1
        apply(HistoryPayload(), usingCache: false)
        carInfo = nil
        loadedCarID = nil
        isRefreshing = false
        phase = .idle
    }

    /// Explicit user refresh (pull-to-refresh / toolbar): full re-download, so late edits to
    /// old records in TeslaMate (e.g. a corrected charge cost) are picked up.
    func refresh(carID: Int) async { await load(carID: carID, incremental: false) }
    func syncRecent(carID: Int) async { await load(carID: carID, incremental: true) }

    /// Publish a whole derived payload in one assignment — one observation notification, one
    /// redraw, instead of eight.
    private func apply(_ payload: HistoryPayload, usingCache: Bool) {
        drives = payload.drives
        charges = payload.charges
        battery = payload.battery
        batteryHealthSummary = payload.batteryHealthSummary
        updates = payload.updates
        chargeAggregates = payload.aggregates
        efficiency = payload.efficiency
        self.usingCache = usingCache
        revision += 1
        if let carID = loadedCarID, let health = payload.batteryHealthSummary {
            WidgetBridge.updateBatteryHealth(health, carID: carID)
        }
    }

    /// `incremental` reuses the cached history and only downloads pages until they overlap
    /// it — automatic loads stay fast on multi-year histories.
    ///
    /// Nothing here blocks the main actor: the cache is read and the analytics are derived on
    /// background tasks, and cached content is published *before* the network call so the
    /// screens have something to show (and stay scrollable) while the download runs.
    private func load(carID: Int, incremental: Bool = false) async {
        // Five screens each own a `.task(id: carID)`. Automatic loads join whatever is already
        // running instead of starting a second download; an explicit refresh waits its turn
        // and then re-downloads for real.
        if let existing = inFlight {
            if inFlightCarID == carID {
                let waitingGeneration = loadGeneration
                await existing.value
                guard loadGeneration == waitingGeneration else { return }
                if incremental { return }
            } else {
                existing.cancel()
            }
        }
        if loadedCarID != carID {
            apply(HistoryPayload(), usingCache: false)
            carInfo = nil
            phase = .idle
        }
        loadGeneration &+= 1
        let generation = loadGeneration
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            guard !Task.isCancelled, self?.loadGeneration == generation else { return }
            await self?.performLoad(carID: carID, incremental: incremental, generation: generation)
        }
        inFlight = task
        inFlightCarID = carID
        await task.value
        if loadGeneration == generation { inFlight = nil; inFlightCarID = nil }
    }

    private func performLoad(carID: Int, incremental: Bool, generation: Int) async {
        loadedCarID = carID
        isRefreshing = true
        defer { if loadGeneration == generation { isRefreshing = false } }

        if settings.config.demoMode {
            let payload = await Task.detached(priority: .userInitiated) {
                var payload = HistoryPayload.derive(drives: DemoDataProvider.drives(),
                                                    charges: DemoDataProvider.charges(),
                                                    batteryHealthSummary: DemoDataProvider.batteryHealthSummary,
                                                    updates: DemoDataProvider.updates(),
                                                    efficiencyKwhPerKm: DemoDataProvider.carInfo.efficiencyKwhPerKm)
                // The demo ships its own hand-built degradation curve; keep it over the derived one.
                payload.battery = DemoDataProvider.batteryHealth()
                return payload
            }.value
            guard !Task.isCancelled else { return }
            carInfo = DemoDataProvider.carInfo
            apply(payload, usingCache: false)
            phase = .loaded
            return
        }

        // Read the cache off the main thread. Publishing it first is what makes the load
        // non-blocking: the screens render real content immediately, then quietly update.
        let sourceCache = cache.scoped(to: settings.config)
        let cached = await sourceCache.loadHistoryAsync(carID: carID)
        guard !Task.isCancelled else { return }
        let api = makeAPI()

        if !hasData, !cached.isEmpty {
            let ratedEfficiency = carInfo?.efficiencyKwhPerKm
            let payload = await Task.detached(priority: .userInitiated) {
                HistoryPayload.derive(drives: cached.drives, charges: cached.charges,
                                      batteryHealthSummary: cached.batteryHealth,
                                      updates: cached.updates,
                                      efficiencyKwhPerKm: ratedEfficiency)
            }.value
            guard !Task.isCancelled else { return }
            apply(payload, usingCache: true)
            phase = .loaded
        }

        guard let api else {
            // No history API configured — the cache above is all there is.
            if !hasData {
                phase = .empty(L("Add a TeslaMateApi URL in Settings to see drives, charges and battery history."))
            }
            return
        }

        if !hasData { phase = .loading }

        do {
            let cachedDrives = incremental ? cached.drives : []
            let cachedCharges = incremental ? cached.charges : []
            async let d = api.fetchDrives(carID: carID, mergingWith: cachedDrives)
            async let c = api.fetchCharges(carID: carID, mergingWith: cachedCharges)
            let (dd, cc) = try await (d, c)
            let fetchedInfo = (try? await api.fetchCarInfo(carID: carID)) ?? nil
            guard !Task.isCancelled else { return }
            if let fetchedInfo { carInfo = fetchedInfo }

            // Best-effort extras — older/minimal TeslaMateApi deployments may not expose these,
            // so a failure must not break the core history load. Keep the last cached value.
            let health = (try? await api.fetchBatteryHealth(carID: carID)) ?? nil
            guard !Task.isCancelled else { return }
            if let health { sourceCache.saveBatteryHealthInBackground(health, carID: carID) }
            let fetchedUpdates = (try? await api.fetchUpdates(carID: carID)) ?? []
            guard !Task.isCancelled else { return }
            if !fetchedUpdates.isEmpty { sourceCache.saveUpdatesInBackground(fetchedUpdates, carID: carID) }

            sourceCache.saveHistoryInBackground(drives: dd, charges: cc, carID: carID)

            let efficiencyKwhPerKm = carInfo?.efficiencyKwhPerKm
            let payload = await Task.detached(priority: .userInitiated) {
                HistoryPayload.derive(drives: dd, charges: cc,
                                      batteryHealthSummary: health ?? cached.batteryHealth,
                                      updates: fetchedUpdates.isEmpty ? cached.updates : fetchedUpdates,
                                      efficiencyKwhPerKm: efficiencyKwhPerKm)
            }.value
            guard !Task.isCancelled else { return }
            apply(payload, usingCache: false)
            phase = payload.isEmpty ? .empty(L("No history returned yet.")) : .loaded
            onChargesLoaded?(payload.charges, carID)
        } catch {
            guard !Task.isCancelled else { return }
            // The cached content published above stays on screen; only a cold failure is fatal.
            if hasData {
                usingCache = true
                phase = .loaded
            } else {
                phase = .failed((error as? APIError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// Fetch the real GPS trace of a drive so the detail map can draw the actual route
    /// instead of geocoding the ambiguous address text. Returns nil in demo mode (the demo
    /// drives already carry their own path) or when no API is configured.
    func driveTrace(carID: Int, driveID: Int) async -> DriveTrace? {
        if settings.config.demoMode { return nil }
        guard let api = makeAPI() else { return nil }
        return try? await api.fetchDriveDetails(carID: carID, driveID: driveID)
    }

    private func makeAPI() -> HistoryAPIService? {
        let cfg = settings.makeAPIConfig()
        guard !cfg.baseURL.isEmpty else { return nil }
        return HistoryAPIService(config: cfg)
    }

    /// Build the battery degradation curve. Charges are the best signal: each charge gives a
    /// rated range that projects to a max range at 100%, and the energy added across a SoC
    /// delta gives a measured usable capacity (kWh). Falls back to drives when no charges.
    nonisolated static func deriveBattery(charges: [ChargeRecord], drives: [DriveRecord], efficiency: Double?) -> [BatteryHealthPoint] {
        let cal = Calendar.current
        var buckets: [Date: (range: Double, cap: Double?)] = [:]

        for c in charges.sorted(by: { $0.startDate < $1.startDate }) {
            guard let endB = c.endBattery, (50...100).contains(endB), let endR = c.endRangeKm,
                  endR.isFinite, endR > 0 else { continue }
            let maxRange = endR / (Double(endB) / 100.0)
            var cap: Double?
            if let startB = c.startBattery, (0...100).contains(startB), endB - startB >= 20,
               c.energyAddedKwh.isFinite, c.energyAddedKwh > 0 {
                cap = c.energyAddedKwh / (Double(endB - startB) / 100.0)   // measured kWh
            } else if let eff = efficiency, eff > 0 {
                cap = maxRange * eff
            }
            guard let month = cal.date(from: cal.dateComponents([.year, .month], from: c.startDate)) else { continue }
            if let existing = buckets[month] {
                buckets[month] = (max(existing.range, maxRange),
                                  maxRange >= existing.range ? cap ?? existing.cap : existing.cap ?? cap)
            } else {
                buckets[month] = (maxRange, cap)
            }
        }

        if buckets.isEmpty {
            for d in drives.sorted(by: { $0.startDate < $1.startDate }) {
                guard let level = d.startBattery, (21...100).contains(level), let range = d.startRangeKm,
                      range.isFinite, range > 0 else { continue }
                let full = range / (Double(level) / 100.0)
                guard let month = cal.date(from: cal.dateComponents([.year, .month], from: d.startDate)) else { continue }
                let cap = efficiency.flatMap { $0.isFinite && $0 > 0 ? full * $0 : nil }
                if let existing = buckets[month] {
                    buckets[month] = (max(existing.range, full),
                                      full >= existing.range ? cap ?? existing.cap : existing.cap ?? cap)
                } else {
                    buckets[month] = (full, cap)
                }
            }
        }

        return buckets
            .map { BatteryHealthPoint(date: $0.key, odometerKm: 0, maxRangeKm: $0.value.range, usableCapacityKwh: $0.value.cap) }
            .sorted { $0.date < $1.date }
    }
}
