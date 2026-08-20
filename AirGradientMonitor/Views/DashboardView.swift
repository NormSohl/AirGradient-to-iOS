import SwiftUI

struct DashboardView: View {
    @Environment(MonitorsModel.self) private var model
    @State private var showingAdd = false
    @State private var showingSettings = false

    private let columns = [GridItem(.adaptive(minimum: 165), spacing: 14)]

    var body: some View {
        NavigationStack {
            Group {
                if model.monitors.isEmpty {
                    EmptyStateView { showingAdd = true }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(model.monitors) { monitor in
                                NavigationLink(value: monitor.id) {
                                    MonitorTile(monitor: monitor)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 4)
                    }
                    .refreshable { await model.refreshAll() }
                }
            }
            .navigationTitle("Air Quality")
            .navigationDestination(for: UUID.self) { id in
                if let monitor = model.monitor(id: id) {
                    MonitorDetailView(monitor: monitor)
                }
            }
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
            .sheet(isPresented: $showingAdd) { AddMonitorView() }
            .sheet(isPresented: $showingSettings) { SettingsView() }
        }
    }
}

private struct EmptyStateView: View {
    var add: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No monitors yet", systemImage: "sensor")
        } description: {
            Text("Add an AirGradient monitor on this network, or connect an AirGradient cloud account.")
        } actions: {
            Button("Add a monitor", action: add)
                .buttonStyle(.borderedProminent)
        }
    }
}

/// The dashboard card: headline PM2.5 with its AQI band as the background, and
/// the three numbers people actually glance at underneath.
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
            RoundedRectangle(cornerRadius: 16)
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
