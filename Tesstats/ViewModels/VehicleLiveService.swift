import Foundation

/// Orchestrates the live data path: chooses Demo, real MQTT or TeslaMateApi polling, applies
/// updates to the observable state map, drives notifications on transitions, caches snapshots
/// offline, and reconnects with backoff. All observable mutation stays on the MainActor.
@MainActor
@Observable
final class VehicleLiveService {
    private(set) var states: [Int: VehicleState] = [:]
    private(set) var cars: [CarSummary] = []
    private(set) var status: ConnectionStatus = .notConfigured
    private(set) var lastError: String?
    private let emptyMotion = MotionEstimator()
    private var motionByCar: [Int: MotionEstimator] = [:]
    private var powerSampleDates: [Int: Date] = [:]
    private var speedSampleDates: [Int: Date] = [:]
    var motion: MotionEstimator { resolvedCarID.flatMap { motionByCar[$0] } ?? emptyMotion }
    let driverTrip = DriverTripDistanceEstimator()
    let driverConsumption = DriverTripConsumptionStore()

    private let settings: SettingsStore
    private let notifications: NotificationEngine
    private let cache: CacheStore

    private var client: MQTTClient?
    private var consumeTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var warmupTask: Task<Void, Never>?
    private var intentionalStop = false
    private var reconnectAttempt = 0
    private var connectionEpoch = 0          // invalidates stale connections/tasks
    private var lastCacheSave: [Int: Date] = [:]
    private var cacheSourceIdentity: String?

    init(settings: SettingsStore, notifications: NotificationEngine, cache: CacheStore) {
        self.settings = settings
        self.notifications = notifications
        self.cache = cache
    }

    // MARK: - Resolved selection

    var resolvedCarID: Int? {
        if let id = settings.config.selectedCarID, states[id] != nil || cars.contains(where: { $0.id == id }) {
            return id
        }
        return cars.first?.id ?? states.keys.sorted().first
    }

    var currentState: VehicleState? { resolvedCarID.flatMap { states[$0] } }
    var currentTripDistanceKm: Double? { driverTrip.distance(for: resolvedCarID) }

    func selectCar(_ id: Int) {
        settings.config.selectedCarID = id
        settings.save()
    }

    // MARK: - Lifecycle

    func start() {
        teardownConnection()
        intentionalStop = false
        lastError = nil

        // Warm the UI from cache — off the main thread, so a cold launch never waits on disk.
        warmupTask?.cancel()
        let identity = settings.config.historySourceIdentity
        if cacheSourceIdentity != identity {
            states.removeAll()
            cars.removeAll()
            driverTrip.reset()
            driverConsumption.reset()
            motionByCar.removeAll()
            powerSampleDates.removeAll()
            speedSampleDates.removeAll()
            lastCacheSave.removeAll()
            cacheSourceIdentity = identity
        }
        let cache = cache.scoped(to: settings.config)
        warmupTask = Task { @MainActor [weak self] in
            let snapshots = await Task.detached(priority: .userInitiated) { cache.loadAllSnapshots() }.value
            guard let self, !Task.isCancelled else { return }
            for snapshot in snapshots where self.states[snapshot.carID] == nil {
                self.states[snapshot.carID] = snapshot
                self.upsertCar(from: snapshot)
            }
        }

        let config = settings.config
        if config.demoMode {
            startDemo()
        } else if config.usesAPIPolling, config.hasAPIConfigured {
            startPolling()
        } else if !config.usesAPIPolling, config.hasMQTTConfigured {
            startLive()
        } else {
            status = .notConfigured
        }
    }

    func stop() {
        intentionalStop = true
        teardownConnection()
        if status != .notConfigured { status = .disconnected }
    }

    func restart() {
        stop()
        start()
    }

    /// Called when the Watch companion becomes active. It immediately re-sends the assembled
    /// state and reconnects a stale/suspended MQTT session (or polls the API again) so the
    /// Watch repopulates without requiring the iPhone UI to be opened first.
    func refreshForWatch() {
        guard settings.isConfigured else { return }
        if let current = currentState {
            WidgetBridge.update(state: current,
                                carName: name(for: current.carID, hint: current.displayName),
                                config: settings.config,
                                cache: cache,
                                force: true)
        }
        guard !settings.config.demoMode, settings.config.hasLiveSourceConfigured else { return }
        let age = currentState.map { Date().timeIntervalSince($0.lastUpdated) } ?? .infinity
        if !status.isLive || age > 15 {
            restart()
        }
    }

    private func teardownConnection() {
        connectionEpoch &+= 1   // invalidate any in-flight consume/reconnect tasks
        consumeTask?.cancel(); consumeTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        warmupTask?.cancel(); warmupTask = nil
        let c = client
        client = nil
        emptyMotion.reset()
        for estimator in motionByCar.values { estimator.reset() }
        if let c { Task { await c.disconnect() } }
    }

    // MARK: - Demo

    private func startDemo() {
        status = .demo
        if cars.isEmpty { cars = [DemoDataProvider.car] }
        if settings.config.selectedCarID == nil { settings.config.selectedCarID = DemoDataProvider.car.id }
        let provider = DemoDataProvider(scenario: .launchValue)
        consumeTask = Task { @MainActor [weak self] in
            for await snapshot in provider.liveStream() {
                guard let self, !self.intentionalStop else { break }
                self.commitFull(snapshot)
            }
        }
    }

    // MARK: - Live MQTT

    private func startLive() {
        // Invalidate and tear down any previous connection so only ONE is ever live.
        connectionEpoch &+= 1
        let epoch = connectionEpoch
        consumeTask?.cancel(); consumeTask = nil
        if let old = client { client = nil; Task { await old.disconnect() } }

        status = .connecting
        let mqttConfig = settings.makeMQTTConfig()
        let topicRoot = settings.config.topicRoot
        let client = MQTTClient(config: mqttConfig)
        self.client = client

        consumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await client.connect(topics: ["\(topicRoot)/+/#"])
                guard epoch == self.connectionEpoch else { await client.disconnect(); return }
                self.status = .connected
                self.reconnectAttempt = 0
                for await msg in client.publishes {
                    if self.intentionalStop || epoch != self.connectionEpoch { break }
                    self.handle(topic: msg.topic, payload: msg.payload, topicRoot: topicRoot)
                }
                self.handleDisconnect(epoch: epoch)
            } catch {
                if epoch == self.connectionEpoch {
                    self.lastError = error.localizedDescription
                    self.status = .failed(error.localizedDescription)
                }
                self.handleDisconnect(epoch: epoch)
            }
        }
    }

    // MARK: - API polling (no MQTT)

    /// Live values without MQTT: poll TeslaMateApi's `/status` for every car. The values lag
    /// by up to one interval, so this is the simple setup, not the recommended one.
    private func startPolling() {
        connectionEpoch &+= 1
        let epoch = connectionEpoch
        consumeTask?.cancel(); consumeTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        if let old = client { client = nil; Task { await old.disconnect() } }

        status = .connecting
        let api = HistoryAPIService(config: settings.makeAPIConfig())
        let interval = Double(settings.config.effectiveAPIPollingSeconds)
        consumeTask = Task { @MainActor [weak self] in
            var failures = 0
            var carIDs: [Int] = []
            while !Task.isCancelled {
                switch await self?.pollOnce(api: api, carIDs: carIDs, epoch: epoch) ?? .stop {
                case .stop: return
                case .failed: failures += 1
                case .polled(let ids): carIDs = ids; failures = 0
                }
                // Back off on errors (2×, 4×… the interval, at most 2 minutes).
                let delay = failures == 0 ? interval : min(120, interval * pow(2, Double(min(failures, 4))))
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }

    private enum PollOutcome { case stop, failed, polled([Int]) }

    /// One polling round over `carIDs` (discovered first when empty). `.stop` means this
    /// polling loop was superseded or stopped.
    private func pollOnce(api: HistoryAPIService, carIDs: [Int], epoch: Int) async -> PollOutcome {
        guard epoch == connectionEpoch, !intentionalStop else { return .stop }
        do {
            var ids = carIDs
            if ids.isEmpty {
                let found = try await api.fetchCars()
                guard epoch == connectionEpoch, !intentionalStop else { return .stop }
                for car in found {
                    if let idx = cars.firstIndex(where: { $0.id == car.id }) {
                        cars[idx].displayName = car.displayName
                        if let model = car.model { cars[idx].model = model }
                    } else {
                        cars.append(car)
                    }
                }
                cars.sort { $0.id < $1.id }
                if settings.config.selectedCarID == nil { settings.config.selectedCarID = found.first?.id }
                ids = found.map(\.id)
            }
            for id in ids {
                let snapshot = try await api.fetchLiveStatus(carID: id)
                guard epoch == connectionEpoch, !intentionalStop else { return .stop }
                if let snapshot { commitPolled(snapshot, carID: id) }
            }
            status = .polling
            lastError = nil
            return .polled(ids)
        } catch {
            guard epoch == connectionEpoch, !intentionalStop, !Task.isCancelled else { return .stop }
            let message = (error as? APIError)?.errorDescription ?? error.localizedDescription
            lastError = message
            status = .failed(message)
            return .failed
        }
    }

    private func commitPolled(_ snapshot: LiveStatusDTO, carID: Int) {
        let previous = states[carID]
        var current = previous ?? VehicleState(carID: carID)
        snapshot.apply(to: &current)
        commitFull(current, previous: previous)
    }

    private func handle(topic: String, payload: String, topicRoot: String) {
        let prefix = topicRoot + "/"
        guard topic.hasPrefix(prefix) else { return }
        let rest = String(topic.dropFirst(prefix.count))
        let parts = rest.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let carID = Int(parts[0]) else { return }
        applyMetric(carID: carID, metric: parts[1], value: payload)
    }

    private func handleDisconnect(epoch: Int) {
        // Ignore drops from a superseded connection — only the current one may reconnect.
        guard epoch == connectionEpoch, !intentionalStop else { return }
        if status.isLive { status = .disconnected }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !intentionalStop, !settings.config.demoMode, !settings.config.usesAPIPolling,
              settings.config.hasMQTTConfigured else { return }
        reconnectTask?.cancel()
        reconnectAttempt += 1
        let delay = min(30.0, pow(2.0, Double(min(reconnectAttempt, 5))))
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !self.intentionalStop else { return }
            self.startLive()
        }
    }

    // MARK: - State application

    private func applyMetric(carID: Int, metric: String, value: String) {
        var current = states[carID] ?? VehicleState(carID: carID)
        let previous = current
        current.apply(metric: metric, value: value)
        if metric == "power" { powerSampleDates[carID] = current.lastUpdated }
        if metric == "speed" { speedSampleDates[carID] = current.lastUpdated }
        let power = recentPower(for: current, at: current.lastUpdated)
        motion(for: carID).ingest(speedKmh: current.speed, powerKw: power,
                                 speedChanged: metric == "speed", at: current.lastUpdated)
        driverTrip.ingest(previous: previous, current: current)
        var telemetry = current
        telemetry.power = power
        if let date = speedSampleDates[carID], current.lastUpdated.timeIntervalSince(date) <= 5 {
            telemetry.speed = current.speed
        } else { telemetry.speed = nil }
        driverConsumption.ingest(previous: previous, current: telemetry)
        states[carID] = current
        upsertCar(from: current)
        notifications.process(previous: previous, current: current, carName: name(for: carID, hint: current.displayName))
        saveCacheThrottled(current)
        pushToWidgets(previous: previous, current: current)
    }

    private func commitFull(_ snapshot: VehicleState) {
        commitFull(snapshot, previous: states[snapshot.carID])
    }

    private func commitFull(_ snapshot: VehicleState, previous: VehicleState?) {
        states[snapshot.carID] = snapshot
        powerSampleDates[snapshot.carID] = snapshot.power == nil ? nil : snapshot.lastUpdated
        speedSampleDates[snapshot.carID] = snapshot.speed == nil ? nil : snapshot.lastUpdated
        motion(for: snapshot.carID).ingest(speedKmh: snapshot.speed, powerKw: snapshot.power,
                                         speedChanged: true, at: snapshot.lastUpdated)
        driverTrip.ingest(previous: previous, current: snapshot)
        driverConsumption.ingest(previous: previous, current: snapshot)
        upsertCar(from: snapshot)
        notifications.process(previous: previous, current: snapshot, carName: name(for: snapshot.carID, hint: snapshot.displayName))
        saveCacheThrottled(snapshot)
        pushToWidgets(previous: previous, current: snapshot)
    }

    /// Mirror the actively-selected car to the home/lock widgets and the charging Live Activity.
    private func pushToWidgets(previous: VehicleState?, current: VehicleState) {
        guard current.carID == resolvedCarID else { return }
        let chargingChanged = (previous?.isCharging ?? false) != current.isCharging
        WidgetBridge.update(state: current,
                            carName: name(for: current.carID, hint: current.displayName),
                            config: settings.config,
                            cache: cache,
                            force: chargingChanged)
    }

    private func upsertCar(from state: VehicleState) {
        let id = state.carID
        if let idx = cars.firstIndex(where: { $0.id == id }) {
            if let name = state.displayName, !name.isEmpty { cars[idx].displayName = name }
            if let model = state.model { cars[idx].model = model }
        } else {
            cars.append(CarSummary(id: id, displayName: state.displayName ?? "Car \(id)", model: state.model))
            cars.sort { $0.id < $1.id }
        }
        if settings.config.selectedCarID == nil {
            settings.config.selectedCarID = id
        }
    }

    private func name(for carID: Int, hint: String?) -> String {
        if let hint, !hint.isEmpty { return hint }
        return cars.first(where: { $0.id == carID })?.title ?? "Tesla"
    }

    private func saveCacheThrottled(_ state: VehicleState) {
        let now = Date()
        if let last = lastCacheSave[state.carID], now.timeIntervalSince(last) < 10 { return }
        lastCacheSave[state.carID] = now
        cache.scoped(to: settings.config).saveSnapshotInBackground(state)
    }

    func currentPowerKw(at date: Date = Date()) -> Double? {
        currentState.flatMap { recentPower(for: $0, at: date) }
    }

    var currentSpeedSample: DriverSpeedSample? {
        guard let state = currentState, let speed = state.speed,
              speed.isFinite, speed >= 0, let date = speedSampleDates[state.carID] else { return nil }
        return DriverSpeedSample(speedKmh: speed, date: date, source: .teslaMate, accuracyKmh: nil)
    }

    private func recentPower(for state: VehicleState, at date: Date) -> Double? {
        guard let power = state.power, let sampleDate = powerSampleDates[state.carID] else { return nil }
        return DriverPowerSample(powerKw: power, date: sampleDate).value(at: date)
    }

    private func motion(for carID: Int) -> MotionEstimator {
        if let estimator = motionByCar[carID] { return estimator }
        let estimator = MotionEstimator()
        motionByCar[carID] = estimator
        return estimator
    }
}
