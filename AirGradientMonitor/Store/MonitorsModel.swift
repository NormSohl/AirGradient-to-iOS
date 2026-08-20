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

    func remove(_ monitor: Monitor) {
        monitors.removeAll { $0.id == monitor.id }
        latest[monitor.id] = nil
        status[monitor.id] = nil
        history.forget(monitor.id)
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

        do {
            let reading = try await AirGradientClient.shared.reading(for: monitor, token: settings.cloudToken)
            guard monitors.contains(where: { $0.id == id }) else { return } // removed mid-flight
            latest[id] = reading
            status[id] = .ok(Date())
            if history.record(reading, for: id) { historyVersion &+= 1 }
            absorbIdentity(reading, into: id)
        } catch {
            guard monitors.contains(where: { $0.id == id }) else { return }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            status[id] = .failed(message, Date())
        }
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
