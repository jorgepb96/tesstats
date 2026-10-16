import Foundation

/// Pure helpers for incremental history sync. TeslaMate never rewrites past drives —
/// so once a page of results overlaps what's already cached, pagination can stop and
/// the fresh records are merged over the cached ones (fetched wins on ID collision).
enum HistorySync {

    /// Merge freshly fetched records over the cached set. On an ID collision the fetched
    /// record wins (it may carry an updated end date or cost). Result is newest-first.
    static func merge<T: Identifiable>(fetched: [T], cached: [T], date: (T) -> Date) -> [T] {
        var byID: [T.ID: T] = [:]
        byID.reserveCapacity(fetched.count + cached.count)
        for c in cached { byID[c.id] = c }
        for f in fetched { byID[f.id] = f }
        return byID.values.sorted { date($0) > date($1) }
    }

    /// True when a newest-first page already overlaps the cached history — everything after
    /// it is older than what we have, so pagination can stop.
    static func reachedCachedHistory(batchIDs: [Int], newestCachedID: Int?) -> Bool {
        guard let newestCachedID, let minID = batchIDs.min() else { return false }
        return minID <= newestCachedID
    }

    /// Detect newest-first ordering from a page's dates. Early-stop is only safe when the
    /// server paginates newest-first; otherwise the caller falls back to a full fetch.
    static func isNewestFirst(dates: [Date]) -> Bool {
        guard dates.count >= 2 else { return false }
        return zip(dates, dates.dropFirst()).allSatisfy { $0 >= $1 }
    }
}
