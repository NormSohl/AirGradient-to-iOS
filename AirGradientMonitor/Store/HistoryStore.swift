import Foundation

/// A rolling per-monitor sample history, kept on disk.
///
/// The device itself keeps no history — `/measures/current` is exactly what its
/// name says — and the cloud's past-measures endpoint needs an account. So the
/// only history that always exists is the one this app records while it is
/// running, which is what the charts draw.
///
/// Two consequences worth stating plainly rather than discovering from an odd
/// chart: the history has gaps whenever the app was not open, and it is capped,
/// so it is a "last day or so" view, not an archive.
@MainActor
final class HistoryStore {
    /// One sample a minute is plenty for a 24 h chart and keeps each file small
    /// enough to rewrite whole. Polling faster still updates the live tiles;
    /// it just doesn't append another point.
    private let minInterval: TimeInterval = 55
    private let maxSamples = 1500

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
        let loaded = load(id)
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
        if series.count > maxSamples { series.removeFirst(series.count - maxSamples) }
        samples[id] = series
        dirty.insert(id)
        return true
    }

    func forget(_ id: UUID) {
        samples[id] = nil
        dirty.remove(id)
        try? FileManager.default.removeItem(at: fileURL(id))
    }

    /// Called on background/quit rather than on every append: a 1500-element
    /// rewrite per sample is wasteful, and losing the last minute of an
    /// in-memory series to a crash costs one chart point.
    func flush() {
        for id in dirty {
            guard let series = samples[id] else { continue }
            if let data = try? JSONEncoder().encode(series) {
                try? data.write(to: fileURL(id), options: .atomic)
            }
        }
        dirty.removeAll()
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func load(_ id: UUID) -> [Reading] {
        guard let data = try? Data(contentsOf: fileURL(id)) else { return [] }
        return (try? JSONDecoder().decode([Reading].self, from: data)) ?? []
    }
}
