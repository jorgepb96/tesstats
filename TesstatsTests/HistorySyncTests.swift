import XCTest
@testable import Tesstats

final class HistorySyncTests: XCTestCase {

    private struct Record: Identifiable, Equatable {
        let id: Int
        let date: Date
        var payload: String = ""
    }

    private func rec(_ id: Int, _ t: TimeInterval, _ payload: String = "") -> Record {
        Record(id: id, date: Date(timeIntervalSince1970: t), payload: payload)
    }

    func testMergePrefersFetchedAndSortsNewestFirst() {
        let cached = [rec(1, 100, "old"), rec(2, 200, "old")]
        let fetched = [rec(2, 200, "updated"), rec(3, 300, "new")]

        let merged = HistorySync.merge(fetched: fetched, cached: cached) { $0.date }

        XCTAssertEqual(merged.map(\.id), [3, 2, 1])
        XCTAssertEqual(merged.first { $0.id == 2 }?.payload, "updated")
    }

    func testMergeWithEmptyCacheEqualsFetchedSorted() {
        let fetched = [rec(1, 100), rec(3, 300), rec(2, 200)]
        let merged = HistorySync.merge(fetched: fetched, cached: []) { $0.date }
        XCTAssertEqual(merged.map(\.id), [3, 2, 1])
    }

    func testReachedCachedHistoryStopsOnOverlapOnly() {
        // Page still strictly newer than the cache → keep paging.
        XCTAssertFalse(HistorySync.reachedCachedHistory(batchIDs: [120, 119, 118], newestCachedID: 100))
        // Page overlaps the cached head → stop.
        XCTAssertTrue(HistorySync.reachedCachedHistory(batchIDs: [101, 100, 99], newestCachedID: 100))
        // No cache → never stop early.
        XCTAssertFalse(HistorySync.reachedCachedHistory(batchIDs: [10, 9], newestCachedID: nil))
        // Empty page → nothing to conclude.
        XCTAssertFalse(HistorySync.reachedCachedHistory(batchIDs: [], newestCachedID: 100))
    }

    func testIsNewestFirstDetection() {
        let newer = Date(timeIntervalSince1970: 2000)
        let older = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(HistorySync.isNewestFirst(dates: [newer, older]))
        XCTAssertFalse(HistorySync.isNewestFirst(dates: [older, newer]))
        // A single sample can't establish an order → not safe to stop early.
        XCTAssertFalse(HistorySync.isNewestFirst(dates: [newer]))
        XCTAssertFalse(HistorySync.isNewestFirst(dates: []))
    }
}
