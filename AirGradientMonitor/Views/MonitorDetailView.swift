import SwiftUI

struct MonitorDetailView: View {
    @Environment(MonitorsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let monitor: Monitor

    @State private var chartMetric: Metric = .pm25
    @State private var renaming = false
    @State private var draftName = ""
    @State private var calibrating = false
    @State private var configMessage: String?

    private var reading: Reading? { model.latest[monitor.id] }
    private var status: MonitorsModel.Status { model.status[monitor.id] ?? .idle }
    private var settings: Settings { model.settings }

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error = status.errorText {
                    ErrorBanner(text: error, lastSeen: status.lastUpdate)
                }

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Metric.allCases) { metric in
                        MetricCard(
                            metric: metric,
                            value: reading.flatMap { metric.value(from: $0, settings: settings) },
                            settings: settings
                        )
                    }
                }

                HistorySection(monitor: monitor, metric: $chartMetric)

                DeviceInfoSection(monitor: monitor, reading: reading, status: status)

                if monitor.isLocal {
                    LocalControlsSection(
                        monitor: monitor,
                        calibrating: $calibrating,
                        message: $configMessage
                    )
                }
            }
            .padding()
        }
        .navigationTitle(monitor.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refresh(monitor.id) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Rename…") {
                        draftName = monitor.name
                        renaming = true
                    }
                    Button("Refresh now") {
                        Task { await model.refresh(monitor.id) }
                    }
                    Divider()
                    Button("Remove monitor", role: .destructive) {
                        // Pop first: this view is built from a monitor that is
                        // about to stop existing, and staying on it would show
                        // a page whose data can never update again.
                        dismiss()
                        model.remove(monitor)
                    }
                } label: {
                    Label("Options", systemImage: "ellipsis.circle")
                }
            }
        }
        .alert("Rename monitor", isPresented: $renaming) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { model.rename(monitor, to: draftName) }
        }
        .alert("AirGradient", isPresented: showingConfigMessage) {
            Button("OK") { configMessage = nil }
        } message: {
            Text(configMessage ?? "")
        }
    }

    /// A real two-way binding rather than `.constant(…)`, so a swipe-away or a
    /// system dismissal clears the message instead of leaving the alert stuck
    /// re-presenting itself.
    private var showingConfigMessage: Binding<Bool> {
        Binding(
            get: { configMessage != nil },
            set: { if !$0 { configMessage = nil } }
        )
    }
}

private struct ErrorBanner: View {
    let text: String
    let lastSeen: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(text, systemImage: "wifi.exclamationmark")
                .font(.footnote.weight(.medium))
            if let lastSeen {
                Text("Last answered \(lastSeen.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct MetricCard: View {
    let metric: Metric
    let value: Double?
    let settings: Settings

    private var band: QualityBand? {
        value.map { metric.band($0, fahrenheit: settings.fahrenheit) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(metric.title, systemImage: metric.symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)

            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value.map { metric.format($0) } ?? "—")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                Text(metric.unit(fahrenheit: settings.fahrenheit))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(band?.shortLabel ?? "No reading")
                .font(.caption2.weight(.medium))
                .foregroundStyle(band?.color ?? .secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(cornerRadius: 14)
    }
}

private struct DeviceInfoSection: View {
    let monitor: Monitor
    let reading: Reading?
    let status: MonitorsModel.Status

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Device")
                .font(.headline)

            InfoRow("Address", monitor.subtitle)
            if let serial = monitor.serial { InfoRow("Serial", serial) }
            if let model = monitor.model { InfoRow("Model", model) }
            if let fw = monitor.firmware { InfoRow("Firmware", fw) }
            if let wifi = reading?.wifi { InfoRow("WiFi", "\(Int(wifi)) dBm") }
            if let updated = status.lastUpdate {
                InfoRow("Updated", updated.formatted(date: .omitted, time: .standard))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardBackground(cornerRadius: 14)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.footnote)
    }
}

/// The one `PUT /config` action worth having on a phone. Everything else the
/// endpoint exposes (correction algorithms, MQTT, cloud-vs-local control) is
/// deliberately left to AirGradient's own dashboard — a mis-tap here would be
/// hard to notice and hard to undo.
private struct LocalControlsSection: View {
    let monitor: Monitor
    @Binding var calibrating: Bool
    @Binding var message: String?

    @State private var confirmCalibration = false

    private var host: String? {
        if case .local(let h) = monitor.source { return h }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Controls")
                .font(.headline)

            Button {
                confirmCalibration = true
            } label: {
                HStack {
                    Label("Calibrate CO₂ sensor", systemImage: "tuningfork")
                    Spacer()
                    if calibrating { ProgressView().controlSize(.small) }
                }
            }
            .disabled(calibrating)

            Text("Runs the SenseAir S8's forced calibration. The monitor must be in fresh outdoor air (~420 ppm) and left there for several minutes — doing this indoors teaches it that your room is clean.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardBackground(cornerRadius: 14)
        .alert("Calibrate CO₂?", isPresented: $confirmCalibration) {
            Button("Cancel", role: .cancel) {}
            Button("Calibrate", role: .destructive) { calibrate() }
        } message: {
            Text("Only do this outdoors. The reading will be wrong for a few minutes afterwards.")
        }
    }

    @MainActor
    private func calibrate() {
        guard let host else { return }
        calibrating = true
        Task {
            do {
                try await AirGradientClient.shared.putConfig(
                    host: host,
                    body: ["co2CalibrationRequested": true]
                )
                message = "Calibration requested. Leave the monitor outdoors for a few minutes."
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            calibrating = false
        }
    }
}
