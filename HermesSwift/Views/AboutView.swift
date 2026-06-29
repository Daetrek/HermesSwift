import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct AboutView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @State private var copied = false

    var body: some View {
        List {
            Section("App") {
                LabeledContent("Name", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "HermesSwift")
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0")
                LabeledContent("Bundle", value: Bundle.main.bundleIdentifier ?? "unknown")
            }

            Section("Hermes") {
                LabeledContent("Gateway", value: settings.gatewayURL)
                LabeledContent("Model", value: settings.selectedModel)
                LabeledContent("Profile", value: settings.selectedProfile)
                LabeledContent("Status", value: settings.statusText)
            }

            Section("Diagnostics") {
                Text(settings.diagnosticsText)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                Button(copied ? "Copied" : "Copy Build Info") {
                    copy(settings.diagnosticsText)
                }
            }

            Section("Notes") {
                Text("Tailnet HTTP is acceptable for this private MVP because Tailscale encrypts device-to-device traffic. HTTPS/Tailscale Serve remains a later polish item.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("About HermesSwift")
    }

    private func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run { copied = false }
        }
    }
}
