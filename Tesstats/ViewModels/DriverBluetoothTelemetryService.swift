import Foundation
import Observation

#if os(iOS)

@MainActor
@Observable
final class DriverBluetoothTelemetryService {
    private(set) var identity: DriverBluetoothVehicleIdentity?
    private(set) var pairingState: DriverBluetoothPairingState = .unavailable(L("Select a vehicle to configure Bluetooth."))
    private(set) var connectionState: DriverBluetoothConnectionState = .idle
    private(set) var snapshot: DriverBluetoothTelemetrySnapshot?
    private(set) var tripDistanceKm: Double?
    private(set) var lastTelemetryDate: Date?
    private(set) var lastTelemetryIssue: String?
    /// Auto mode only selects BLE after several consecutive valid replies. One isolated late
    /// packet therefore cannot make the speedometer bounce back from GPS for a single frame.
    private(set) var isTelemetryStable = false

    private let settings: SettingsStore
    private let preferences: DriverBluetoothPreferencesStore
    private let keyStore: TeslaBLEKeyStore
    private let transportFactory: @MainActor () -> TeslaBLETransporting
    private var transport: TeslaBLETransporting?
    private var session: TeslaBLEProtocolSession?
    private var runTask: Task<Void, Never>?
    private var pairingTask: Task<Void, Never>?
    private var generation = 0
    private var tripStartOdometerKm: [String: Double] = [:]
    private var lastShiftState: [String: ShiftState] = [:]
    private var telemetryStability = DriverBluetoothTelemetryStability()

    init(settings: SettingsStore,
         preferences: DriverBluetoothPreferencesStore = DriverBluetoothPreferencesStore(),
         keyStore: TeslaBLEKeyStore = TeslaBLEKeyStore(),
         transportFactory: @escaping @MainActor () -> TeslaBLETransporting = { TeslaBLECentralTransport() }) {
        self.settings = settings
        self.preferences = preferences
        self.keyStore = keyStore
        self.transportFactory = transportFactory
    }

    var isEnabled: Bool {
        guard let identity else { return false }
        return preferences.isEnabled(vehicleID: identity.vehicleID)
    }

    var canPair: Bool {
        identity?.isInitiallySupported == true && keyStore.isHardwareProtectionAvailable
    }

    func prepare(carID: Int?) async {
        guard let carID else {
            identity = nil
            pairingState = .unavailable(L("Select a vehicle to configure Bluetooth."))
            return
        }
        do {
            let resolved = try await resolveIdentity(carID: carID)
            identity = resolved
            guard resolved.isInitiallySupported else {
                pairingState = .unavailable(DriverBluetoothError.unsupportedVehicle.localizedDescription)
                return
            }
            guard keyStore.isHardwareProtectionAvailable else {
                pairingState = .unavailable(DriverBluetoothError.unavailable.localizedDescription)
                return
            }
            if keyStore.load(vehicleID: resolved.vehicleID) != nil {
                pairingState = preferences.isEnabled(vehicleID: resolved.vehicleID) ? .paired : .pairedDisabled
            } else {
                pairingState = .unpaired
            }
        } catch {
            identity = nil
            pairingState = .unavailable(error.localizedDescription)
        }
    }

    func start(carID: Int?) async {
        // A vehicle switch must never leave the previous VIN connected. Do not interrupt an
        // in-progress approval flow when iOS briefly changes scene phase.
        guard pairingTask == nil else { return }
        generation &+= 1
        runTask?.cancel(); runTask = nil
        transport?.disconnect(); transport = nil
        session = nil
        snapshot = nil
        lastTelemetryDate = nil
        lastTelemetryIssue = nil
        isTelemetryStable = false
        telemetryStability.reset()
        tripDistanceKm = nil
        tripStartOdometerKm.removeAll()
        lastShiftState.removeAll()
        connectionState = .idle
        await prepare(carID: carID)
        guard let identity, preferences.isEnabled(vehicleID: identity.vehicleID),
              let key = keyStore.load(vehicleID: identity.vehicleID) else { return }
        startRunLoop(identity: identity, key: key)
    }

    func stop() {
        generation &+= 1
        runTask?.cancel(); runTask = nil
        pairingTask?.cancel(); pairingTask = nil
        transport?.disconnect(); transport = nil
        session = nil
        snapshot = nil
        lastTelemetryDate = nil
        lastTelemetryIssue = nil
        isTelemetryStable = false
        telemetryStability.reset()
        tripDistanceKm = nil
        tripStartOdometerKm.removeAll()
        lastShiftState.removeAll()
        connectionState = .idle
    }

    func setEnabled(_ enabled: Bool) {
        guard let identity else { return }
        preferences.setEnabled(enabled, vehicleID: identity.vehicleID)
        if enabled, let key = keyStore.load(vehicleID: identity.vehicleID) {
            pairingState = .paired
            startRunLoop(identity: identity, key: key)
        } else {
            runTask?.cancel(); runTask = nil
            transport?.disconnect(); transport = nil
            session = nil
            snapshot = nil
            lastTelemetryDate = nil
            lastTelemetryIssue = nil
            isTelemetryStable = false
            telemetryStability.reset()
            tripDistanceKm = nil
            tripStartOdometerKm.removeAll()
            lastShiftState.removeAll()
            connectionState = .idle
            pairingState = keyStore.load(vehicleID: identity.vehicleID) == nil ? .unpaired : .pairedDisabled
        }
    }

    func pair() {
        guard pairingTask == nil, let identity, identity.isInitiallySupported else { return }
        pairingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performPairing(identity: identity)
            self.pairingTask = nil
        }
    }

    func cancelPairing() {
        pairingTask?.cancel(); pairingTask = nil
        transport?.disconnect(); transport = nil
        session = nil
        if let identity {
            pairingState = keyStore.load(vehicleID: identity.vehicleID) == nil ? .unpaired : .pairedDisabled
        }
        connectionState = .idle
        isTelemetryStable = false
        lastTelemetryIssue = nil
        telemetryStability.reset()
    }

    func deletePairing() {
        guard let identity else { return }
        stop()
        keyStore.delete(vehicleID: identity.vehicleID)
        preferences.delete(vehicleID: identity.vehicleID)
        self.identity = identity
        pairingState = .unpaired
    }

    func eraseAll() {
        stop()
        keyStore.deleteAll()
        preferences.deleteAll()
        identity = nil
        pairingState = .unavailable(L("Select a vehicle to configure Bluetooth."))
    }

    private func performPairing(identity: DriverBluetoothVehicleIdentity) async {
        do {
            pairingState = .connecting
            connectionState = .scanning
            let provisional = try keyStore.createProvisional(vin: identity.vin)
            let transport = transportFactory()
            self.transport = transport
            try await transport.connect(vin: identity.vin, timeout: 30)
            connectionState = .connecting
            try await transport.send(TeslaBLEWire.encode(.enrollVehicleMonitor(publicKey: provisional.publicKey)))
            pairingState = .awaitingVehicleApproval

            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline, !Task.isCancelled {
                do {
                    connectionState = .authenticating
                    let session = try await establishSession(key: provisional, transport: transport)
                    self.session = session
                    // A valid authenticated Infotainment session proves that the vehicle enrolled
                    // this monitor-only key. DriveState is intentionally not part of pairing:
                    // some firmware returns RESPONSE_MTU_EXCEEDED for that query even though the
                    // key and GATT connection are both valid.
                    try keyStore.save(provisional)
                    preferences.remember(vehicleID: identity.vehicleID,
                                         carID: identity.carID,
                                         scopeID: currentScopeID)
                    preferences.setEnabled(true, vehicleID: identity.vehicleID)
                    pairingState = .paired
                    connectionState = .authenticating
                    startPollingConnected(identity: identity, key: provisional, transport: transport)
                    return
                } catch DriverBluetoothError.keyRejected {
                    connectionState = .authenticating
                } catch DriverBluetoothError.responseTimedOut {
                    connectionState = .authenticating
                }
                try? await Task.sleep(for: .seconds(2))
            }
            guard !Task.isCancelled else { return }
            throw DriverBluetoothError.pairingTimedOut
        } catch {
            transport?.disconnect(); transport = nil
            session = nil
            connectionState = .failed(error.localizedDescription)
            pairingState = .failed(error.localizedDescription)
        }
    }

    private func startRunLoop(identity: DriverBluetoothVehicleIdentity, key: TeslaBLEStoredKey) {
        generation &+= 1
        let thisGeneration = generation
        runTask?.cancel()
        transport?.disconnect(); transport = nil
        session = nil
        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var backoff: TimeInterval = 1
            while !Task.isCancelled, thisGeneration == self.generation,
                  self.preferences.isEnabled(vehicleID: identity.vehicleID) {
                do {
                    self.connectionState = .scanning
                    let transport = self.transportFactory()
                    self.transport = transport
                    try await transport.connect(vin: identity.vin, timeout: 20)
                    self.connectionState = .authenticating
                    let session = try await self.establishSession(key: key, transport: transport)
                    self.session = session
                    // A valid session proves that the paired key is accepted, not that motion
                    // telemetry is arriving. `publish` marks the link connected after the first
                    // successfully decoded DriveState response.
                    self.connectionState = .authenticating
                    self.pairingState = .paired
                    self.isTelemetryStable = false
                    self.telemetryStability.reset()
                    backoff = 1
                    try await self.poll(identity: identity, key: key, transport: transport)
                } catch {
                    guard !Task.isCancelled else { break }
                    self.transport?.disconnect(); self.transport = nil
                    self.session = nil
                    self.isTelemetryStable = false
                    self.telemetryStability.reset()
                    if let bluetoothError = error as? DriverBluetoothError {
                        switch bluetoothError {
                        case .disconnected, .responseTimedOut, .connectionFailed, .vehicleNotFound:
                            self.connectionState = .connecting
                        default:
                            self.connectionState = .failed(error.localizedDescription)
                        }
                    } else {
                        self.connectionState = .connecting
                    }
                    try? await Task.sleep(for: .seconds(backoff))
                    backoff = min(5, backoff * 2)
                }
            }
        }
    }

    private func startPollingConnected(identity: DriverBluetoothVehicleIdentity,
                                       key: TeslaBLEStoredKey,
                                       transport: TeslaBLETransporting) {
        generation &+= 1
        let thisGeneration = generation
        runTask?.cancel()
        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.poll(identity: identity, key: key, transport: transport)
            } catch {
                guard !Task.isCancelled, thisGeneration == self.generation else { return }
                self.transport?.disconnect(); self.transport = nil
                self.session = nil
                self.startRunLoop(identity: identity, key: key)
            }
        }
    }

    private func poll(identity: DriverBluetoothVehicleIdentity,
                      key: TeslaBLEStoredKey,
                      transport: TeslaBLETransporting) async throws {
        while !Task.isCancelled, preferences.isEnabled(vehicleID: identity.vehicleID) {
            guard var session else { throw DriverBluetoothError.protocolViolation }
            let request = try session.makeDriveStateRequest()
            self.session = session
            try await transport.send(request.bytes)
            do {
                let response = try await receiveRoutable(
                    transport: transport,
                    timeout: 5,
                    accepting: { TeslaBLEWire.isDriveStateResponse($0, matching: request.requestUUID) }
                )
                publish(try session.decryptDriveStateResponse(response, request: request))
                self.session = session
                connectionState = .connected
                try await Task.sleep(for: .milliseconds(350))
            } catch DriverBluetoothError.temporaryVehicleFault(let code) {
                self.session = session
                lastTelemetryIssue = DriverBluetoothError.temporaryVehicleFault(code).localizedDescription
                _ = telemetryStability.recordTimeout()
                isTelemetryStable = telemetryStability.isStable
                // BUSY/TIMEOUT/INTERNAL are application replies, not a dropped BLE link.
                connectionState = .connected
                try await Task.sleep(for: .seconds(1))
            } catch DriverBluetoothError.responseTooLarge {
                self.session = session
                lastTelemetryIssue = DriverBluetoothError.responseTooLarge.localizedDescription
                telemetryStability.reset()
                isTelemetryStable = false
                // Keep the enrolled session alive. Auto mode will consistently use iPhone GPS
                // instead of flashing through a disconnect/reconnect loop.
                connectionState = .connected
                try await Task.sleep(for: .seconds(2))
            } catch DriverBluetoothError.sessionOutOfSync {
                lastTelemetryIssue = DriverBluetoothError.sessionOutOfSync.localizedDescription
                telemetryStability.reset()
                isTelemetryStable = false
                connectionState = .authenticating
                self.session = try await establishSession(key: key, transport: transport)
                try await Task.sleep(for: .seconds(1))
            } catch DriverBluetoothError.responseTimedOut {
                self.session = session
                // A delayed reply is not a radio disconnect. Keep the authenticated CoreBluetooth
                // link alive and let Auto mode fall back until three consecutive replies restore
                // confidence. Only rebuild the session after a sustained silence.
                let shouldReconnect = telemetryStability.recordTimeout()
                isTelemetryStable = telemetryStability.isStable
                if shouldReconnect {
                    throw DriverBluetoothError.responseTimedOut
                }
                try await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func establishSession(key: TeslaBLEStoredKey,
                                  transport: TeslaBLETransporting) async throws -> TeslaBLEProtocolSession {
        let uuid = TeslaBLEWire.randomBytes(count: 16)
        let address = TeslaBLEWire.randomBytes(count: 16)
        let request = TeslaBLEWire.encodeSessionRequest(publicKey: key.publicKey,
                                                        routingAddress: address,
                                                        uuid: uuid)
        try await transport.send(request)
        let response = try await receiveRoutable(transport: transport, timeout: 5)
        guard let material = try TeslaBLEWire.sessionMaterial(from: response) else {
            throw DriverBluetoothError.keyRejected
        }
        let info = try TeslaBLEWire.decodeSessionInfo(material.info)
        guard info.status == 0 else { throw DriverBluetoothError.keyRejected }
        let shared = try key.sharedSecret(with: info.publicKey)
        return try TeslaBLEProtocolSession(vin: key.vin,
                                           localPublicKey: key.publicKey,
                                           sharedSecret: shared,
                                           encodedSessionInfo: material.info,
                                           sessionInfoTag: material.tag,
                                           challenge: uuid)
    }

    private func receiveRoutable(
        transport: TeslaBLETransporting,
        timeout: TimeInterval,
        accepting: (Data) -> Bool = { TeslaBLEWire.isAuthenticatedRoutableMessage($0) }
    ) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let remaining = max(0.05, deadline.timeIntervalSinceNow)
            let data = try await transport.receive(timeout: remaining)
            // Ignore unrelated VCSEC notifications. Only authenticated session material or an
            // encrypted response envelope is allowed to reach the session parser.
            if accepting(data) { return data }
        }
        throw DriverBluetoothError.responseTimedOut
    }

    private func publish(_ value: DriverBluetoothTelemetrySnapshot) {
        snapshot = value
        lastTelemetryDate = value.date
        lastTelemetryIssue = nil
        connectionState = .connected
        telemetryStability.recordResponse()
        isTelemetryStable = telemetryStability.isStable
        let previousShift = lastShiftState[value.vehicleID]
        lastShiftState[value.vehicleID] = value.shiftState
        guard let odometer = value.odometerKm else { return }
        let driving = value.shiftState == .drive || value.shiftState == .reverse
        if driving {
            if previousShift != .drive && previousShift != .reverse || tripStartOdometerKm[value.vehicleID] == nil {
                tripStartOdometerKm[value.vehicleID] = odometer
            }
            if let start = tripStartOdometerKm[value.vehicleID] {
                tripDistanceKm = max(0, odometer - start)
            }
        } else if previousShift == .drive || previousShift == .reverse {
            tripStartOdometerKm[value.vehicleID] = nil
            tripDistanceKm = nil
        }
    }

    private func resolveIdentity(carID: Int) async throws -> DriverBluetoothVehicleIdentity {
        let scopeID = currentScopeID
        if settings.config.hasAPIConfigured {
            let service = HistoryAPIService(config: settings.makeAPIConfig())
            if let info = try? await service.fetchCarInfo(carID: carID),
               let rawVIN = info.vin {
                guard let vin = DriverBluetoothIdentity.normalizedVIN(rawVIN) else {
                    throw DriverBluetoothError.invalidVIN
                }
                let vehicleID = DriverBluetoothIdentity.identifier(forVIN: vin)
                preferences.remember(vehicleID: vehicleID, carID: carID, scopeID: scopeID)
                return DriverBluetoothVehicleIdentity(carID: carID,
                                                      vehicleID: vehicleID,
                                                      vin: vin,
                                                      displayName: info.name,
                                                      model: info.model)
            }
        }

        if let vehicleID = preferences.vehicleID(carID: carID, scopeID: scopeID),
           let stored = keyStore.load(vehicleID: vehicleID) {
            return DriverBluetoothVehicleIdentity(carID: carID,
                                                  vehicleID: vehicleID,
                                                  vin: stored.vin,
                                                  displayName: "Tesla",
                                                  model: "Model 3")
        }
        throw DriverBluetoothError.vinUnavailable
    }

    private var currentScopeID: String {
        DriverBluetoothIdentity.scopeIdentifier(profileID: settings.activeProfileID,
                                                config: settings.config)
    }
}

#else

@MainActor
@Observable
final class DriverBluetoothTelemetryService {
    private(set) var identity: DriverBluetoothVehicleIdentity?
    private(set) var pairingState: DriverBluetoothPairingState = .unavailable(L("Direct Bluetooth is available on iPhone and iPad."))
    private(set) var connectionState: DriverBluetoothConnectionState = .idle
    private(set) var snapshot: DriverBluetoothTelemetrySnapshot?
    private(set) var tripDistanceKm: Double?
    private(set) var lastTelemetryDate: Date?
    private(set) var lastTelemetryIssue: String?
    private(set) var isTelemetryStable = false
    var isEnabled: Bool { false }
    var canPair: Bool { false }
    init(settings: SettingsStore) {}
    func prepare(carID: Int?) async {}
    func start(carID: Int?) async {}
    func stop() {}
    func setEnabled(_ enabled: Bool) {}
    func pair() {}
    func cancelPairing() {}
    func deletePairing() {}
    func eraseAll() {}
}

#endif
