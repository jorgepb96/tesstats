import XCTest
@testable import Tesstats

@MainActor
final class DriverBluetoothTests: XCTestCase {
    func testVINNormalizationRejectsAmbiguousOrMalformedValues() {
        XCTAssertEqual(DriverBluetoothIdentity.normalizedVIN(" 5yj3e1ea7kf000000 "), "5YJ3E1EA7KF000000")
        XCTAssertNil(DriverBluetoothIdentity.normalizedVIN("5YJ3E1EA7KF00000"))
        XCTAssertNil(DriverBluetoothIdentity.normalizedVIN("5YJ3E1EA7OF000000"))
        XCTAssertNil(DriverBluetoothIdentity.normalizedVIN("5YJ3E1EA7KF00000!"))
    }

    func testTeslaAdvertisementNameMatchesOfficialVehicleCommandExample() {
        XCTAssertEqual(TeslaBLEWire.vehicleLocalName(vin: "5YJS0000000000000"),
                       "S1a87a5a75f3df858C")
    }

    func testTeslaAdvertisementMatcherSelectsOnlyTheVINDerivedVehicle() {
        let selected = TeslaBLEWire.vehicleLocalName(vin: "5YJS0000000000000")
        let other = TeslaBLEWire.vehicleLocalName(vin: "7SAYGDEE9PF000001")

        XCTAssertTrue(TeslaBLEAdvertisementMatcher.matches(expectedLocalName: selected,
                                                            advertisedLocalName: selected,
                                                            peripheralName: nil))
        XCTAssertTrue(TeslaBLEAdvertisementMatcher.matches(expectedLocalName: selected,
                                                            advertisedLocalName: nil,
                                                            peripheralName: selected))
        XCTAssertFalse(TeslaBLEAdvertisementMatcher.matches(expectedLocalName: selected,
                                                             advertisedLocalName: other,
                                                             peripheralName: other))
        XCTAssertFalse(TeslaBLEAdvertisementMatcher.matches(expectedLocalName: selected,
                                                             advertisedLocalName: nil,
                                                             peripheralName: nil))
    }

    func testReadOnlyDriveStateEncoderMatchesPinnedWireShape() {
        XCTAssertEqual(TeslaBLEWire.encode(.readDriveState).hex,
                       "12040a022200")
    }

    func testEnrollmentHardCodesVehicleMonitorAndIOSDevice() {
        let publicKey = Data([0x04] + Array(repeating: 0x11, count: 64))
        let encoded = TeslaBLEWire.encode(.enrollVehicleMonitor(publicKey: publicKey))

        XCTAssertEqual(encoded.prefix(2).hex, "0a54")
        XCTAssertTrue(encoded.hex.contains("2005"), "Role must be ROLE_VEHICLE_MONITOR (5)")
        XCTAssertTrue(encoded.hex.contains("32020806"), "Form factor must be IOS_DEVICE (6)")
        XCTAssertEqual(encoded.count, 86)
    }

    func testRoutableFilterRejectsArbitraryNotificationsAndKeepsAuthenticatedSessionInfo() throws {
        XCTAssertFalse(TeslaBLEWire.isAuthenticatedRoutableMessage(Data(repeating: 0x7f, count: 80)))

        let sessionInfo = Data([0x08, 0x01])
        let tag = Data(repeating: 0xaa, count: 32)
        let challenge = Data(repeating: 0xbb, count: 16)
        let sourceDomain = message(7, varintField(1, 3))
        let signature = message(13, message(6, message(1, tag)))
        let envelope = sourceDomain + message(15, sessionInfo) + signature + message(50, challenge)

        XCTAssertTrue(TeslaBLEWire.isAuthenticatedRoutableMessage(envelope))
        let material = try XCTUnwrap(TeslaBLEWire.sessionMaterial(from: envelope))
        XCTAssertEqual(material.info, sessionInfo)
        XCTAssertEqual(material.tag, tag)
        XCTAssertEqual(material.challenge, challenge)
    }

    func testDriveStateResponseMatcherRejectsLateResponseFromPreviousRequest() {
        let currentRequest = Data(repeating: 0x11, count: 16)
        let previousRequest = Data(repeating: 0x22, count: 16)
        let nonce = Data(repeating: 0x33, count: 12)
        let tag = Data(repeating: 0x44, count: 16)
        let sourceDomain = message(7, varintField(1, 3))
        let responseSignature = message(13, message(9,
            message(1, nonce) + varintField(2, 7) + message(3, tag)
        ))
        let response = sourceDomain + message(10, Data([0xaa]))
            + responseSignature + message(50, currentRequest)

        XCTAssertTrue(TeslaBLEWire.isDriveStateResponse(response, matching: currentRequest))
        XCTAssertFalse(TeslaBLEWire.isDriveStateResponse(response, matching: previousRequest))
        XCTAssertFalse(TeslaBLEWire.isDriveStateResponse(Data(repeating: 0xff, count: 32),
                                                         matching: currentRequest))

        let plaintextResponse = sourceDomain + message(10, Data([0x12, 0x00]))
            + message(50, currentRequest)
        XCTAssertTrue(TeslaBLEWire.isDriveStateResponse(plaintextResponse,
                                                        matching: currentRequest),
                      "Tesla firmware predating encrypted replies returns a plaintext payload")
    }

    func testDriveStateDecoderConvertsMilesAndKeepsSignedPower() throws {
        let shiftDrive = message(1, message(5, Data()))
        let speedFloat = fixed32(106, Float(72).bitPattern)
        let power = varintField(103, UInt64(UInt32(bitPattern: Int32(-18))))
        let odometerHundredthsMiles = varintField(105, 1_000_000)
        let drive = shiftDrive + speedFloat + power + odometerHundredthsMiles
        let response = message(2, message(5, drive))

        let decoded = try TeslaBLEWire.decodeDriveStateResponse(response, vehicleID: "vehicle")

        XCTAssertEqual(decoded.shiftState, .drive)
        XCTAssertEqual(decoded.speedKmh ?? 0, 72 * 1.609344, accuracy: 0.0001)
        XCTAssertEqual(decoded.powerKw, -18)
        XCTAssertEqual(decoded.odometerKm ?? 0, 10_000 * 1.609344, accuracy: 0.001)
    }

    func testPreferencesAreIsolatedByVehicleAndReuseVINAcrossProfiles() {
        let suite = "DriverBluetoothTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DriverBluetoothPreferencesStore(defaults: defaults)
        let first = DriverBluetoothIdentity.identifier(forVIN: "5YJ3E1EA7KF000000")
        let second = DriverBluetoothIdentity.identifier(forVIN: "7SAYGDEE9PF000001")

        store.remember(vehicleID: first, carID: 1, scopeID: "home")
        store.remember(vehicleID: first, carID: 42, scopeID: "remote")
        store.remember(vehicleID: second, carID: 2, scopeID: "home")
        store.setEnabled(true, vehicleID: first)

        XCTAssertEqual(store.vehicleID(carID: 1, scopeID: "home"), first)
        XCTAssertEqual(store.vehicleID(carID: 42, scopeID: "remote"), first)
        XCTAssertEqual(store.vehicleID(carID: 2, scopeID: "home"), second)
        XCTAssertTrue(store.isEnabled(vehicleID: first))
        XCTAssertFalse(store.isEnabled(vehicleID: second))

        store.delete(vehicleID: first)
        XCTAssertNil(store.vehicleID(carID: 1, scopeID: "home"))
        XCTAssertNil(store.vehicleID(carID: 42, scopeID: "remote"))
        XCTAssertEqual(store.vehicleID(carID: 2, scopeID: "home"), second)
    }

    func testSpeedFusionPrefersFreshBluetoothAndFallsBackWhenStale() {
        let now = Date(timeIntervalSince1970: 10_000)
        let bluetooth = DriverSpeedSample(speedKmh: 91, date: now.addingTimeInterval(-0.4),
                                          source: .vehicleBluetooth, accuracyKmh: nil)
        let phone = DriverSpeedSample(speedKmh: 88, date: now.addingTimeInterval(-0.2),
                                      source: .iphoneGPS, accuracyKmh: 1)
        let teslaMate = DriverSpeedSample(speedKmh: 84, date: now.addingTimeInterval(-0.1),
                                          source: .teslaMate, accuracyKmh: nil)

        XCTAssertEqual(DriverSpeedFusion.resolve(bluetooth: bluetooth, phone: phone,
                                                 teslaMate: teslaMate, at: now)?.source,
                       .vehicleBluetooth)

        let stale = DriverSpeedSample(
            speedKmh: 91,
            date: now.addingTimeInterval(-(DriverSpeedFusion.bluetoothMaximumAge + 0.05)),
                                      source: .vehicleBluetooth, accuracyKmh: nil)
        XCTAssertEqual(DriverSpeedFusion.resolve(bluetooth: stale, phone: phone,
                                                 teslaMate: teslaMate, at: now)?.source,
                       .iphoneGPS)
    }

    func testBluetoothStabilityUsesHysteresisAndDoesNotReconnectOnBriefDelay() {
        var health = DriverBluetoothTelemetryStability()

        for _ in 0..<(DriverBluetoothLinkPolicy.responsesRequiredForStableTelemetry - 1) {
            health.recordResponse()
            XCTAssertFalse(health.isStable)
        }
        health.recordResponse()
        XCTAssertTrue(health.isStable)

        XCTAssertFalse(health.recordTimeout())
        XCTAssertTrue(health.isStable, "One delayed reply must not make Auto mode flicker")

        for _ in 1..<(DriverBluetoothLinkPolicy.timeoutsBeforeSessionReconnect - 1) {
            XCTAssertFalse(health.recordTimeout())
        }
        XCTAssertTrue(health.recordTimeout())
        XCTAssertFalse(health.isStable)

        health.recordResponse()
        XCTAssertEqual(health.consecutiveTimeouts, 0)
        XCTAssertFalse(health.isStable)
    }

    func testVehicleFaultsPreserveLinkOrRefreshOnlyTheSecureSession() {
        XCTAssertNil(TeslaBLEWire.error(forMessageFault: 0))
        XCTAssertEqual(TeslaBLEWire.error(forMessageFault: 1), .temporaryVehicleFault(1))
        XCTAssertEqual(TeslaBLEWire.error(forMessageFault: 2), .temporaryVehicleFault(2))
        XCTAssertEqual(TeslaBLEWire.error(forMessageFault: 11), .temporaryVehicleFault(11))
        XCTAssertEqual(TeslaBLEWire.error(forMessageFault: 6), .sessionOutOfSync)
        XCTAssertEqual(TeslaBLEWire.error(forMessageFault: 26), .sessionOutOfSync)
        XCTAssertEqual(TeslaBLEWire.error(forMessageFault: 25), .responseTooLarge)
        XCTAssertEqual(TeslaBLEWire.error(forMessageFault: 3), .keyRejected)
        XCTAssertEqual(TeslaBLEWire.error(forMessageFault: 7), .keyRejected)
        XCTAssertEqual(TeslaBLEWire.error(forMessageFault: 14), .connectionLimitReached)
        XCTAssertEqual(TeslaBLEWire.error(forMessageFault: 999), .protocolViolation)
    }

    // Test-only protobuf primitives keep the expected wire representation independent from the
    // production encoder and exercise the production decoder with high field numbers.
    private func message(_ number: Int, _ value: Data) -> Data {
        key(number, wire: 2) + varint(UInt64(value.count)) + value
    }

    private func varintField(_ number: Int, _ value: UInt64) -> Data {
        key(number, wire: 0) + varint(value)
    }

    private func fixed32(_ number: Int, _ value: UInt32) -> Data {
        var little = value.littleEndian
        return key(number, wire: 5) + withUnsafeBytes(of: &little) { Data($0) }
    }

    private func key(_ number: Int, wire: UInt64) -> Data {
        varint(UInt64(number << 3) | wire)
    }

    private func varint(_ initial: UInt64) -> Data {
        var value = initial
        var data = Data()
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            data.append(byte)
        } while value != 0
        return data
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
