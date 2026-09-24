import Foundation
import Observation

/// The app's single source of truth: which monitors exist, their latest
/// reading, and the polling loop that keeps those fresh.
@MainActor
@Observable
final class MonitorsModel {
    /// Per-monitor liveness. `.failed` deliberately keeps the last reading in
    /// `latest` — a monitor that stopped answering thirty seconds ago should
    /// show its last values dimmed, with the time they were taken, not blank
    /// tiles.
    enum Status: Equatable {
        case idle
        case loading
        case ok(Date)
        case failed(String, Date)

        var errorText: String? { if case .failed(let m, _) = self { return m }; return nil }
        var lastUpdate: Date? {
            switch self {
            case .ok(let d), .failed(_, let d): d
            default: nil
            }
        }
    }

    private(set) var monitors: [Monitor] = []
    private(set) var latest: [UUID: Reading] = [:]
    private(set) var status: [UUID: Status] = [:]

    /// Plain stored property: `@Observable` rewrites stored properties into
    /// accessors, so a `didSet` here would not compile. Persistence is driven
    /// explicitly by `settingsChanged()` instead, called from the settings
    /// screen when the user edits a field.
    var settings: Settings

    let history = HistoryStore()

    /// Bumped whenever `history` actually grows. `HistoryStore` is a plain
    /// class behind a `let`, so nothing about it is observable on its own — a
    /// chart reading it would never be told a point had been appended. Views
    /// that draw history read this counter to register the dependency.
    private(set) var historyVersion = 0

    private var loop: Task<Void, Never>?
    private var isRunning = false
    /// The interval the running loop was started with, so a settings change
    /// only tears the loop down when the cadence actually changed.
    private var runningInterval: Double?

    private let defaults: UserDefaults
    private let monitorsKey = "monitors.v1"
    private let settingsKey = "settings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.data(forKey: settingsKey)
            .flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        monitors = defaults.data(forKey: monitorsKey)
            .flatMap { try? JSONDecoder().decode([Monitor].self, from: $0) } ?? []
    }

    // MARK: - Collection

    func add(_ monitor: Monitor) {
        guard !monitors.contains(where: { $0.source == monitor.source }) else { return }
        monitors.append(monitor)
        persistMonitors()
        Task { await refresh(monitor.id) }
    }

    /// Adds the demo monitor with two days of history already recorded, so the
    /// charts say something immediately. Someone evaluating the app — a
    /// reviewer, or anyone without a device yet — should not have to wait an
    /// hour to find out whether it draws anything.
    func addDemoMonitor() {
        guard !monitors.contains(where: { $0.isDemo }) else { return }
        let monitor = DemoSource.monitor
        monitors.append(monitor)
        persistMonitors()
        for reading in DemoSource.backfill() {
            _ = history.record(reading, for: monitor.id)
        }
        history.flush()
        historyVersion &+= 1
        Task { await refresh(monitor.id) }
    }

    var hasDemoMonitor: Bool { monitors.contains { $0.isDemo } }

    func remove(_ monitor: Monitor) {
        monitors.removeAll { $0.id == monitor.id }
        latest[monitor.id] = nil
        status[monitor.id] = nil
        history.forget(monitor.id)
        cancelCloudHistory(monitor.id)
        setCloudBackfillDone(false, for: monitor.id)
        persistMonitors()
    }

    func remove(atOffsets offsets: IndexSet) {
        for index in offsets { remove(monitors[index]) }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        monitors.move(fromOffsets: source, toOffset: destination)
        persistMonitors()
    }

    func rename(_ monitor: Monitor, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = monitors.firstIndex(where: { $0.id == monitor.id }) else { return }
        monitors[i].name = trimmed
        persistMonitors()
    }

    func monitor(id: UUID) -> Monitor? { monitors.first { $0.id == id } }

    var hasCloudMonitors: Bool { monitors.contains { !$0.isLocal } }

    // MARK: - Polling

    func startPolling() {
        guard !isRunning else { return }
        isRunning = true
        restartLoop()
    }

    func stopPolling() {
        isRunning = false
        loop?.cancel()
        loop = nil
        // Backfill resumes from its saved floor on the next start; a request
        // left running would be refused once the app is suspended anyway.
        for id in cloudHistoryTasks.keys { cancelCloudHistory(id) }
        history.flush()
    }

    func settingsChanged() {
        persistSettings()
        if isRunning, runningInterval != settings.refreshInterval { restartLoop() }
    }

    private func restartLoop() {
        loop?.cancel()
        let interval = settings.refreshInterval
        runningInterval = interval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func refreshAll() async {
        // Concurrently, because one unreachable monitor must not delay the
        // others by the full request timeout.
        let ids = monitors.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { @MainActor in await self.refresh(id) }
            }
        }
    }

    func refresh(_ id: UUID) async {
        guard let monitor = monitor(id: id) else { return }
        if status[id] == .loading { return }
        status[id] = .loading

        if monitor.isDemo {
            let reading = DemoSource.reading(at: Date())
            latest[id] = reading
            status[id] = .ok(Date())
            if history.record(reading, for: id) { historyVersion &+= 1 }
            absorbIdentity(reading, into: id)
            return
        }

        do {
            let reading = try await AirGradientClient.shared.reading(for: monitor, token: settings.cloudToken)
            guard monitors.contains(where: { $0.id == id }) else { return } // removed mid-flight
            latest[id] = reading
            status[id] = .ok(Date())
            // A cloud monitor's history comes from the cloud, not from what
            // this app happened to observe. Recording here too would sprinkle
            // app-timed points through a fetched series at slightly different
            // timestamps.
            if case .cloud(let locationId) = monitor.source {
                refreshCloudHistory(id: id, locationId: locationId)
            } else if history.record(reading, for: id) {
                historyVersion &+= 1
            }
            absorbIdentity(reading, into: id)
        } catch {
            guard monitors.contains(where: { $0.id == id }) else { return }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            status[id] = .failed(message, Date())
        }
    }

    /// How often a cloud monitor's history is brought up to date. The buckets
    /// are five minutes wide, so asking faster only re-downloads the same
    /// numbers.
    private let cloudHistoryTTL: TimeInterval = 600
    private var cloudHistoryFetched: [UUID: Date] = [:]
    /// One sync per monitor at a time. Backfill can be dozens of requests, and
    /// runs apart from `refresh` so the tiles never wait on it.
    /// Tokened so a cancelled task finishing late can't clear the slot of the
    /// one that replaced it — which would let a duplicate sync start.
    private var cloudHistoryTasks: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]

    private func refreshCloudHistory(id: UUID, locationId: Int) {
        guard cloudHistoryTasks[id] == nil else { return }
        if let last = cloudHistoryFetched[id], Date().timeIntervalSince(last) < cloudHistoryTTL { return }
        cloudHistoryFetched[id] = Date()
        let token = UUID()
        let task = Task { [weak self] in
            await self?.syncCloudHistory(id: id, locationId: locationId)
            if self?.cloudHistoryTasks[id]?.token == token { self?.cloudHistoryTasks[id] = nil }
        }
        cloudHistoryTasks[id] = (token, task)
    }

    /// Catches up to now, then backfills towards a year. See `CloudHistoryPlan`.
    private func syncCloudHistory(id: UUID, locationId: Int) async {
        let now = Date()
        let newest = history.history(for: id).last?.timestamp
        let recent = CloudHistoryPlan.catchUp(newest: newest, now: now)
        for slice in recent {
            guard await fetchCloudSlice(slice, id: id, locationId: locationId) != nil else {
                // A failed history fetch must not mark the monitor unreachable:
                // the current reading already arrived, and that is what the
                // tiles show. The chart keeps whatever it had, and the next
                // refresh tries again rather than waiting out the TTL.
                cloudHistoryFetched[id] = nil
                return
            }
        }

        guard !cloudBackfillDone(id) else { return }

        // Resume from the oldest point actually held, not from a saved
        // position: history reaches disk up to five minutes after it is
        // fetched, so a saved position can outlive a crash that the samples
        // didn't, and the hole behind it would never be refetched.
        var floor = history.history(for: id).first.map { CloudHistoryPlan.hourStart($0.timestamp) }
            ?? recent.first?.start ?? now
        var emptyRun = 0
        while let slice = CloudHistoryPlan.backfill(floor: floor, now: now) {
            // Politeness, not correctness: a year is ~40 requests, and nothing
            // is gained by sending them back to back.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled,
                  let count = await fetchCloudSlice(slice, id: id, locationId: locationId) else { return }
            floor = slice.start
            emptyRun = count == 0 ? emptyRun + 1 : 0
            if emptyRun >= CloudHistoryPlan.emptyChunksToStop { break }
        }
        // Done only once it is on disk — the same crash, the other way round.
        history.flush()
        setCloudBackfillDone(true, for: id)
    }

    /// Fetches and stores one slice. Returns how many buckets it held, or nil
    /// if the fetch failed or the monitor was removed meanwhile.
    private func fetchCloudSlice(_ slice: DateInterval, id: UUID, locationId: Int) async -> Int? {
        guard let past = try? await AirGradientClient.shared.cloudHistory(
            locationId: locationId, from: slice.start, to: slice.end, token: settings.cloudToken
        ), !Task.isCancelled, monitors.contains(where: { $0.id == id }) else { return nil }
        history.merge(past, covering: slice, for: id)
        historyVersion &+= 1
        return past.count
    }

    // MARK: - Cloud backfill progress

    /// Cloud monitors whose backfill has finished — reached a year, or found
    /// the monitor hadn't existed that long. Without this, every launch would
    /// re-ask for the empty weeks before a monitor was set up.
    private let backfillDoneKey = "cloudBackfillDone.v1"

    private func cloudBackfillDone(_ id: UUID) -> Bool {
        (defaults.stringArray(forKey: backfillDoneKey) ?? []).contains(id.uuidString)
    }

    private func setCloudBackfillDone(_ done: Bool, for id: UUID) {
        var ids = Set(defaults.stringArray(forKey: backfillDoneKey) ?? [])
        if done { ids.insert(id.uuidString) } else { ids.remove(id.uuidString) }
        defaults.set(ids.sorted(), forKey: backfillDoneKey)
    }

    private func cancelCloudHistory(_ id: UUID) {
        cloudHistoryTasks[id]?.task.cancel()
        cloudHistoryTasks[id] = nil
        cloudHistoryFetched[id] = nil
    }

    /// Serial/model/firmware arrive with the readings; keep them on the monitor
    /// so the detail page can still identify a device that has gone offline.
    private func absorbIdentity(_ reading: Reading, into id: UUID) {
        guard let i = monitors.firstIndex(where: { $0.id == id }) else { return }
        var changed = false
        if let s = reading.serialno, monitors[i].serial != s { monitors[i].serial = s; changed = true }
        if let m = reading.model, monitors[i].model != m { monitors[i].model = m; changed = true }
        if let f = reading.firmware, monitors[i].firmware != f { monitors[i].firmware = f; changed = true }
        if changed { persistMonitors() }
    }

    // MARK: - Persistence

    private func persistMonitors() {
        if let data = try? JSONEncoder().encode(monitors) { defaults.set(data, forKey: monitorsKey) }
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: settingsKey) }
    }
}
