import XCTest
@testable import Tesstats

@MainActor
final class FunctionAuditTests: XCTestCase {
    func testServerCachesDoNotMixSameCarAndRecordIDsAndClearAllIncludesScopes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = CacheStore(directory: directory)
        var a = ServerConfig()
        a.apiBaseURL = "https://a.invalid/api"
        var b = a
        b.apiBaseURL = "https://b.invalid/api"
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let dto = try decoder.decode(ChargeDTO.self, from: Data(#"{"charge_id":1,"start_date":"2026-07-10T10:00:00Z","charge_energy_added":10}"#.utf8))
        let first = try XCTUnwrap(dto.toDomain(index: 1))
        var second = first
        second.energyAddedKwh = 20
        root.scoped(to: a).saveCharges([first], carID: 1)
        root.scoped(to: b).saveCharges([second], carID: 1)
        XCTAssertEqual(root.scoped(to: a).loadCharges(carID: 1).first?.energyAddedKwh, 10)
        XCTAssertEqual(root.scoped(to: b).loadCharges(carID: 1).first?.energyAddedKwh, 20)
        XCTAssertGreaterThan(root.sizeBytes(), 0)
        root.clearAll()
        XCTAssertTrue(root.scoped(to: a).loadCharges(carID: 1).isEmpty)
        XCTAssertTrue(root.scoped(to: b).loadCharges(carID: 1).isEmpty)
        XCTAssertEqual(root.sizeBytes(), 0)
    }

    func testCacheIdentitySeparatesDemoButRetainsSourceAcrossDisplayPreferences() {
        var config = ServerConfig()
        config.apiBaseURL = "https://a.invalid/api"
        let original = config.historySourceIdentity
        config.selectedCarID = 2
        config.units = .imperial
        config.chargePricePerKwh = 0.5
        XCTAssertEqual(config.historySourceIdentity, original)
        config.demoMode = true
        XCTAssertNotEqual(config.historySourceIdentity, original)
    }

    func testProfilesPersistInTheSettingsStoresOwnDefaults() throws {
        let suite = "FunctionAuditTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, keychain: KeychainStore(service: suite))
        settings.config.apiBaseURL = "https://a.invalid/api"
        settings.saveCurrentAsProfile(name: "Audit")
        let id = try XCTUnwrap(settings.activeProfileID)
        defer { settings.deleteProfile(id) }
        settings.renameProfile(id, to: "Renamed")
        let restored = SettingsStore(defaults: defaults, keychain: KeychainStore(service: suite))
        XCTAssertEqual(restored.activeProfileID, id)
        XCTAssertEqual(restored.profiles.first?.name, "Renamed")
        XCTAssertEqual(restored.profiles.first?.config.apiBaseURL, "https://a.invalid/api")
        settings.deleteProfile(id)
        XCTAssertTrue(SettingsStore(defaults: defaults).profiles.isEmpty)
        XCTAssertNil(SettingsStore(defaults: defaults).activeProfileID)
    }

    func testMQTTParserReassemblesFragmentedPacketsAndHandlesCoalescedPackets() {
        let topic = Array("teslamate/cars/1/battery_level".utf8)
        let body = [UInt8(topic.count >> 8), UInt8(topic.count & 255)] + topic + Array("72".utf8)
        let packet = [UInt8(0x30)] + MQTTEncoder.remainingLength(body.count) + body
        let parser = MQTTByteParser()
        for byte in packet.dropLast() {
            parser.append(Data([byte]))
            XCTAssertNil(parser.next())
        }
        parser.append(Data([packet.last!] + [0xD0, 0x00]))
        guard case .publish(let publish, let qos, let packetID) = parser.next() else { return XCTFail("Missing complete packet") }
        XCTAssertEqual(publish.topic, "teslamate/cars/1/battery_level")
        XCTAssertEqual(publish.payload, "72")
        XCTAssertEqual(qos, 0)
        XCTAssertNil(packetID)
        guard case .pingResp = parser.next() else { return XCTFail("Missing coalesced ping response") }
        XCTAssertNil(parser.next())
    }

    func testMQTTQosOnePacketRetainsIdentifierForAcknowledgment() {
        let parser = MQTTByteParser()
        parser.append(Data([0x32, 0x07, 0x00, 0x01, 0x61, 0x12, 0x34, 0x6F, 0x6B]))
        guard case .publish(let publish, let qos, let packetID) = parser.next() else { return XCTFail("Missing QoS1 packet") }
        XCTAssertEqual(publish.payload, "ok")
        XCTAssertEqual(qos, 1)
        XCTAssertEqual(packetID, 0x1234)
        XCTAssertEqual(MQTTEncoder.puback(packetID: 0x1234), Data([0x40, 0x02, 0x12, 0x34]))
    }

    func testTripTagsMigrateOnceAndRemainIsolatedAcrossServers() {
        let suite = "FunctionAuditTags-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TripTagStore(defaults: defaults)
        store.setTag(.work, for: 1)
        store.scope(to: "server-a")
        XCTAssertEqual(store.tag(for: 1), .work)
        store.scope(to: "server-b")
        XCTAssertNil(store.tag(for: 1))
        store.setTag(.personal, for: 1)
        store.scope(to: "server-a")
        XCTAssertEqual(store.tag(for: 1), .work)
        let restored = TripTagStore(defaults: defaults)
        restored.scope(to: "server-b")
        XCTAssertEqual(restored.tag(for: 1), .personal)
        restored.clear()
        restored.scope(to: "server-a")
        XCTAssertNil(restored.tag(for: 1))
    }
}
