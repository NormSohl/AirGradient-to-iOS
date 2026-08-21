import SwiftUI

/// Root of the app, built iPad-first.
///
/// A `NavigationSplitView` keeps the monitor list permanently on screen next to
/// a full-size detail pane — which is the whole point on a tablet that sits on a
/// shelf showing air quality all day. On iPhone the same structure collapses to
/// a push navigation stack for free, so there is one view hierarchy rather than
/// two size-class branches to keep in step.
struct DashboardView: View {
    @Environment(MonitorsModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// What the detail pane is showing. The overview (the tile grid) is a
    /// first-class destination rather than the root of a stack, so on iPad it
    /// keeps its place in the sidebar instead of being something you back out to.
    enum Selection: Hashable {
        case overview
        case monitor(UUID)
    }

    @State private var selection: Selection?
    @State private var showingAdd = false
    @State private var showingSettings = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack { detail }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showingAdd) { AddMonitorView() }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .onAppear {
            // Only pre-select on iPad. In the collapsed (iPhone) layout a
            // non-nil selection is a pushed view, so doing this there would
            // launch the app one screen deep with a back button.
            //
            // With no monitors there is nothing to overview: the grid would
            // draw an empty LazyVGrid, and the sidebar hides its "All monitors"
            // row in that state anyway. Leaving the selection nil is what lets
            // the detail pane show the empty state that offers to add one.
            if sizeClass == .regular, selection == nil, !model.monitors.isEmpty {
                selection = .overview
            }
        }
        .onChange(of: model.monitors) { _, monitors in
            // A monitor can be removed from its own detail pane or from
            // Settings. Either way the selection would otherwise point at
            // something that no longer exists, leaving a frozen pane.
            // Adding the first monitor from an empty state leaves the
            // selection nil, and in the regular layout the sidebar may be
            // hidden — which strands you on "Select a monitor" with no list in
            // sight. Show what was just added instead. Compact is fine as it
            // is: nil selection there means the list itself is on screen.
            if selection == nil, sizeClass == .regular, let added = monitors.last {
                selection = .monitor(added.id)
            }

            if case .monitor(let id) = selection,
               !monitors.contains(where: { $0.id == id }) {
                // Same reasoning as the launch pre-selection: falling back to
                // the overview after removing the *last* monitor would land on
                // the same blank grid.
                selection = (sizeClass == .regular && !monitors.isEmpty) ? .overview : nil
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            if !model.monitors.isEmpty {
                Section {
                    Label("All monitors", systemImage: "square.grid.2x2")
                        .tag(Selection.overview)
                }
            }

            Section("Monitors") {
                ForEach(model.monitors) { monitor in
                    MonitorRow(monitor: monitor)
                        .tag(Selection.monitor(monitor.id))
                }
                .onDelete { model.remove(atOffsets: $0) }
                .onMove { model.move(fromOffsets: $0, toOffset: $1) }

                if model.monitors.isEmpty {
                    Button("Add a monitor") { showingAdd = true }
                    // The sidebar *is* the first screen on iPhone, so the demo
                    // has to be offered here too — not only in the detail
                    // pane's empty state, which a phone never shows first.
                    Button("Try sample data") { model.addDemoMonitor() }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Air Quality")
        .refreshable { await model.refreshAll() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: {
                    Label("Add monitor", systemImage: "plus")
                }
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .overview:
            OverviewGrid(select: { selection = .monitor($0) })
        case .monitor(let id):
            if let monitor = model.monitor(id: id) {
                MonitorDetailView(monitor: monitor)
            } else {
                ContentUnavailableView("Monitor removed", systemImage: "sensor.fill")
            }
        case nil:
            if model.monitors.isEmpty {
                ContentUnavailableView {
                    Label("No monitors yet", systemImage: "sensor")
                } description: {
                    Text("Add an AirGradient monitor on this network, or connect an AirGradient cloud account.")
                } actions: {
                    Button("Add a monitor") { showingAdd = true }
                        .buttonStyle(.borderedProminent)
                    Button("Try sample data") { model.addDemoMonitor() }
                }
            } else {
                ContentUnavailableView("Select a monitor", systemImage: "square.grid.2x2")
            }
        }
    }
}

/// One line in the sidebar: enough to answer "is anything wrong" without
/// selecting it, which is what makes the always-visible list worth its width.
private struct MonitorRow: View {
    @Environment(MonitorsModel.self) private var model
    let monitor: Monitor

    private var reading: Reading? { model.latest[monitor.id] }
    private var pm25: Double? { reading.flatMap { Metric.pm25.value(from: $0, settings: model.settings) } }
    private var band: QualityBand? { pm25.map { Metric.pm25.band($0) } }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(band?.color ?? .gray.opacity(0.4))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 1) {
                Text(monitor.name)
                    .lineLimit(1)
                Text(band?.shortLabel ?? "No data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(pm25.map { Metric.pm25.format($0) } ?? "—")
                .font(.callout.weight(.medium).monospacedDigit())
                .foregroundStyle(band?.color ?? .secondary)

            StatusDot(status: model.status[monitor.id] ?? .idle)
        }
        .padding(.vertical, 2)
    }
}

/// The tile grid, now a destination in the detail pane rather than the app root.
private struct OverviewGrid: View {
    @Environment(MonitorsModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    var select: (UUID) -> Void

    private var columns: [GridItem] {
        // Wider tiles on iPad: the phone minimum would give six cramped columns
        // across a 12.9" landscape canvas.
        [GridItem(.adaptive(minimum: sizeClass == .regular ? 240 : 165), spacing: 16)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(model.monitors) { monitor in
                    Button { select(monitor.id) } label: {
                        MonitorTile(monitor: monitor)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle("All monitors")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refreshAll() }
    }
}

/// The dashboard card: headline PM2.5 with its AQI band, and the three numbers
/// people actually glance at underneath.
struct MonitorTile: View {
    @Environment(MonitorsModel.self) private var model
    let monitor: Monitor

    private var reading: Reading? { model.latest[monitor.id] }
    private var status: MonitorsModel.Status { model.status[monitor.id] ?? .idle }

    private var pm25: Double? { reading.flatMap { Metric.pm25.value(from: $0, settings: model.settings) } }
    private var band: QualityBand? { pm25.map { Metric.pm25.band($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(monitor.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                StatusDot(status: status)
            }

            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(pm25.map { Metric.pm25.format($0) } ?? "—")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                Text("µg/m³")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(band?.shortLabel ?? "No data")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background((band?.color ?? .gray).opacity(0.18), in: Capsule())
                .foregroundStyle(band?.color ?? .secondary)

            Divider()

            HStack(spacing: 12) {
                MiniStat(metric: .co2, reading: reading, settings: model.settings)
                MiniStat(metric: .temperature, reading: reading, settings: model.settings)
                MiniStat(metric: .humidity, reading: reading, settings: model.settings)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(cornerRadius: 16)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder((band?.color ?? .gray).opacity(0.35), lineWidth: 1)
        )
        .opacity(status.errorText == nil ? 1 : 0.55)
    }
}

private struct MiniStat: View {
    let metric: Metric
    let reading: Reading?
    let settings: Settings

    var body: some View {
        let value = reading.flatMap { metric.value(from: $0, settings: settings) }
        VStack(alignment: .leading, spacing: 1) {
            Text(value.map { metric.format($0) } ?? "—")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(value.map { metric.band($0, fahrenheit: settings.fahrenheit).color } ?? .secondary)
            Text(metric.unit(fahrenheit: settings.fahrenheit).isEmpty ? metric.title : metric.unit(fahrenheit: settings.fahrenheit))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

struct StatusDot: View {
    let status: MonitorsModel.Status

    var body: some View {
        switch status {
        case .loading:
            ProgressView().controlSize(.mini)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .ok, .idle:
            Circle()
                .fill(.green)
                .frame(width: 7, height: 7)
                .opacity(status.lastUpdate == nil ? 0 : 1)
        }
    }
}
