import Foundation
import CryptoKit
import Security

/// Security boundary for outbound BLE traffic. These are the only application messages that the
/// app can encode. There is intentionally no generic "send command" API and no vehicle-control
/// protobuf schema in the target.
enum TeslaBLEReadOnlyCommand: Equatable, Sendable {
    case enrollVehicleMonitor(publicKey: Data)
    case readDriveState
}

struct TeslaBLEEncryptedRequest: Sendable {
    let bytes: Data
    let requestUUID: Data
    let requestID: Data
}

struct TeslaBLESessionInfo: Equatable, Sendable {
    let counter: UInt32
    let publicKey: Data
    let epoch: Data
    let clockTime: UInt32
    let status: UInt32
}

private enum TeslaBLEDomain: UInt64 {
    case vehicleSecurity = 2
    case infotainment = 3
}

private enum TeslaBLESignatureType: UInt8 {
    case aesGCMPersonalized = 5
    case sessionInfoHMAC = 6
    case aesGCMResponse = 9
}

struct TeslaBLEProtocolSession: Sendable {
    private let vin: String
    private let localPublicKey: Data
    private let symmetricKey: SymmetricKey
    private var epoch: Data
    private var counter: UInt32
    private var lastResponseCounter: UInt32?
    private var timeZero: Date

    init(vin: String,
         localPublicKey: Data,
         sharedSecret: Data,
         encodedSessionInfo: Data,
         sessionInfoTag: Data,
         challenge: Data,
         receivedAt: Date = Date()) throws {
        let info = try TeslaBLEWire.decodeSessionInfo(encodedSessionInfo)
        guard info.status == 0, info.epoch.count == 16, info.publicKey.count == 65 else {
            throw DriverBluetoothError.keyRejected
        }
        let digest = Insecure.SHA1.hash(data: sharedSecret)
        let keyData = Data(digest.prefix(16))
        let key = SymmetricKey(data: keyData)

        let sessionSubkey = TeslaBLEWire.hmacSHA256(key: key, data: Data("session info".utf8))
        var metadata = TeslaBLEMetadata(hmacKey: SymmetricKey(data: sessionSubkey))
        try metadata.add(tag: 0, bytes: Data([TeslaBLESignatureType.sessionInfoHMAC.rawValue]))
        try metadata.add(tag: 2, bytes: Data(vin.utf8))
        try metadata.add(tag: 6, bytes: challenge)
        let expected = metadata.finish(message: encodedSessionInfo)
        guard TeslaBLEWire.constantTimeEqual(expected, sessionInfoTag) else {
            throw DriverBluetoothError.protocolViolation
        }

        self.vin = vin
        self.localPublicKey = localPublicKey
        self.symmetricKey = key
        self.epoch = info.epoch
        self.counter = info.counter
        self.lastResponseCounter = nil
        self.timeZero = receivedAt.addingTimeInterval(-TimeInterval(info.clockTime))
    }

    mutating func makeDriveStateRequest(now: Date = Date()) throws -> TeslaBLEEncryptedRequest {
        guard counter < UInt32.max else { throw DriverBluetoothError.protocolViolation }
        counter += 1
        let expiration = UInt32(max(0, now.addingTimeInterval(5).timeIntervalSince(timeZero)))
        let flags: UInt32 = 1 << 1
        let plaintext = TeslaBLEWire.encodeReadDriveState()

        var metadata = TeslaBLEMetadata()
        try metadata.add(tag: 0, bytes: Data([TeslaBLESignatureType.aesGCMPersonalized.rawValue]))
        try metadata.add(tag: 1, bytes: Data([UInt8(TeslaBLEDomain.infotainment.rawValue)]))
        try metadata.add(tag: 2, bytes: Data(vin.utf8))
        try metadata.add(tag: 3, bytes: epoch)
        try metadata.add(tag: 4, uint32: expiration)
        try metadata.add(tag: 5, uint32: counter)
        try metadata.add(tag: 7, uint32: flags)
        let aad = metadata.finish()

        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: nonce, authenticating: aad)
        let nonceData = nonce.withUnsafeBytes { Data($0) }
        let signature = TeslaBLEWire.encodeRequestSignature(publicKey: localPublicKey,
                                                            epoch: epoch,
                                                            nonce: nonceData,
                                                            counter: counter,
                                                            expiration: expiration,
                                                            tag: sealed.tag)
        // Tesla copies this identifier into the reply and DriveState can approach the BLE
        // response-size ceiling. Requests are strictly serial, so four unpredictable bytes leave
        // more room for telemetry without introducing response ambiguity inside this session.
        let uuid = TeslaBLEWire.randomBytes(count: 4)
        let address = TeslaBLEWire.randomBytes(count: 16)
        let envelope = TeslaBLEWire.encodeRoutableMessage(toDomain: TeslaBLEDomain.infotainment.rawValue,
                                                          routingAddress: address,
                                                          payload: sealed.ciphertext,
                                                          signatureData: signature,
                                                          uuid: uuid,
                                                          flags: flags)
        return TeslaBLEEncryptedRequest(bytes: envelope,
                                        requestUUID: uuid,
                                        requestID: Data([TeslaBLESignatureType.aesGCMPersonalized.rawValue]) + sealed.tag)
    }

    mutating func decryptDriveStateResponse(_ encoded: Data,
                                            request: TeslaBLEEncryptedRequest) throws -> DriverBluetoothTelemetrySnapshot {
        let message = try TeslaBLEWire.decodeRoutableMessage(encoded)
        guard message.fromDomain == TeslaBLEDomain.infotainment.rawValue,
              message.requestUUID == request.requestUUID else {
            throw DriverBluetoothError.protocolViolation
        }
        if let faultError = TeslaBLEWire.error(forMessageFault: message.fault) {
            throw faultError
        }
        let plaintext: Data
        if let response = message.responseSignature {
            if let lastResponseCounter, response.counter <= lastResponseCounter {
                throw DriverBluetoothError.protocolViolation
            }

            var metadata = TeslaBLEMetadata()
            try metadata.add(tag: 0, bytes: Data([TeslaBLESignatureType.aesGCMResponse.rawValue]))
            try metadata.add(tag: 1, bytes: Data([UInt8(TeslaBLEDomain.infotainment.rawValue)]))
            try metadata.add(tag: 2, bytes: Data(vin.utf8))
            try metadata.add(tag: 5, uint32: response.counter)
            try metadata.add(tag: 7, uint32: message.flags)
            try metadata.add(tag: 8, bytes: request.requestID)
            try metadata.add(tag: 9, uint32: message.fault)
            let aad = metadata.finish()
            let nonce = try AES.GCM.Nonce(data: response.nonce)
            let box = try AES.GCM.SealedBox(nonce: nonce,
                                           ciphertext: message.payload,
                                           tag: response.tag)
            plaintext = try AES.GCM.open(box, using: symmetricKey, authenticating: aad)
            lastResponseCounter = response.counter
        } else {
            // Firmware before encrypted BLE replies ignores FLAG_ENCRYPT_RESPONSE and returns the
            // CarServer payload in plaintext. Tesla documents this compatibility response. It is
            // still matched to the serial request and the exact VIN-derived GATT connection.
            guard !message.payload.isEmpty else { throw DriverBluetoothError.protocolViolation }
            plaintext = message.payload
        }
        let snapshot = try TeslaBLEWire.decodeDriveStateResponse(
            plaintext,
            vehicleID: DriverBluetoothIdentity.identifier(forVIN: vin)
        )
        return snapshot
    }
}

private struct TeslaBLEMetadata {
    private var data = Data()
    private var lastTag: UInt8 = 0
    private let hmacKey: SymmetricKey?

    init(hmacKey: SymmetricKey? = nil) { self.hmacKey = hmacKey }

    mutating func add(tag: UInt8, bytes: Data?) throws {
        guard tag >= lastTag else { throw DriverBluetoothError.protocolViolation }
        guard let bytes else { return }
        guard bytes.count <= 255 else { throw DriverBluetoothError.protocolViolation }
        lastTag = tag
        data.append(tag)
        data.append(UInt8(bytes.count))
        data.append(bytes)
    }

    mutating func add(tag: UInt8, uint32: UInt32) throws {
        var value = uint32.bigEndian
        try withUnsafeBytes(of: &value) { try add(tag: tag, bytes: Data($0)) }
    }

    mutating func finish(message: Data = Data()) -> Data {
        data.append(255)
        data.append(message)
        if let hmacKey { return TeslaBLEWire.hmacSHA256(key: hmacKey, data: data) }
        return Data(SHA256.hash(data: data))
    }
}

fileprivate struct TeslaBLEDecodedRoutableMessage {
    let fromDomain: UInt64?
    let payload: Data
    let sessionInfo: Data?
    let sessionInfoTag: Data?
    let responseSignature: (nonce: Data, counter: UInt32, tag: Data)?
    let requestUUID: Data?
    let flags: UInt32
    let fault: UInt32
}

/// Minimal protobuf wire encoder/decoder derived from Tesla vehicle-command commit
/// f97fa1e4bf617a364c72b85cb5d859528abeda67 (BSD-3-Clause). It deliberately understands only
/// the fields needed for Vehicle Monitor enrollment, authenticated sessions, and DriveState reads.
enum TeslaBLEWire {
    static let serviceUUID = "00000211-B2D1-43F0-9B88-960CEBF8B91E"
    static let writeUUID = "00000212-B2D1-43F0-9B88-960CEBF8B91E"
    static let readUUID = "00000213-B2D1-43F0-9B88-960CEBF8B91E"

    /// Tesla's RoutableMessage faults are not all transport failures. In particular BUSY,
    /// TIMEOUT and INTERNAL mean the existing GATT link should be retained, while counter and
    /// epoch faults require only a new authenticated session. Reconnecting the radio for either
    /// class makes the UI oscillate between paired and connected and can starve telemetry.
    static func error(forMessageFault fault: UInt32) -> DriverBluetoothError? {
        switch fault {
        case 0:
            return nil
        case 1, 2, 11:
            return .temporaryVehicleFault(fault)
        case 5, 6, 15, 17, 20, 26:
            return .sessionOutOfSync
        case 25:
            return .responseTooLarge
        case 3, 4, 7, 27:
            return .keyRejected
        case 14:
            return .connectionLimitReached
        default:
            return .protocolViolation
        }
    }

    static func vehicleLocalName(vin: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(vin.utf8))
        return "S" + digest.prefix(8).map { String(format: "%02x", $0) }.joined() + "C"
    }

    static func encode(_ command: TeslaBLEReadOnlyCommand) -> Data {
        switch command {
        case .enrollVehicleMonitor(let publicKey):
            let key = bytesField(1, publicKey)
            let permission = messageField(1, key) + varintField(4, 5) // ROLE_VEHICLE_MONITOR
            let metadata = varintField(1, 6)                           // IOS_DEVICE
            let operation = messageField(5, permission) + messageField(6, metadata)
            let unsigned = messageField(16, operation)
            let signed = bytesField(2, unsigned) + varintField(3, 2)  // PRESENT_KEY
            return messageField(1, signed)
        case .readDriveState:
            return encodeReadDriveState()
        }
    }

    static func encodeReadDriveState() -> Data {
        let getDriveState = messageField(4, Data())
        let vehicleAction = messageField(1, getDriveState)
        return messageField(2, vehicleAction)
    }

    static func encodeSessionRequest(publicKey: Data,
                                     domain: UInt64 = TeslaBLEDomain.infotainment.rawValue,
                                     routingAddress: Data,
                                     uuid: Data) -> Data {
        let destination = varintField(1, domain)
        let source = bytesField(2, routingAddress)
        let request = bytesField(1, publicKey)
        return messageField(6, destination)
            + messageField(7, source)
            + messageField(14, request)
            + bytesField(51, uuid)
    }

    static func encodeRequestSignature(publicKey: Data,
                                       epoch: Data,
                                       nonce: Data,
                                       counter: UInt32,
                                       expiration: UInt32,
                                       tag: Data) -> Data {
        let identity = bytesField(1, publicKey)
        let personalized = bytesField(1, epoch)
            + bytesField(2, nonce)
            + varintField(3, UInt64(counter))
            + fixed32Field(4, expiration)
            + bytesField(5, tag)
        return messageField(1, identity) + messageField(5, personalized)
    }

    static func encodeRoutableMessage(toDomain: UInt64,
                                      routingAddress: Data,
                                      payload: Data,
                                      signatureData: Data,
                                      uuid: Data,
                                      flags: UInt32) -> Data {
        messageField(6, varintField(1, toDomain))
            + messageField(7, bytesField(2, routingAddress))
            + bytesField(10, payload)
            + messageField(13, signatureData)
            + bytesField(51, uuid)
            + varintField(52, UInt64(flags))
    }

    static func decodeSessionInfo(_ data: Data) throws -> TeslaBLESessionInfo {
        let fields = try decodeFields(data)
        return TeslaBLESessionInfo(
            counter: UInt32(truncatingIfNeeded: fields.varint(1) ?? 0),
            publicKey: fields.bytes(2) ?? Data(),
            epoch: fields.bytes(3) ?? Data(),
            clockTime: fields.fixed32(4) ?? 0,
            status: UInt32(truncatingIfNeeded: fields.varint(5) ?? 0)
        )
    }

    fileprivate static func decodeRoutableMessage(_ data: Data) throws -> TeslaBLEDecodedRoutableMessage {
        let fields = try decodeFields(data)
        let fromDomain = try fields.bytes(7).map { try decodeFields($0).varint(1) }.flatMap { $0 }
        let status = try fields.bytes(12).map { try decodeFields($0) }
        let fault = UInt32(truncatingIfNeeded: status?.varint(2) ?? 0)
        var sessionTag: Data?
        var responseSignature: (Data, UInt32, Data)?
        if let signatureBytes = fields.bytes(13) {
            let signature = try decodeFields(signatureBytes)
            if let session = signature.bytes(6) {
                sessionTag = try decodeFields(session).bytes(1)
            }
            if let response = signature.bytes(9) {
                let decoded = try decodeFields(response)
                if let nonce = decoded.bytes(1), let tag = decoded.bytes(3) {
                    responseSignature = (nonce, UInt32(truncatingIfNeeded: decoded.varint(2) ?? 0), tag)
                }
            }
        }
        return TeslaBLEDecodedRoutableMessage(fromDomain: fromDomain,
                                              payload: fields.bytes(10) ?? Data(),
                                              sessionInfo: fields.bytes(15),
                                              sessionInfoTag: sessionTag,
                                              responseSignature: responseSignature,
                                              requestUUID: fields.bytes(50),
                                              flags: UInt32(truncatingIfNeeded: fields.varint(52) ?? 0),
                                              fault: fault)
    }

    static func decodeDriveStateResponse(_ data: Data,
                                         vehicleID: String,
                                         date: Date = Date()) throws -> DriverBluetoothTelemetrySnapshot {
        let response = try decodeFields(data)
        if let actionStatus = response.bytes(1) {
            let status = try decodeFields(actionStatus)
            guard status.varint(1) ?? 0 == 0 else { throw DriverBluetoothError.protocolViolation }
        }
        guard let vehicleDataBytes = response.bytes(2) else { throw DriverBluetoothError.protocolViolation }
        let vehicleData = try decodeFields(vehicleDataBytes)
        guard let driveBytes = vehicleData.bytes(5) else { throw DriverBluetoothError.protocolViolation }
        let drive = try decodeFields(driveBytes)

        var shift: ShiftState?
        if let shiftBytes = drive.bytes(1), let field = try decodeFields(shiftBytes).all.first?.number {
            shift = switch field {
            case 2: .park
            case 3: .reverse
            case 4: .neutral
            case 5: .drive
            default: .unknown
            }
        }
        let speedMph: Double? = drive.fixed32(106).map { Double(Float(bitPattern: $0)) }
            ?? drive.varint(102).map(Double.init)
        let power = drive.varint(103).map { Double(Int32(bitPattern: UInt32(truncatingIfNeeded: $0))) }
        let odometer = drive.varint(105).map {
            Double(Int32(bitPattern: UInt32(truncatingIfNeeded: $0))) / 100 * 1.609344
        }
        return DriverBluetoothTelemetrySnapshot(vehicleID: vehicleID,
                                                date: date,
                                                speedKmh: speedMph.map { max(0, $0 * 1.609344) },
                                                powerKw: power,
                                                shiftState: shift,
                                                odometerKm: odometer)
    }

    static func sessionMaterial(from data: Data) throws -> (info: Data, tag: Data, challenge: Data?)? {
        let message = try decodeRoutableMessage(data)
        guard let info = message.sessionInfo, let tag = message.sessionInfoTag else { return nil }
        return (info, tag, message.requestUUID)
    }

    static func isAuthenticatedRoutableMessage(_ data: Data) -> Bool {
        guard let message = try? decodeRoutableMessage(data), message.fromDomain != nil else { return false }
        return message.sessionInfo != nil || message.responseSignature != nil
    }

    /// A timed-out request can still leave a valid response in CoreBluetooth's notification
    /// queue. Accepting that response for the next request used to fail UUID validation and
    /// unnecessarily tear down the whole BLE session. Match before decrypting so late or
    /// unrelated authenticated notifications are safely discarded.
    static func isDriveStateResponse(_ data: Data, matching requestUUID: Data) -> Bool {
        guard let message = try? decodeRoutableMessage(data) else { return false }
        return message.fromDomain == TeslaBLEDomain.infotainment.rawValue
            && message.requestUUID == requestUUID
            && (message.responseSignature != nil || !message.payload.isEmpty || message.fault != 0)
    }

    static func frame(_ message: Data) throws -> Data {
        guard message.count <= 1_024 else { throw DriverBluetoothError.protocolViolation }
        var length = UInt16(message.count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) } + message
    }

    static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    static func hmacSHA256(key: SymmetricKey, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // MARK: Minimal protobuf primitives

    private enum PBValue {
        case varint(UInt64)
        case fixed32(UInt32)
        case bytes(Data)
    }

    private struct PBField {
        let number: Int
        let value: PBValue
    }

    private struct PBFields {
        let all: [PBField]
        func varint(_ number: Int) -> UInt64? {
            all.last(where: { $0.number == number }).flatMap {
                if case .varint(let value) = $0.value { value } else { nil }
            }
        }
        func fixed32(_ number: Int) -> UInt32? {
            all.last(where: { $0.number == number }).flatMap {
                if case .fixed32(let value) = $0.value { value } else { nil }
            }
        }
        func bytes(_ number: Int) -> Data? {
            all.last(where: { $0.number == number }).flatMap {
                if case .bytes(let value) = $0.value { value } else { nil }
            }
        }
    }

    private static func decodeFields(_ data: Data) throws -> PBFields {
        var cursor = 0
        var result: [PBField] = []
        while cursor < data.count {
            let key = try readVarint(data, cursor: &cursor)
            let number = Int(key >> 3)
            guard number > 0 else { throw DriverBluetoothError.protocolViolation }
            switch key & 7 {
            case 0:
                result.append(PBField(number: number, value: .varint(try readVarint(data, cursor: &cursor))))
            case 1:
                guard cursor + 8 <= data.count else { throw DriverBluetoothError.protocolViolation }
                cursor += 8 // No required read-only field uses fixed64.
            case 2:
                let length = Int(try readVarint(data, cursor: &cursor))
                guard length >= 0, cursor + length <= data.count else { throw DriverBluetoothError.protocolViolation }
                result.append(PBField(number: number, value: .bytes(data.subdata(in: cursor..<(cursor + length)))))
                cursor += length
            case 5:
                guard cursor + 4 <= data.count else { throw DriverBluetoothError.protocolViolation }
                let bytes = data[cursor..<(cursor + 4)]
                let value = bytes.enumerated().reduce(UInt32(0)) { partial, item in
                    partial | (UInt32(item.element) << UInt32(item.offset * 8))
                }
                result.append(PBField(number: number, value: .fixed32(value)))
                cursor += 4
            default:
                throw DriverBluetoothError.protocolViolation
            }
        }
        return PBFields(all: result)
    }

    private static func readVarint(_ data: Data, cursor: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard cursor < data.count else { throw DriverBluetoothError.protocolViolation }
            let byte = data[cursor]
            cursor += 1
            result |= UInt64(byte & 0x7f) << UInt64(shift)
            if byte & 0x80 == 0 { return result }
        }
        throw DriverBluetoothError.protocolViolation
    }

    private static func varint(_ value: UInt64) -> Data {
        var value = value
        var result = Data()
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            result.append(byte)
        } while value != 0
        return result
    }

    private static func key(_ number: Int, _ wireType: UInt64) -> Data {
        varint(UInt64(number << 3) | wireType)
    }

    private static func varintField(_ number: Int, _ value: UInt64) -> Data {
        key(number, 0) + varint(value)
    }

    private static func fixed32Field(_ number: Int, _ value: UInt32) -> Data {
        var little = value.littleEndian
        return key(number, 5) + withUnsafeBytes(of: &little) { Data($0) }
    }

    private static func bytesField(_ number: Int, _ value: Data) -> Data {
        key(number, 2) + varint(UInt64(value.count)) + value
    }

    private static func messageField(_ number: Int, _ value: Data) -> Data { bytesField(number, value) }
}
