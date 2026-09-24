import Foundation

/// Which slices of a cloud monitor's past to ask AirGradient for.
///
/// `/measures/past` refuses any `from … to` wider than 10 days (422), so a
/// year of history is dozens of requests. Asking for it all on every refresh,
/// as the week-long window this replaced did, is not an option. Instead:
///
/// - **Catch up** from just before the newest stored point to now. Once
///   caught up that is an hour or so of buckets every ten minutes.
/// - **Backfill** backwards from `floor` — the oldest point already stored —
///   one chunk at a time, until a year is covered or the monitor evidently
///   didn't exist yet.
///
/// Every boundary is on a whole hour. Past 48 h the store keeps hourly
/// averages, and `HistoryStore.merge` replaces exactly the span it was given;
/// a boundary mid-hour would leave an old hourly average and fresh buckets
/// for the same hour side by side, and the next compaction would average the
/// average in with them.
enum CloudHistoryPlan {
    /// Under the API's 10-day limit with room to spare: the spec doesn't say
    /// whether exactly ten days is accepted, and a 422 costs the whole chunk.
    static let chunk: TimeInterval = 9 * 24 * 3600

    /// As far back as backfill goes — the same age `HistoryStore` drops at.
    static let reach: TimeInterval = 365 * 24 * 3600

    /// Consecutive empty chunks after which backfill decides the monitor
    /// hadn't been set up yet. Four weeks of nothing is a monitor that didn't
    /// exist, not one that was unplugged over a weekend.
    static let emptyChunksToStop = 3

    /// Slices from shortly before `newest` up to `now`, oldest first.
    ///
    /// Starts an hour early so a bucket the cloud finalised late is picked up
    /// on the next pass. With nothing stored, starts one chunk back and leaves
    /// the rest to backfill. After a long absence this is several slices, so
    /// the stretch the app wasn't running is filled rather than left as a hole
    /// backfill would never reach — backfill only ever walks backwards.
    static func catchUp(newest: Date?, now: Date) -> [DateInterval] {
        let earliest = hourStart(now.addingTimeInterval(-reach))
        let start: Date
        if let newest {
            start = max(hourStart(newest).addingTimeInterval(-3600), earliest)
        } else {
            // An hour inside one chunk: rounding down to the hour would make
            // it a chunk and a bit, and cost a second request for the bit.
            start = hourStart(now.addingTimeInterval(-chunk)).addingTimeInterval(3600)
        }
        return slices(from: start, to: now)
    }

    /// The next slice back from `floor`, or nil once a year is covered.
    static func backfill(floor: Date, now: Date) -> DateInterval? {
        let earliest = hourStart(now.addingTimeInterval(-reach))
        guard floor > earliest else { return nil }
        let start = max(hourStart(floor.addingTimeInterval(-chunk)), earliest)
        return DateInterval(start: start, end: floor)
    }

    /// `from … to` cut into chunks no wider than `chunk`, oldest first.
    static func slices(from start: Date, to end: Date) -> [DateInterval] {
        var out: [DateInterval] = []
        var s = start
        while s < end {
            let e = min(s.addingTimeInterval(chunk), end)
            out.append(DateInterval(start: s, end: e))
            s = e
        }
        return out
    }

    static func hourStart(_ date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / 3600).rounded(.down) * 3600)
    }
}
