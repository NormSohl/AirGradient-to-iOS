import Foundation

/// A rolling per-monitor sample history, kept on disk.
///
/// The device itself keeps no history — `/measures/current` is exactly what its
/// name says — and the cloud's past-measures endpoint needs an account. So the
/// only history that always exists is the one this app records while it is
/// running, which is what the charts draw.
///
/// The history still has gaps whenever the app was not open. What it is no
/// longer is a "last day or so" view: samples age out of one-a-minute detail
/// into hourly averages, so a monitor left running accumulates a year of trend
/// without the file growing without bound. See `compact(_:now:)`.
@MainActor
final class HistoryStore {
    /// One sample a minute is plenty for a 24 h chart and keeps each file small
    /// enough to rewrite whole. Polling faster still updates the live tiles;
    /// it just doesn't append another point.
    private let minInterval: TimeInterval = 55

    /// How long samples keep full one-a-minute resolution. Past this they are
    /// averaged into hourly points: a chart weeks wide cannot draw minute
    /// detail anyway, and keeping it would cost a sample per minute forever.
    private let fineWindow: TimeInterval = 48 * 3600

    /// Hourly points are dropped past this age. A year of them is ~8,760
    /// samples per monitor — a few MB of JSON, small enough to keep whole.
    private let maxAge: TimeInterval = 365 * 24 * 3600

    /// Guard against a device clock jumping far forward, which would put every
    /// existing sample outside `fineWindow` and `maxAge` at once.
    private let hardCap = 20_000

    /// Longest unsaved samples may sit in memory. `flush()` on scene change is
    /// not enough for the case this app is actually used for: a kiosk iPad
    /// never backgrounds, so without a periodic write a crash or a power cut
    /// loses everything recorded since launch — which for an always-on display
    /// is the entire history.
    private let flushInterval: TimeInterval = 300
    private var lastFlush = Date()

    /// Compaction rewrites the whole series, which at a year of history is tens
    /// of milliseconds — cheap hourly, but not something to do on every append
    /// once a minute, on the main actor, behind a display that is always being
    /// looked at. Nothing is lost by waiting: rolling up only changes anything
    /// when a whole hour ages out of `fineWindow`.
    private let compactInterval: TimeInterval = 600
    private var lastCompaction = Date.distantPast

    private var samples: [UUID: [Reading]] = [:]
    private var dirty: Set<UUID> = []

    private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("History", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func history(for id: UUID) -> [Reading] {
        if let s = samples[id] { return s }
        // Compact on load as well as on append: a file written by an older
        // build, or one left by a long gap in use, should shrink on first read
        // rather than only after the next sample arrives.
        let loaded = compact(load(id), now: Date())
        samples[id] = loaded
        return loaded
    }

    /// Appends unless the previous sample is too recent. Returns whether the
    /// series actually grew, so callers can avoid redrawing a chart for nothing.
    @discardableResult
    func record(_ reading: Reading, for id: UUID) -> Bool {
        var series = history(for: id)
        if let last = series.last, reading.timestamp.timeIntervalSince(last.timestamp) < minInterval {
            return false
        }
        series.append(reading)
        if reading.timestamp.timeIntervalSince(lastCompaction) >= compactInterval || series.count > hardCap {
            lastCompaction = reading.timestamp
            series = compact(series, now: reading.timestamp)
        }
        samples[id] = series
        dirty.insert(id)
        flushIfStale()
        return true
    }

    func forget(_ id: UUID) {
        samples[id] = nil
        dirty.remove(id)
        try? FileManager.default.removeItem(at: fileURL(id))
    }

    /// Synchronous, and called on background/quit, where a detached write may
    /// not survive suspension.
    func flush() {
        for id in dirty {
            guard let series = samples[id] else { continue }
            write(series, to: fileURL(id))
        }
        dirty.removeAll()
        lastFlush = Date()
    }

    // MARK: - Periodic saving

    private func flushIfStale() {
        guard Date().timeIntervalSince(lastFlush) >= flushInterval else { return }
        lastFlush = Date()

        // Snapshot on the main actor, then encode and write off it. A year of
        // hourly samples is a few MB, and re-encoding that every five minutes
        // on the main thread would be visible as a stutter on a display that
        // is never not being looked at.
        let pending = dirty.compactMap { id -> (URL, [Reading])? in
            guard let series = samples[id] else { return nil }
            return (fileURL(id), series)
        }
        dirty.removeAll()

        Task.detached(priority: .utility) {
            for (url, series) in pending {
                guard let data = try? JSONEncoder().encode(series) else { continue }
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func write(_ series: [Reading], to url: URL) {
        guard let data = try? JSONEncoder().encode(series) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Retention

    /// Ages a series: recent samples keep minute resolution, older ones are
    /// averaged into one point per hour, and anything past `maxAge` is dropped.
    ///
    /// Idempotent — a bucket that already holds a single rolled-up point
    /// averages to itself — so it is safe to run on every append.
    private func compact(_ series: [Reading], now: Date) -> [Reading] {
        guard !series.isEmpty else { return series }

        let ageLimit = now.addingTimeInterval(-maxAge)
        let fineLimit = now.addingTimeInterval(-fineWindow)

        var kept = series.filter { $0.timestamp >= ageLimit }
        if kept.isEmpty { return [] }

        let fine = kept.filter { $0.timestamp >= fineLimit }
        let old = kept.filter { $0.timestamp < fineLimit }
        guard !old.isEmpty else {
            if kept.count > hardCap { kept.removeFirst(kept.count - hardCap) }
            return kept
        }

        var buckets: [Date: [Reading]] = [:]
        for reading in old {
            buckets[Self.hourStart(of: reading.timestamp), default: []].append(reading)
        }

        var result = buckets.keys.sorted().map { hour in
            averaged(buckets[hour] ?? [], at: hour)
        }
        result.append(contentsOf: fine)
        if result.count > hardCap { result.removeFirst(result.count - hardCap) }
        return result
    }

    private static func hourStart(of date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / 3600).rounded(.down) * 3600)
    }

    /// Mean of one hour's samples.
    ///
    /// A field is averaged over the samples that actually reported it, and is
    /// left nil when none did. Averaging a missing sensor as zero would be the
    /// same lie the tiles refuse to tell: a dead CO₂ sensor must not become an
    /// hour of exceptionally clean air.
    private func averaged(_ group: [Reading], at timestamp: Date) -> Reading {
        func mean(_ values: [Double?]) -> Double? {
            let present = values.compactMap { $0 }
            guard !present.isEmpty else { return nil }
            return present.reduce(0, +) / Double(present.count)
        }

        var out = Reading(timestamp: timestamp)
        out.pm01 = mean(group.map(\.pm01))
        out.pm02 = mean(group.map(\.pm02))
        out.pm10 = mean(group.map(\.pm10))
        out.pm02Compensated = mean(group.map(\.pm02Compensated))
        out.pm003Count = mean(group.map(\.pm003Count))
        out.rco2 = mean(group.map(\.rco2))
        out.atmp = mean(group.map(\.atmp))
        out.atmpCompensated = mean(group.map(\.atmpCompensated))
        out.rhum = mean(group.map(\.rhum))
        out.rhumCompensated = mean(group.map(\.rhumCompensated))
        out.tvocIndex = mean(group.map(\.tvocIndex))
        out.noxIndex = mean(group.map(\.noxIndex))
        out.tvocRaw = mean(group.map(\.tvocRaw))
        out.noxRaw = mean(group.map(\.noxRaw))
        out.wifi = mean(group.map(\.wifi))

        // Identity, not measurement: carry the most recent sample's, so a
        // firmware upgrade mid-hour reports the version the hour ended on.
        let last = group.last
        out.serialno = last?.serialno
        out.firmware = last?.firmware
        out.model = last?.model
        out.locationId = last?.locationId
        out.locationName = last?.locationName
        return out
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func load(_ id: UUID) -> [Reading] {
        guard let data = try? Data(contentsOf: fileURL(id)) else { return [] }
        return (try? JSONDecoder().decode([Reading].self, from: data)) ?? []
    }
}
