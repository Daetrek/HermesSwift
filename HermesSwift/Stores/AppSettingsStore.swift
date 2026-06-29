import Foundation

enum VoiceReplyMode: String, CaseIterable, Identifiable {
    case never
    case afterVoice
    case always

    var id: String { rawValue }

    var label: String {
        switch self {
        case .never: return "Never"
        case .afterVoice: return "After voice prompts"
        case .always: return "Always"
        }
    }

    var detail: String {
        switch self {
        case .never: return "Replies stay text-only."
        case .afterVoice: return "Only speaks when your last prompt came from the mic."
        case .always: return "Speaks every HermesSwift reply."
        }
    }
}

@MainActor
final class AppSettingsStore: ObservableObject {
    @Published var gatewayURL: String {
        didSet { UserDefaults.standard.set(gatewayURL, forKey: "gatewayURL") }
    }
    @Published var apiToken: String = ""
    @Published var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "selectedModel") }
    }
    @Published var selectedProfile: String {
        didSet { UserDefaults.standard.set(selectedProfile, forKey: "selectedProfile") }
    }
    @Published var availableModels: [String] = AppSettingsStore.defaultModelOptions
    @Published var availableProfiles: [HermesProfileInfo] = AppSettingsStore.defaultProfileOptions.map { HermesProfileInfo(id: $0, name: $0, active: $0 == "default", gatewayState: nil, apiServerEnabled: nil, apiServerPort: nil, apiServerReachable: nil) }
    @Published var statusText: String = "Not checked"
    @Published var lastError: String?
    @Published var isTesting = false
    @Published var isLoadingModels = false
    @Published var isLoadingProfiles = false
    @Published var voiceStackURL: String {
        didSet { UserDefaults.standard.set(voiceStackURL, forKey: "voiceStackURL") }
    }
    @Published var selectedVoice: String {
        didSet { UserDefaults.standard.set(selectedVoice, forKey: "selectedVoice") }
    }
    @Published var availableVoices: [VoiceInfo] = [VoiceInfo(id: "af_heart", name: "af_heart", language: "en-US")]
    @Published var autoSendTranscript: Bool {
        didSet { UserDefaults.standard.set(autoSendTranscript, forKey: "autoSendTranscript") }
    }
    @Published var voiceReplyMode: VoiceReplyMode {
        didSet { UserDefaults.standard.set(voiceReplyMode.rawValue, forKey: "voiceReplyMode") }
    }
    @Published var callSilenceTimeout: Double {
        didSet { UserDefaults.standard.set(callSilenceTimeout, forKey: "callSilenceTimeout") }
    }
    @Published var callMinimumSpeechDuration: Double {
        didSet { UserDefaults.standard.set(callMinimumSpeechDuration, forKey: "callMinimumSpeechDuration") }
    }
    @Published var callSilenceThreshold: Double {
        didSet { UserDefaults.standard.set(callSilenceThreshold, forKey: "callSilenceThreshold") }
    }
    @Published var isLoadingVoices = false

    static let defaultModelOptions = ["hermes-agent", "gpt-4.1", "claude-sonnet-4", "local-model"]
    static let defaultProfileOptions = ["default"]

    private let keychain = KeychainService()

    var selectedModelForRequest: String? {
        let trimmed = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "hermes-agent" ? nil : trimmed
    }

    var selectedProfileForRequest: String? {
        let trimmed = selectedProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "default" else { return nil }
        guard let profile = availableProfiles.first(where: { $0.id == trimmed }) else { return nil }
        guard profile.apiServerReachable == true else { return nil }
        return trimmed
    }

    var diagnosticsText: String {
        [
            "Gateway URL: \(gatewayURL)",
            "Token present: \(!apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "yes" : "no")",
            "Selected model: \(selectedModel)",
            "Selected profile: \(selectedProfile)",
            "VoiceStack URL: \(voiceStackURL)",
            "Selected voice: \(selectedVoice)",
            "Profiles:\n\(profileDiagnosticsText)",
            "Auto-send transcript: \(autoSendTranscript ? "yes" : "no")",
            "Voice reply mode: \(voiceReplyMode.label)",
            "Call silence timeout: \(String(format: "%.1f", callSilenceTimeout))s",
            "Call minimum speech: \(String(format: "%.1f", callMinimumSpeechDuration))s",
            "Call silence threshold: \(Int(callSilenceThreshold)) dB",
            "Status: \(statusText)",
            "Last error: \(lastError ?? "none")",
            "App: \(buildInfoText)"
        ].joined(separator: "\n")
    }

    var profileDiagnosticsText: String {
        availableProfiles.map { profile in
            let status: String
            if profile.id == "default" {
                status = "default route"
            } else if profile.apiServerReachable == true {
                status = "API ready"
            } else if profile.apiServerEnabled == false {
                status = "no API server"
            } else if profile.apiServerReachable == false {
                status = "API offline"
            } else {
                status = "unavailable"
            }
            return "- \(profile.id): \(status)"
        }.joined(separator: "\n")
    }

    var buildInfoText: String {
        let bundle = Bundle.main
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "HermesSwift"
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let bundleID = bundle.bundleIdentifier ?? "unknown"
        return "\(name) \(version) (\(build)) • \(bundleID)"
    }

    init() {
        let savedURL = UserDefaults.standard.string(forKey: "gatewayURL")
        let finalURL: String
        let shouldMigrateURL = savedURL == "" || savedURL == "http://your-hermes-host.example.com:18642"
        if shouldMigrateURL {
            finalURL = AppConstants.defaultGatewayURL
        } else {
            finalURL = savedURL ?? AppConstants.defaultGatewayURL
        }

        gatewayURL = finalURL
        selectedModel = UserDefaults.standard.string(forKey: "selectedModel") ?? "hermes-agent"
        let savedProfile = UserDefaults.standard.string(forKey: "selectedProfile") ?? "default"
        let unsafePresetProfiles: Set<String> = ["voice", "dev", "scout", "scribe", "reach"]
        if unsafePresetProfiles.contains(savedProfile) {
            selectedProfile = "default"
            UserDefaults.standard.set("default", forKey: "selectedProfile")
        } else {
            selectedProfile = savedProfile
        }
        voiceStackURL = UserDefaults.standard.string(forKey: "voiceStackURL") ?? ""
        selectedVoice = UserDefaults.standard.string(forKey: "selectedVoice") ?? "af_heart"
        autoSendTranscript = UserDefaults.standard.object(forKey: "autoSendTranscript") as? Bool ?? false
        if let savedReplyMode = UserDefaults.standard.string(forKey: "voiceReplyMode"), let mode = VoiceReplyMode(rawValue: savedReplyMode) {
            voiceReplyMode = mode
        } else {
            voiceReplyMode = .afterVoice
            UserDefaults.standard.set(VoiceReplyMode.afterVoice.rawValue, forKey: "voiceReplyMode")
        }
        let storedSilenceTimeout = UserDefaults.standard.object(forKey: "callSilenceTimeout") as? Double
        if let storedSilenceTimeout, storedSilenceTimeout < 1.0 {
            callSilenceTimeout = storedSilenceTimeout
        } else {
            // Device testing: 1.3s felt too slow after speech detection was calibrated.
            callSilenceTimeout = 0.5
            UserDefaults.standard.set(0.5, forKey: "callSilenceTimeout")
        }
        callMinimumSpeechDuration = UserDefaults.standard.object(forKey: "callMinimumSpeechDuration") as? Double ?? 0.4
        let storedCallThreshold = UserDefaults.standard.object(forKey: "callSilenceThreshold") as? Double
        if let storedCallThreshold, (-50...(-40)).contains(storedCallThreshold) {
            callSilenceThreshold = storedCallThreshold
        } else {
            // Route testing showed AirPods speech peaks around -1..0 dB, phone speaker/mic speech can sit near -30 dB,
            // and quiet room is around -50..-60 dB. A threshold near -45 dB catches speakerphone voice while
            // still treating quiet room as silence. Earlier -35 dB was too insensitive for phone speaker mode.
            callSilenceThreshold = -45
            UserDefaults.standard.set(-45, forKey: "callSilenceThreshold")
        }
        apiToken = (try? keychain.read(account: AppConstants.tokenAccount)) ?? ""

        if shouldMigrateURL {
            UserDefaults.standard.set(finalURL, forKey: "gatewayURL")
        }
    }

    func saveToken() {
        do {
            try keychain.save(apiToken, account: AppConstants.tokenAccount)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func clearToken() {
        do {
            try keychain.delete(account: AppConstants.tokenAccount)
            apiToken = ""
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func makeClient() throws -> HermesAPIClient {
        try HermesAPIClient(baseURLString: gatewayURL, token: apiToken)
    }

    func makeVoiceClient() throws -> VoiceStackClient {
        try VoiceStackClient(baseURLString: voiceStackURL)
    }

    func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        do {
            let status = try await makeClient().status()
            statusText = [status.status, status.version, status.model].compactMap { $0 }.joined(separator: " • ")
            if statusText.isEmpty { statusText = "Connected" }
            lastError = nil
            saveToken()
            await refreshModels()
            await refreshProfiles()
            await refreshVoices()
        } catch {
            statusText = "Failed"
            lastError = error.localizedDescription
        }
    }

    func refreshModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let response = try await makeClient().models()
            var values = response.data.map(\.id)
            values.append(contentsOf: Self.defaultModelOptions)
            availableModels = Array(Set(values)).sorted { lhs, rhs in
                if lhs == selectedModel { return true }
                if rhs == selectedModel { return false }
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
            if !availableModels.contains(selectedModel) {
                availableModels.insert(selectedModel, at: 0)
            }
            lastError = nil
        } catch {
            // Model listing is optional; keep fallback presets.
            availableModels = Array(Set(Self.defaultModelOptions + [selectedModel])).sorted()
        }
    }

    func refreshProfiles() async {
        isLoadingProfiles = true
        defer { isLoadingProfiles = false }
        do {
            let response = try await makeClient().profiles()
            var profiles = response.data
            let seen = Set(profiles.map(\.id))
            for fallback in Self.defaultProfileOptions where !seen.contains(fallback) {
                profiles.append(HermesProfileInfo(id: fallback, name: fallback, active: fallback == "default", gatewayState: nil, apiServerEnabled: nil, apiServerPort: nil, apiServerReachable: nil))
            }
            availableProfiles = profiles.sorted { lhs, rhs in
                if lhs.id == selectedProfile { return true }
                if rhs.id == selectedProfile { return false }
                if lhs.active == true && rhs.active != true { return true }
                if rhs.active == true && lhs.active != true { return false }
                return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
            }
            lastError = nil
        } catch {
            availableProfiles = Self.defaultProfileOptions.map { HermesProfileInfo(id: $0, name: $0, active: $0 == "default", gatewayState: nil, apiServerEnabled: nil, apiServerPort: nil, apiServerReachable: nil) }
        }
    }

    func refreshVoices() async {
        isLoadingVoices = true
        defer { isLoadingVoices = false }
        do {
            let response = try await makeVoiceClient().voices()
            var voices = response.voices
            if voices.isEmpty {
                voices = [VoiceInfo(id: "af_heart", name: "af_heart", language: "en-US")]
            }
            availableVoices = voices.sorted { lhs, rhs in
                if lhs.id == selectedVoice { return true }
                if rhs.id == selectedVoice { return false }
                return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
            }
            if !availableVoices.contains(where: { $0.id == selectedVoice }) {
                availableVoices.insert(VoiceInfo(id: selectedVoice, name: selectedVoice, language: "en-US"), at: 0)
            }
            lastError = nil
        } catch {
            availableVoices = [VoiceInfo(id: selectedVoice, name: selectedVoice, language: "en-US"), VoiceInfo(id: "af_heart", name: "af_heart", language: "en-US")]
            lastError = "Voice refresh failed: \(error.localizedDescription)"
        }
    }
}
