import XCTest
@testable import Tesstats

@MainActor
final class HistoryViewModelTests: XCTestCase {

    private func makeSettings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "HistoryViewModelTests-\(UUID().uuidString)")!)
    }

    /// After a failed load, switching back to a view (loadIfNeeded) must retry
    /// instead of staying stuck on the error until a manual refresh.
    func testLoadIfNeededRetriesAfterFailure() async {
        let settings = makeSettings()
        // http:// + insecure not allowed → the request throws immediately (no network).
        settings.config.apiBaseURL = "http://127.0.0.1:1"
        settings.config.allowInsecureTransport = false

        let vm = HistoryViewModel(settings: settings, cache: CacheStore())
        let carID = 987_654  // no cached history for this id

        await vm.loadIfNeeded(carID: carID)
        guard case .failed = vm.phase else {
            return XCTFail("Expected .failed, got \(vm.phase)")
        }

        // Recovery path: configuration now works (demo mode). loadIfNeeded must retry.
        settings.config.demoMode = true
        await vm.loadIfNeeded(carID: carID)
        XCTAssertEqual(vm.phase, .loaded)
        XCTAssertFalse(vm.drives.isEmpty)
    }

    /// A successful load must NOT be repeated by loadIfNeeded for the same car.
    func testLoadIfNeededDoesNotReloadWhenAlreadyLoaded() async {
        let settings = makeSettings()
        settings.config.demoMode = true

        let vm = HistoryViewModel(settings: settings, cache: CacheStore())
        await vm.loadIfNeeded(carID: 1)
        XCTAssertEqual(vm.phase, .loaded)
        let first = vm.drives.count

        await vm.loadIfNeeded(carID: 1)
        XCTAssertEqual(vm.drives.count, first)
        XCTAssertEqual(vm.phase, .loaded)
    }

    func testChangingCarClearsPreviousVehicleHistoryWithoutAPI() async {
        let settings = makeSettings()
        settings.config.demoMode = true
        let vm = HistoryViewModel(settings: settings, cache: CacheStore())
        await vm.loadIfNeeded(carID: 1)
        XCTAssertTrue(vm.hasData)
        settings.config.demoMode = false
        await vm.loadIfNeeded(carID: 2_000_001)
        XCTAssertFalse(vm.hasData)
        XCTAssertNil(vm.carInfo)
        guard case .empty = vm.phase else { return XCTFail("Expected empty history for new vehicle") }
    }

    func testChangingCarDuringLoadDoesNotJoinPreviousVehicleRequest() async {
        let settings = makeSettings()
        settings.config.demoMode = true
        let vm = HistoryViewModel(settings: settings, cache: CacheStore())
        let old = Task { await vm.loadIfNeeded(carID: 1) }
        // The first load yields while deriving the demo history off the main actor.
        while !vm.isRefreshing { await Task.yield() }
        settings.config.demoMode = false
        await vm.loadIfNeeded(carID: 2_000_002)
        await old.value
        XCTAssertFalse(vm.hasData)
        XCTAssertNil(vm.carInfo)
        guard case .empty = vm.phase else { return XCTFail("New vehicle must own the final phase") }
    }
}
