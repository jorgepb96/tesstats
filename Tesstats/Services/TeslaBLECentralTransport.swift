import Foundation

#if os(iOS)
import CoreBluetooth

@MainActor
protocol TeslaBLETransporting: AnyObject {
    var isConnected: Bool { get }
    func connect(vin: String, timeout: TimeInterval) async throws
    func disconnect()
    func send(_ message: Data) async throws
    func receive(timeout: TimeInterval) async throws -> Data
}

/// Tesla beacons are selected by the VIN-derived local name documented by Tesla. Discovery is
/// intentionally performed without a CoreBluetooth service filter: the official client also
/// scans advertisements first and only discovers service 0x211 after connecting.
enum TeslaBLEAdvertisementMatcher {
    static func matches(expectedLocalName: String,
                        advertisedLocalName: String?,
                        peripheralName: String?) -> Bool {
        let advertised = advertisedLocalName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let peripheral = peripheralName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return advertised == expectedLocalName || peripheral == expectedLocalName
    }
}

@MainActor
final class TeslaBLECentralTransport: NSObject, TeslaBLETransporting,
                                       @preconcurrency CBCentralManagerDelegate,
                                       @preconcurrency CBPeripheralDelegate {
    private let service = CBUUID(string: TeslaBLEWire.serviceUUID)
    private let writeID = CBUUID(string: TeslaBLEWire.writeUUID)
    private let readID = CBUUID(string: TeslaBLEWire.readUUID)

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var readCharacteristic: CBCharacteristic?
    private var expectedLocalName: String?
    private var inputBuffer = Data()
    private var inbox: [Data] = []

    private var stateWaiter: (id: UUID, continuation: CheckedContinuation<Void, Error>)?
    private var connectionWaiter: (id: UUID, continuation: CheckedContinuation<Void, Error>)?
    private var readyWaiter: (id: UUID, continuation: CheckedContinuation<Void, Error>)?
    private var writeWaiter: (id: UUID, continuation: CheckedContinuation<Void, Error>)?
    private var receiveWaiter: (id: UUID, continuation: CheckedContinuation<Data, Error>)?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    var isConnected: Bool {
        peripheral?.state == .connected && writeCharacteristic != nil && readCharacteristic != nil
    }

    func connect(vin: String, timeout: TimeInterval = 20) async throws {
        disconnect()
        try await waitForBluetooth(timeout: timeout)
        expectedLocalName = TeslaBLEWire.vehicleLocalName(vin: vin)
        // Tesla's beacon identity lives in the advertisement local name. Filtering here by the
        // GATT service can make iOS discard a valid Tesla advertisement before didDiscover runs.
        // We still connect only to the exact VIN-derived local name, never to an arbitrary device.
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        try await withTimeout(timeout, assign: { self.connectionWaiter = $0 }, current: { self.connectionWaiter })
        guard let peripheral else { throw DriverBluetoothError.connectionFailed }
        peripheral.delegate = self
        peripheral.discoverServices([service])
        try await withTimeout(timeout, assign: { self.readyWaiter = $0 }, current: { self.readyWaiter })
        guard isConnected else { throw DriverBluetoothError.connectionFailed }
    }

    func disconnect() {
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        writeCharacteristic = nil
        readCharacteristic = nil
        expectedLocalName = nil
        inputBuffer.removeAll(keepingCapacity: false)
        inbox.removeAll(keepingCapacity: false)
        failWaiters(with: DriverBluetoothError.disconnected)
    }

    func send(_ message: Data) async throws {
        guard let peripheral, let characteristic = writeCharacteristic, isConnected else {
            throw DriverBluetoothError.disconnected
        }
        let framed = try TeslaBLEWire.frame(message)
        let maximum = max(20, peripheral.maximumWriteValueLength(for: .withResponse))
        var offset = 0
        while offset < framed.count {
            let end = min(framed.count, offset + maximum)
            let chunk = framed.subdata(in: offset..<end)
            peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
            try await withTimeout(4, assign: { self.writeWaiter = $0 }, current: { self.writeWaiter })
            offset = end
        }
    }

    func receive(timeout: TimeInterval) async throws -> Data {
        if !inbox.isEmpty { return inbox.removeFirst() }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            receiveWaiter = (id, continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, self.receiveWaiter?.id == id else { return }
                let waiter = self.receiveWaiter?.continuation
                self.receiveWaiter = nil
                waiter?.resume(throwing: DriverBluetoothError.responseTimedOut)
            }
        }
    }

    private func waitForBluetooth(timeout: TimeInterval) async throws {
        switch central.state {
        case .poweredOn: return
        case .unauthorized: throw DriverBluetoothError.permissionDenied
        case .poweredOff: throw DriverBluetoothError.bluetoothDisabled
        case .unsupported: throw DriverBluetoothError.unavailable
        case .unknown, .resetting:
            try await withTimeout(timeout, assign: { self.stateWaiter = $0 }, current: { self.stateWaiter })
            try await waitForBluetooth(timeout: timeout)
        @unknown default:
            throw DriverBluetoothError.unavailable
        }
    }

    private func withTimeout(
        _ seconds: TimeInterval,
        assign: ((id: UUID, continuation: CheckedContinuation<Void, Error>)) -> Void,
        current: @escaping () -> (id: UUID, continuation: CheckedContinuation<Void, Error>)?
    ) async throws {
        let id = UUID()
        try await withCheckedThrowingContinuation { continuation in
            assign((id, continuation))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard let self, current()?.id == id else { return }
                if self.connectionWaiter?.id == id {
                    let waiter = self.connectionWaiter?.continuation
                    self.connectionWaiter = nil
                    self.central.stopScan()
                    waiter?.resume(throwing: DriverBluetoothError.vehicleNotFound)
                } else if self.readyWaiter?.id == id {
                    let waiter = self.readyWaiter?.continuation
                    self.readyWaiter = nil
                    waiter?.resume(throwing: DriverBluetoothError.connectionFailed)
                } else if self.writeWaiter?.id == id {
                    let waiter = self.writeWaiter?.continuation
                    self.writeWaiter = nil
                    waiter?.resume(throwing: DriverBluetoothError.responseTimedOut)
                } else if self.stateWaiter?.id == id {
                    let waiter = self.stateWaiter?.continuation
                    self.stateWaiter = nil
                    waiter?.resume(throwing: DriverBluetoothError.unavailable)
                }
            }
        }
    }

    private func failWaiters(with error: Error) {
        let state = stateWaiter?.continuation; stateWaiter = nil; state?.resume(throwing: error)
        let connection = connectionWaiter?.continuation; connectionWaiter = nil; connection?.resume(throwing: error)
        let ready = readyWaiter?.continuation; readyWaiter = nil; ready?.resume(throwing: error)
        let write = writeWaiter?.continuation; writeWaiter = nil; write?.resume(throwing: error)
        let receive = receiveWaiter?.continuation; receiveWaiter = nil; receive?.resume(throwing: error)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard let pending = stateWaiter else { return }
        switch central.state {
        case .poweredOn:
            stateWaiter = nil; pending.continuation.resume()
        case .unauthorized:
            stateWaiter = nil; pending.continuation.resume(throwing: DriverBluetoothError.permissionDenied)
        case .poweredOff:
            stateWaiter = nil; pending.continuation.resume(throwing: DriverBluetoothError.bluetoothDisabled)
        case .unsupported:
            stateWaiter = nil; pending.continuation.resume(throwing: DriverBluetoothError.unavailable)
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard connectionWaiter != nil, self.peripheral == nil, let expectedLocalName else { return }
        let advertisedLocalName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard TeslaBLEAdvertisementMatcher.matches(expectedLocalName: expectedLocalName,
                                                    advertisedLocalName: advertisedLocalName,
                                                    peripheralName: peripheral.name) else { return }
        central.stopScan()
        if let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber,
           !connectable.boolValue {
            let waiter = connectionWaiter?.continuation
            connectionWaiter = nil
            waiter?.resume(throwing: DriverBluetoothError.connectionLimitReached)
            return
        }
        self.peripheral = peripheral
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let waiter = connectionWaiter?.continuation
        connectionWaiter = nil
        waiter?.resume()
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        let waiter = connectionWaiter?.continuation
        connectionWaiter = nil
        waiter?.resume(throwing: error ?? DriverBluetoothError.connectionFailed)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        timestamp: CFAbsoluteTime,
                        isReconnecting: Bool,
                        error: Error?) {
        self.peripheral = nil
        writeCharacteristic = nil
        readCharacteristic = nil
        failWaiters(with: error ?? DriverBluetoothError.disconnected)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            let waiter = readyWaiter?.continuation; readyWaiter = nil; waiter?.resume(throwing: error)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == self.service }) else {
            let waiter = readyWaiter?.continuation; readyWaiter = nil
            waiter?.resume(throwing: DriverBluetoothError.protocolViolation)
            return
        }
        peripheral.discoverCharacteristics([writeID, readID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            let waiter = readyWaiter?.continuation; readyWaiter = nil; waiter?.resume(throwing: error)
            return
        }
        writeCharacteristic = service.characteristics?.first(where: { $0.uuid == writeID })
        readCharacteristic = service.characteristics?.first(where: { $0.uuid == readID })
        guard let readCharacteristic, writeCharacteristic != nil else {
            let waiter = readyWaiter?.continuation; readyWaiter = nil
            waiter?.resume(throwing: DriverBluetoothError.protocolViolation)
            return
        }
        peripheral.setNotifyValue(true, for: readCharacteristic)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == readID else { return }
        let waiter = readyWaiter?.continuation
        readyWaiter = nil
        if let error { waiter?.resume(throwing: error) }
        else if characteristic.isNotifying { waiter?.resume() }
        else { waiter?.resume(throwing: DriverBluetoothError.connectionFailed) }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        let waiter = writeWaiter?.continuation
        writeWaiter = nil
        if let error { waiter?.resume(throwing: error) }
        else { waiter?.resume() }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, characteristic.uuid == readID, let value = characteristic.value else { return }
        inputBuffer.append(value)
        flushMessages()
    }

    private func flushMessages() {
        while inputBuffer.count >= 2 {
            let length = Int(inputBuffer[0]) * 256 + Int(inputBuffer[1])
            guard length <= 1_024 else {
                inputBuffer.removeAll()
                failWaiters(with: DriverBluetoothError.protocolViolation)
                return
            }
            guard inputBuffer.count >= length + 2 else { return }
            let message = inputBuffer.subdata(in: 2..<(length + 2))
            inputBuffer.removeSubrange(0..<(length + 2))
            if let waiter = receiveWaiter?.continuation {
                receiveWaiter = nil
                waiter.resume(returning: message)
            } else {
                inbox.append(message)
                if inbox.count > 16 { inbox.removeFirst(inbox.count - 16) }
            }
        }
    }
}
#endif
