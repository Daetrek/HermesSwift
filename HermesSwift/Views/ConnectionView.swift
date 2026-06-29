import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        Form {
            Section("Gateway") {
                TextField("Gateway URL", text: $settings.gatewayURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                SecureField("API token", text: $settings.apiToken)
                    .textInputAutocapitalization(.never)
                Button(settings.isTesting ? "Testing…" : "Save + Test Connection") {
                    Task { await settings.testConnection() }
                }
                .disabled(settings.isTesting)
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

            Section("Security") {
                Text("Token is stored in Keychain. This app does not expose arbitrary shell execution from the phone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("HermesSwift")
    }
}
