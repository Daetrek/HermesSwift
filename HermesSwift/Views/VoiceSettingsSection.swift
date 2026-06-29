import SwiftUI

struct VoiceSettingsSection: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @State private var testStatus: String?

    var body: some View {
        Section("Voice") {
            TextField("VoiceStack URL", text: $settings.voiceStackURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()

            Picker("Voice", selection: $settings.selectedVoice) {
                ForEach(settings.availableVoices) { voice in
                    Text(label(for: voice)).tag(voice.id)
                }
            }

            Toggle("Send transcript automatically", isOn: $settings.autoSendTranscript)

            Picker("Speak replies", selection: $settings.voiceReplyMode) {
                ForEach(VoiceReplyMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }

            Text(settings.voiceReplyMode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            DisclosureGroup("Call Mode Tuning") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Silence timeout: \(String(format: "%.1f", settings.callSilenceTimeout))s")
                    Slider(value: $settings.callSilenceTimeout, in: 0.3...2.5, step: 0.1)

                    Text("Minimum speech: \(String(format: "%.1f", settings.callMinimumSpeechDuration))s")
                    Slider(value: $settings.callMinimumSpeechDuration, in: 0.2...1.5, step: 0.1)

                    Text("Voice threshold: \(Int(settings.callSilenceThreshold)) dB")
                    Slider(value: $settings.callSilenceThreshold, in: -70...(-10), step: 1)

                    Text("Based on common device readings: AirPods speech is about -1 to 0 dB, phone speaker/mic speech can be around -30 dB, and quiet room is about -50 to -60 dB. Default -45 dB should catch speakerphone voice while keeping room silence quiet. If background triggers voice, move toward -35. If speech is missed, move toward -50.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button(settings.isLoadingVoices ? "Refreshing Voices…" : "Refresh Voices") {
                    Task { await settings.refreshVoices() }
                }
                .disabled(settings.isLoadingVoices)

                Spacer()

                Button("Test VoiceStack") {
                    Task { await testVoiceStack() }
                }

                Button("Test TTS") {
                    Task { await testTTS() }
                }
            }

            if let testStatus {
                Text(testStatus)
                    .font(.caption)
                    .foregroundStyle(testStatus.lowercased().contains("ok") ? TerminalTheme.text : TerminalTheme.secondaryText)
            }

            Text("PTT records on-device, sends audio to VoiceStack for transcription, then inserts the transcript into the composer. Speak replies uses VoiceStack TTS after HermesSwift finishes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func label(for voice: VoiceInfo) -> String {
        let name = voice.name ?? voice.id
        if let language = voice.language, !language.isEmpty {
            return "\(name) • \(language)"
        }
        return name
    }

    private func testVoiceStack() async {
        do {
            let health = try await settings.makeVoiceClient().health()
            testStatus = "OK • \(health.service ?? "VoiceStack")"
            await settings.refreshVoices()
        } catch {
            testStatus = "VoiceStack failed: \(error.localizedDescription)"
        }
    }

    private func testTTS() async {
        do {
            let file = try await settings.makeVoiceClient().speech(text: "HermesSwift voice test is working.", voice: settings.selectedVoice)
            testStatus = "TTS OK • \(file.lastPathComponent)"
        } catch {
            testStatus = "TTS failed: \(error.localizedDescription)"
        }
    }
}
