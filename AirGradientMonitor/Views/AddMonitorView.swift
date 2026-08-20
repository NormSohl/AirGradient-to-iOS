import SwiftUI

/// Three ways in, in the order they are likely to work: Bonjour discovery,
/// typed address, cloud account.
struct AddMonitorView: View {
    @Environment(MonitorsModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var discovery = MonitorDiscovery()
    @State private var manualHost = ""
    @State private var manualName = ""
    @State private var probing = false
    @State private var probeError: String?

    @State private var cloudLocations: [(id: Int, name: String)] = []
    @State private var cloudLoading = false
    @State private var cloudError: String?

    var body: some View {
        NavigationStack {
            Form {
                discoverySection
                manualSection
                cloudSection
            }
            .navigationTitle("Add monitor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                discovery.start()
                if !model.settings.cloudToken.isEmpty { await loadCloudLocations() }
            }
            .onDisappear { discovery.stop() }
        }
    }

    // MARK: - Sections

    private var discoverySection: some View {
        Section {
            if let failure = discovery.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if discovery.found.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Looking for monitors…")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(discovery.found) { found in
                Button {
                    add(host: found.host, name: found.serial.map { "AirGradient \($0.suffix(4))" } ?? found.serviceName)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(found.serviceName).font(.body)
                        Text(found.host).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(alreadyAdded(host: found.host))
            }
        } header: {
            Text("On this network")
        } footer: {
            Text("Monitors running firmware 3.0.10 or later announce themselves over Bonjour. iOS will ask for local network permission the first time.")
        }
    }

    private var manualSection: some View {
        Section {
            TextField("192.168.1.42 or airgradient_xxxx.local", text: $manualHost)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("Name (optional)", text: $manualName)
                .textInputAutocapitalization(.words)

            if let probeError {
                Text(probeError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button {
                Task { await probeAndAdd() }
            } label: {
                HStack {
                    Text("Add by address")
                    Spacer()
                    if probing { ProgressView().controlSize(.small) }
                }
            }
            .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty || probing)
        } header: {
            Text("By address")
        } footer: {
            Text("The address is checked before it is saved, so a typo is caught here rather than showing up as a monitor that never has any data.")
        }
    }

    private var cloudSection: some View {
        Section {
            if model.settings.cloudToken.isEmpty {
                Text("Add an API token in Settings to see the locations on your AirGradient account.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if cloudLoading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading locations…").foregroundStyle(.secondary)
                }
            } else if let cloudError {
                Text(cloudError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if cloudLocations.isEmpty {
                Text("No locations on this account.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(cloudLocations, id: \.id) { location in
                    Button {
                        model.add(Monitor(name: location.name, source: .cloud(locationId: location.id)))
                        dismiss()
                    } label: {
                        Text(location.name)
                    }
                    .disabled(model.monitors.contains { $0.source == .cloud(locationId: location.id) })
                }
            }
        } header: {
            Text("AirGradient cloud")
        } footer: {
            Text("Cloud readings are aggregated in five-minute buckets, so they lag a monitor on the same network. Use the cloud for places this iPhone isn't.")
        }
    }

    // MARK: - Actions

    private func alreadyAdded(host: String) -> Bool {
        model.monitors.contains { $0.source == .local(host: host) }
    }

    private func add(host: String, name: String) {
        model.add(Monitor(name: name, source: .local(host: host)))
        dismiss()
    }

    /// Fetch once before saving: a monitor that was added from a typo looks
    /// identical to one that is merely offline, and the difference matters when
    /// someone is standing next to a working device wondering why.
    @MainActor
    private func probeAndAdd() async {
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        probing = true
        probeError = nil
        do {
            let reading = try await AirGradientClient.shared.localReading(host: host)
            var monitor = Monitor(
                name: manualName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? (reading.serialno.map { "AirGradient \($0.suffix(4))" } ?? host)
                    : manualName,
                source: .local(host: host)
            )
            monitor.serial = reading.serialno
            monitor.model = reading.model
            monitor.firmware = reading.firmware
            model.add(monitor)
            dismiss()
        } catch {
            probeError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        probing = false
    }

    @MainActor
    private func loadCloudLocations() async {
        cloudLoading = true
        cloudError = nil
        do {
            cloudLocations = try await AirGradientClient.shared.cloudLocations(token: model.settings.cloudToken)
        } catch {
            cloudError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        cloudLoading = false
    }
}
