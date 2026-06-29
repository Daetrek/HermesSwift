import SwiftUI

struct ModelProfileSection: View {
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        Section("Agent Routing") {
            Picker("Model", selection: $settings.selectedModel) {
                ForEach(settings.availableModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }

            Picker("Profile", selection: $settings.selectedProfile) {
                ForEach(settings.availableProfiles) { profile in
                    Text(profileLabel(profile)).tag(profile.id)
                }
            }

            HStack {
                Button(settings.isLoadingModels ? "Refreshing Models…" : "Refresh Models") {
                    Task { await settings.refreshModels() }
                }
                .disabled(settings.isLoadingModels)

                Spacer()

                Button(settings.isLoadingProfiles ? "Refreshing Profiles…" : "Refresh Profiles") {
                    Task { await settings.refreshProfiles() }
                }
                .disabled(settings.isLoadingProfiles)
            }

            Text("Model overrides now route through the patched Hermes API server after gateway restart. Profiles route through profile-local API servers when available; unavailable profiles remain selectable but will return a clear API error until their gateway/API server is running.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func profileLabel(_ profile: HermesProfileInfo) -> String {
        var parts = [profile.name ?? profile.id]
        if profile.active == true { parts.append("active") }
        if profile.apiServerReachable == true {
            if let port = profile.apiServerPort { parts.append(":\(port)") }
            else { parts.append("api") }
        } else if profile.apiServerEnabled == true {
            parts.append("api offline")
        }
        return parts.joined(separator: " • ")
    }
}
