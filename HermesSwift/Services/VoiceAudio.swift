import AVFoundation
import Foundation

@MainActor
final class VoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var statusText: String?
    @Published var lastError: String?
    @Published var averagePower: Float = -120
    @Published var peakPower: Float = -120

    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    private var recordingStartedAt: Date?

    var recordingDuration: TimeInterval {
        guard let recordingStartedAt else { return 0 }
        return Date().timeIntervalSince(recordingStartedAt)
    }

    func toggleRecording() async -> URL? {
        if isRecording {
            return stopRecording(status: "Transcribing…")
        }
        do {
            try await startRecording(status: "Recording… tap mic to stop")
            return nil
        } catch {
            lastError = error.localizedDescription
            statusText = "Mic unavailable"
            return nil
        }
    }

    func startRecording(status: String = "Recording…") async throws {
        guard !isRecording else { return }
        lastError = nil
        statusText = "Requesting microphone…"
        let granted = await requestMicrophonePermission()
        guard granted else {
            throw NSError(domain: "HermesSwiftVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"])
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agentone-recording-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw NSError(domain: "HermesSwiftVoice", code: 2, userInfo: [NSLocalizedDescriptionKey: "Recording failed to start"])
        }
        self.recorder = recorder
        self.currentURL = url
        self.recordingStartedAt = Date()
        self.averagePower = -120
        self.peakPower = -120
        isRecording = true
        statusText = status
    }

    func stopRecording(status: String = "Transcribing…") -> URL? {
        guard isRecording else { return nil }
        recorder?.stop()
        recorder = nil
        isRecording = false
        statusText = status
        let url = currentURL
        currentURL = nil
        recordingStartedAt = nil
        averagePower = -120
        peakPower = -120
        return url
    }

    func cancelRecording(status: String? = nil) {
        let url = currentURL
        recorder?.stop()
        recorder = nil
        isRecording = false
        currentURL = nil
        recordingStartedAt = nil
        averagePower = -120
        peakPower = -120
        if let url { try? FileManager.default.removeItem(at: url) }
        statusText = status
    }

    func updateMeters() -> Float {
        guard let recorder, isRecording else {
            averagePower = -120
            peakPower = -120
            return peakPower
        }
        recorder.updateMeters()
        averagePower = recorder.averagePower(forChannel: 0)
        peakPower = recorder.peakPower(forChannel: 0)
        return peakPower
    }

    func markTranscribing(_ active: Bool) {
        isTranscribing = active
        statusText = active ? "Transcribing…" : nil
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}

@MainActor
final class VoicePlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isSpeaking = false
    @Published var lastError: String?

    private var player: AVAudioPlayer?

    func play(fileURL: URL) {
        do {
            let session = AVAudioSession.sharedInstance()
            // `.defaultToSpeaker` / `.allowBluetoothHFP` are only valid for play-and-record.
            // Using them with `.playback` can throw OSStatus -50 on device.
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: fileURL)
            player.delegate = self
            player.prepareToPlay()
            guard player.play() else {
                throw NSError(domain: "HermesSwiftVoice", code: 50, userInfo: [NSLocalizedDescriptionKey: "Audio player refused to start playback"])
            }
            self.player = player
            isSpeaking = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            isSpeaking = false
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isSpeaking = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
