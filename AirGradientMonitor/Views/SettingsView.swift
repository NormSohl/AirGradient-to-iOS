import SwiftUI

struct SettingsView: View {
    @Environment(MonitorsModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section("Units") {
                    Toggle("Fahrenheit", isOn: $model.settings.fahrenheit)
                    Toggle("Corrected values", isOn: $model.settings.useCompensated)
                }

                Section {
                    Picker("Refresh every", selection: $model.settings.refreshInterval) {
                        ForEach(Settings.refreshChoices, id: \.self) { choice in
                            Text(Settings.refreshLabel(choice)).tag(choice)
                        }
                    }
                } header: {
                    Text("Updates")
                } footer: {
                    Text("Applies while the app is open. Monitors sample about every two seconds; cloud locations update no faster than every five minutes whatever this is set to.")
                }

                Section {
                    SecureField("API token", text: $model.settings.cloudToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("AirGradient cloud")
                } footer: {
                    Text("Optional. Create a long-term token at dashboard.airgradient.com to add locations that aren't on this network. Local monitors need no token.")
                }

                Section {
                    ForEach(model.monitors) { monitor in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(monitor.name)
                            Text(monitor.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { model.remove(atOffsets: $0) }
                    .onMove { model.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Monitors")
                } footer: {
                    if !model.monitors.isEmpty {
                        Text("Drag to reorder the dashboard. Removing a monitor also discards its recorded history.")
                    }
                }
            }
            .onChange(of: model.settings) { _, _ in model.settingsChanged() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}
