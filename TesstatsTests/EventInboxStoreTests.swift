import XCTest
@testable import Tesstats

@MainActor
final class EventInboxStoreTests: XCTestCase {
    func testInboxPersistsGroupsFiltersAndClears() {
        let defaults = UserDefaults(suiteName: "EventInboxStoreTests-\(UUID().uuidString)")!
        let store = EventInboxStore(defaults: defaults, key: "events")

        store.add(category: .vehicle, title: "Charging complete", body: "Done", symbol: "bolt.fill")
        store.add(category: .tesstats, title: "Welcome", body: "Hello", symbol: "sparkles")

        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.grouped(category: .vehicle).first?.items.count, 1)

        let reloaded = EventInboxStore(defaults: defaults, key: "events")
        XCTAssertEqual(reloaded.items.count, 2)

        reloaded.clear()
        XCTAssertTrue(reloaded.items.isEmpty)
    }
}
