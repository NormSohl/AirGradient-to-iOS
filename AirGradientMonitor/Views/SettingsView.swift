import SwiftUI
import UIKit

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
                    HStack {
                        SecureField("API token", text: $model.settings.cloudToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        // A token is pasted, never typed, and iOS can refuse a
                        // cross-app paste silently — leaving no way to tell a
                        // blocked paste from a bad token. An explicit button
                        // makes the system ask, so refusing is visible.
                        if model.settings.cloudToken.isEmpty {
                            Button("Paste") {
                                let pasted = UIPasteboard.general.string ?? ""
                                model.settings.cloudToken = pasted
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                            .buttonStyle(.borderless)
                        } else {
                            Button {
                                model.settings.cloudToken = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Clear token")
                        }
                    }
                } header: {
                    Text("AirGradient cloud")
                } footer: {
                    // Secure fields are blanked in screenshots and show only
                    // dots on screen, so "is anything in there?" is otherwise
                    // unanswerable. The length says the field is populated
                    // without putting the token itself on screen.
                    if model.settings.cloudToken.isEmpty {
                        Text("Optional. Create a long-term token at dashboard.airgradient.com to add locations that aren't on this network. Local monitors need no token.")
                    } else {
                        Text("Token set — \(model.settings.cloudToken.count) characters. Locations appear under Add monitor.")
                    }
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
