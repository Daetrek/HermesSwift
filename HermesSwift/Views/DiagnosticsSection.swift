import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct DiagnosticsSection: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @State private var copied = false

    var body: some View {
        Section("Diagnostics") {
            VStack(alignment: .leading, spacing: 8) {
                DiagnosticRow(label: "Gateway", value: settings.gatewayURL)
                DiagnosticRow(label: "Token", value: settings.apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Missing" : "Present")
                DiagnosticRow(label: "Status", value: settings.statusText)
                DiagnosticRow(label: "Selected model", value: settings.selectedModel)
                DiagnosticRow(label: "Selected profile", value: settings.selectedProfile)
                DiagnosticRow(label: "VoiceStack", value: settings.voiceStackURL)
                if let error = settings.lastError, !error.isEmpty {
                    DiagnosticRow(label: "Last error", value: error, valueColor: .red)
                }
            }
            .font(.footnote)
            .textSelection(.enabled)

            DisclosureGroup("Profile/API guardrails") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(settings.availableProfiles) { profile in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: icon(for: status(for: profile)))
                                .foregroundStyle(color(for: status(for: profile)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.id)
                                    .font(.caption.weight(.semibold))
                                Text(status(for: profile))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    Text("Only `default` and profiles marked API ready are used for iPhone chat sends. Voice Call is local VoiceStack mode, not a Hermes API profile.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }

            Button(copied ? "Copied Debug Report" : "Copy Debug Report") {
                copy(settings.diagnosticsText)
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await MainActor.run { copied = false }
                }
            }
        }
    }

    private func status(for profile: HermesProfileInfo) -> String {
        if profile.id == "default" { return "default route" }
        if profile.apiServerReachable == true { return "API ready" }
        if profile.apiServerEnabled == false { return "no API server" }
        if profile.apiServerReachable == false { return "API offline" }
        return "unavailable"
    }

    private func icon(for status: String) -> String {
        switch status {
        case "default route": return "sparkles"
        case "API ready": return "checkmark.circle.fill"
        case "no API server": return "xmark.circle.fill"
        case "API offline": return "wifi.exclamationmark"
        default: return "questionmark.circle.fill"
        }
    }

    private func color(for status: String) -> Color {
        switch status {
        case "default route", "API ready": return TerminalTheme.text
        case "no API server", "API offline": return .orange
        default: return .secondary
        }
    }

    private func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

private struct DiagnosticRow: View {
    let label: String
    let value: String
    var valueColor: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.tertiary)
            Text(value)
                .foregroundStyle(valueColor)
                .lineLimit(4)
        }
    }
}
