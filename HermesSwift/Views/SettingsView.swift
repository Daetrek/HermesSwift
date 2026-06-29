import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Gateway") {
                    TextField("Gateway URL", text: $settings.gatewayURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    SecureField("API token", text: $settings.apiToken)
                        .textInputAutocapitalization(.never)
                    Button(settings.isTesting ? "Testing…" : "Save + Test") { Task { await settings.testConnection() } }
                        .disabled(settings.isTesting)
                    Button("Clear Token", role: .destructive) { settings.clearToken() }
                }

                Section("Status") {
                    Text(settings.statusText)
                    if let error = settings.lastError {
                        Text(error)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

                DiagnosticsSection()
                ModelProfileSection()
                VoiceSettingsSection()

                Section("App") {
                    NavigationLink("About / Build Info") { AboutView() }
                }
            }
            .navigationTitle("HermesSwift Settings")
            .toolbar { Button("Done") { dismiss() } }
            .task {
                await settings.refreshModels()
                await settings.refreshProfiles()
                await settings.refreshVoices()
            }
        }
    }
}
