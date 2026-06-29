import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers
import Vision
import PDFKit
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

struct ChatView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var organization: SessionOrganizationStore
    @Environment(\.scenePhase) private var scenePhase
    let session: HermesSession
    @State private var draft = ""
    @StateObject private var recorder = VoiceRecorder()
    @StateObject private var playback = VoicePlayback()
    @State private var spokenAssistantStableID: String?
    @State private var draftCameFromVoice = false
    @State private var lastSubmittedPromptWasVoice = false
    @State private var isCallActive = false
    @State private var callStatus: String?
    @State private var callMonitorTask: Task<Void, Never>?
    @State private var callLevelSamples: [Float] = Array(repeating: -120, count: 18)
    @State private var callLiveLevel: Float = -120
    @State private var callStartedAt: Date?
    @State private var callPausedForNoSpeech = false
    @State private var callStartMessageCount = 0
    @State private var callContextInjected = false
    @State private var selectedCallIntent = VoiceCallIntent.defaultIntent
    @State private var endedCall: EndedCallInfo?
    @State private var isHoldRecording = false
    @State private var replacementSession: HermesSession?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showingDocumentPicker = false
    @State private var attachmentStatus: String?
    @State private var isProcessingAttachment = false
    @State private var pendingAttachments: [HermesAttachment] = []
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if store.isLoadingMessages && store.messages.isEmpty {
                            ProgressView("Loading transcript…")
                                .frame(maxWidth: .infinity)
                                .padding(.top, 32)
                        }

                        ForEach(store.messages, id: \.stableID) { message in
                            MessageBubble(message: message)
                                .id(message.stableID)
                        }

                        if store.isSending {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(store.streamStatus ?? "HermesSwift is working…")
                                    .lineLimit(2)
                                Spacer()
                                Button(role: .destructive) { store.cancelSend() } label: {
                                    Label("Stop", systemImage: "stop.circle.fill")
                                        .labelStyle(.titleAndIcon)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .font(.caption)
                            .foregroundStyle(TerminalTheme.secondaryText)
                            .padding(.horizontal)
                        }

                        if let endedCall {
                            EndedCallCard(
                                info: endedCall,
                                transcriptPreview: callTranscriptPreview,
                                onSummarize: { summarizeEndedCall() },
                                onCopyTranscript: { copyCallTranscript() },
                                onKeepPinned: { organization.setPinned(activeSession, pinned: true) },
                                onDismiss: { self.endedCall = nil }
                            )
                            .id("ended-call-card")
                        }

                        if store.missingSession?.id == activeSession.id {
                            MissingSessionRecoveryCard(
                                sessionID: activeSession.id,
                                onArchive: { organization.setArchived(activeSession, archived: true) },
                                onReplace: { Task { await startReplacementChat() } }
                            )
                            .id("missing-session-recovery")
                        }

                        if let error = store.lastError {
                            ErrorBubble(error: error)
                                .id("last-error")
                        }
                    }
                    .padding()
                }
                .background(TerminalTheme.background)
                .scrollContentBackground(.hidden)
                .onChange(of: store.messages.count) { _, _ in scrollToBottom(proxy) }
                .onChange(of: store.lastError) { _, _ in scrollToBottom(proxy) }
                .onChange(of: store.streamStatus) { _, _ in scrollToBottom(proxy) }
            }

            Divider()

            VStack(spacing: 6) {
                HStack(alignment: .bottom, spacing: 10) {
                    Menu {
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            Label("Attach photo or screenshot", systemImage: "photo.on.rectangle")
                        }
                        Button {
                            Haptics.light()
                            showingDocumentPicker = true
                        } label: {
                            Label("Attach document or log", systemImage: "doc.badge.plus")
                        }
                        Button {
                            attachClipboardText()
                        } label: {
                            Label("Paste clipboard and ask", systemImage: "doc.on.clipboard")
                        }
                    } label: {
                        Image(systemName: "paperclip.circle.fill")
                            .font(.title2)
                            .foregroundStyle(TerminalTheme.text)
                    }
                    .disabled(store.isSending || isProcessingAttachment)
                    .accessibilityLabel("Attach photo screenshot document or clipboard")

                    Button { Task { Haptics.light(); await handleMicTapped() } } label: {
                        Image(systemName: micIconName)
                            .font(.title2)
                            .foregroundStyle(micColor)
                    }
                    .onLongPressGesture(minimumDuration: 0.25, pressing: { pressing in
                        if !pressing && isHoldRecording {
                            Task { await finishHoldToTalk() }
                        }
                    }, perform: {
                        Task { await startHoldToTalk() }
                    })
                    .disabled(store.isSending || recorder.isTranscribing || (isCallActive && !isHoldRecording))
                    .accessibilityLabel(micAccessibilityLabel)

                    Button { Task { Haptics.medium(); await toggleCallMode() } } label: {
                        Image(systemName: isCallActive ? "phone.down.circle.fill" : "phone.circle.fill")
                            .font(.title2)
                            .foregroundStyle(isCallActive ? .red : TerminalTheme.text)
                    }
                    .disabled(store.isSending && !isCallActive)
                    .accessibilityLabel(isCallActive ? "End HermesSwift call" : "Start HermesSwift call")

                    Menu {
                        Button { runCommand(.analyzeScreenshot) } label: { Label("Analyze attached screenshot", systemImage: "photo.badge.magnifyingglass") }
                        Button { runCommand(.summarizeChat) } label: { Label("Summarize this chat", systemImage: "text.badge.checkmark") }
                        Button { runCommand(.extractTasks) } label: { Label("Extract tasks", systemImage: "checklist") }
                        Button { runCommand(.debugLastError) } label: { Label("Debug latest error", systemImage: "ladybug.fill") }
                        Button { runCommand(.explainLastAnswer) } label: { Label("Explain last answer", systemImage: "questionmark.bubble.fill") }
                        Divider()
                        Button { copyLastAssistantAnswer() } label: { Label("Copy last answer", systemImage: "doc.on.doc") }
                        Button { Task { await speakLastAssistantAnswer() } } label: { Label("Speak last answer", systemImage: "speaker.wave.2.fill") }
                        Divider()
                        Button { renameFromTopic() } label: { Label("Rename from topic", systemImage: "text.cursor") }
                        Button { organization.setPinned(activeSession, pinned: true); attachmentStatus = "Chat pinned"; Haptics.success() } label: { Label("Pin chat", systemImage: "pin.fill") }
                        Button { organization.setArchived(activeSession, archived: true); attachmentStatus = "Chat archived locally"; Haptics.success() } label: { Label("Archive chat", systemImage: "archivebox.fill") }
                    } label: {
                        Image(systemName: "bolt.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.yellow)
                    }
                    .disabled(store.isSending)
                    .accessibilityLabel("Command palette")

                    TextField("Message HermesSwift…", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .background(TerminalTheme.fieldFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(TerminalTheme.faintBorder, lineWidth: 0.8) }
                        .foregroundStyle(TerminalTheme.text)
                        .focused($composerFocused)
                        .submitLabel(.send)
                        .onChange(of: draft) { _, newValue in
                            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                draftCameFromVoice = false
                            }
                        }
                        .onSubmit { submitDraft() }

                    Button { Haptics.light(); submitDraft() } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(store.isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send")
                }

                if !pendingAttachments.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(pendingAttachments) { attachment in
                            PendingAttachmentCard(
                                attachment: attachment,
                                onRemove: { pendingAttachments.removeAll { $0.id == attachment.id } }
                            )
                        }
                    }
                }

                if let attachmentStatus {
                    HStack(spacing: 6) {
                        if isProcessingAttachment { ProgressView().controlSize(.mini) }
                        Text(attachmentStatus)
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(TerminalTheme.secondaryText)
                }

                if let voiceStatus = voiceStatusText {
                    HStack(spacing: 6) {
                        if recorder.isTranscribing || playback.isSpeaking || isCallActive { ProgressView().controlSize(.mini) }
                        Text(voiceStatus)
                        Spacer()
                        if playback.isSpeaking {
                            Button("Stop voice") { playback.stop() }
                                .buttonStyle(.borderless)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(TerminalTheme.secondaryText)
                }
            }
            .padding()
            .background(TerminalTheme.background)
        }
        .background(TerminalTheme.background.ignoresSafeArea())
        .foregroundStyle(TerminalTheme.text)
        .overlay(alignment: .bottom) {
            if isCallActive {
                CallModeOverlay(
                    status: callStatus ?? "Call: active",
                    level: callLiveLevel,
                    threshold: Float(settings.callSilenceThreshold),
                    levels: callLevelSamples,
                    isListening: recorder.isRecording,
                    isTranscribing: recorder.isTranscribing,
                    isSending: store.isSending,
                    isSpeaking: playback.isSpeaking,
                    isPaused: callPausedForNoSpeech,
                    elapsed: callElapsedText,
                    selectedIntent: selectedCallIntent,
                    onSelectIntent: { selectedCallIntent = $0 },
                    onEnd: { endCallMode() },
                    onResume: { Task { await resumeCallListening() } },
                    onInterrupt: { Task { await interruptCallSpeechAndListen() } }
                )
                .padding(.horizontal)
                .padding(.bottom, 92)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isCallActive)
        .navigationTitle(organization.displayTitle(for: activeSession))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                    ProfilePillMenu()
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(store.isLoadingMessages || store.isSending)
                }
            }
        }
        .task { await load() }
        .fileImporter(isPresented: $showingDocumentPicker, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            handleDocumentImport(result)
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task { await processPhotoItem(newItem) }
        }
        .refreshable { await load() }
        .onChange(of: store.isSending) { oldValue, newValue in
            if oldValue == true && newValue == false {
                Task {
                    let spoke = await speakLatestAssistantIfNeeded()
                    if isCallActive && !spoke && !playback.isSpeaking {
                        await beginCallListening()
                    }
                }
            }
        }
        .onChange(of: playback.isSpeaking) { oldValue, newValue in
            if oldValue == true && newValue == false && isCallActive {
                Task { await beginCallListening() }
            }
        }
        .onDisappear { endCallMode() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            Task { await handleAudioInterruption(notification) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
            handleRouteChange(notification)
        }
        .onChange(of: scenePhase) { _, newPhase in
            Task { await handleScenePhase(newPhase) }
        }
    }

    private var activeSession: HermesSession {
        replacementSession ?? session
    }

    private var voiceStatusText: String? {
        if let error = recorder.lastError { return "Voice error: \(error)" }
        if let error = playback.lastError { return "Playback error: \(error)" }
        if let callStatus { return callStatus }
        if let status = recorder.statusText { return status }
        if playback.isSpeaking { return "Speaking HermesSwift reply…" }
        return nil
    }

    private var callElapsedText: String {
        guard let callStartedAt else { return "00:00" }
        let seconds = max(0, Int(Date().timeIntervalSince(callStartedAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var micIconName: String {
        if isHoldRecording { return "mic.fill" }
        if recorder.isRecording { return "stop.circle.fill" }
        return "mic.circle.fill"
    }

    private var micColor: Color {
        if isHoldRecording || recorder.isRecording { return .red }
        return TerminalTheme.text
    }

    private var micAccessibilityLabel: String {
        if isHoldRecording { return "Release to send voice message" }
        if recorder.isRecording { return "Stop recording" }
        return "Record voice"
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if let last = store.messages.last {
            withAnimation { proxy.scrollTo(last.stableID, anchor: .bottom) }
        } else if store.lastError != nil {
            withAnimation { proxy.scrollTo("last-error", anchor: .bottom) }
        }
    }

    private func load() async {
        guard let client = try? settings.makeClient() else { return }
        await store.loadMessages(client: client, session: activeSession)
    }

    private func uploadAttachment(data: Data, filename: String, mimeType: String) async throws -> HermesAttachment {
        guard let client = try? settings.makeClient() else { throw HermesAPIClient.APIError.invalidBaseURL }
        return try await client.uploadAttachment(sessionID: activeSession.id, data: data, filename: filename, mimeType: mimeType)
    }

    private func attachClipboardText() {
        #if canImport(UIKit)
        Haptics.light()
        let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            attachmentStatus = "Clipboard is empty"
            Haptics.warning()
            return
        }
        let capped = capText(text, limit: 16_000)
        draft = """
        Review this clipboard text and tell me what matters, what is wrong, and what to do next.

        ```text
        \(capped)
        ```
        """
        draftCameFromVoice = false
        attachmentStatus = "Clipboard text inserted"
        Haptics.success()
        composerFocused = true
        #endif
    }

    private func processPhotoItem(_ item: PhotosPickerItem) async {
        isProcessingAttachment = true
        attachmentStatus = "Reading image…"
        defer {
            isProcessingAttachment = false
            selectedPhotoItem = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                attachmentStatus = "Could not read selected image"
                Haptics.warning()
                return
            }
            attachmentStatus = "Uploading screenshot…"
            let mimeType = "image/jpeg"
            let attachment = try await uploadAttachment(data: data, filename: "screenshot.jpg", mimeType: mimeType)
            pendingAttachments.append(attachment)
            attachmentStatus = "Screenshot uploaded for vision"
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft = "Analyze this screenshot/photo for you. Focus on what is wrong, likely root cause, and the next concrete action."
            }
            Haptics.success()
            composerFocused = true
        } catch {
            attachmentStatus = "Image attach failed: \(error.localizedDescription)"
            Haptics.error()
        }
    }

    private func handleDocumentImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await processDocumentURL(url) }
        case .failure(let error):
            attachmentStatus = "Document picker failed: \(error.localizedDescription)"
            Haptics.error()
        }
    }

    private func processDocumentURL(_ url: URL) async {
        isProcessingAttachment = true
        attachmentStatus = "Reading document…"
        defer { isProcessingAttachment = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .localizedNameKey])
            let data = try Data(contentsOf: url)
            let name = values.localizedName ?? url.lastPathComponent
            let type = values.contentType?.preferredMIMEType ?? values.contentType?.identifier ?? url.pathExtension
            attachmentStatus = "Uploading document…"
            let attachment = try await uploadAttachment(data: data, filename: name, mimeType: type)
            pendingAttachments.append(attachment)
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft = attachment.isImage
                    ? "Analyze this image for you. Focus on what is wrong, likely root cause, and the next concrete action."
                    : "Review this attached file for you. Tell me what matters, what is wrong, and what to do next."
            }
            attachmentStatus = "Document uploaded"
            Haptics.success()
            composerFocused = true
        } catch {
            attachmentStatus = "Document attach failed: \(error.localizedDescription)"
            Haptics.error()
        }
    }

    private func attachmentPrompt(kind: String, name: String, metadata: [String], extractedText: String, emptyExtractionNote: String) -> String {
        let cleanText = extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = cleanText.isEmpty ? emptyExtractionNote : capText(cleanText, limit: 18_000)
        let metadataText = metadata.filter { !$0.isEmpty }.joined(separator: "\n")
        return """
        Analyze this \(kind) for you. Focus on what is wrong, likely root cause, and the next concrete action.

        Attachment: \(name)
        \(metadataText)

        Extracted content:
        ```text
        \(body)
        ```
        """
    }

    private func extractText(from data: Data, url: URL, contentType: UTType?) throws -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" || contentType?.conforms(to: .pdf) == true {
            guard let pdf = PDFDocument(data: data) else { return "" }
            return (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n\n")
        }
        if contentType?.conforms(to: .image) == true {
            return awaitlessImageOCR(data)
        }
        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) {
            return text
        }
        return ""
    }

    private func awaitlessImageOCR(_ data: Data) -> String {
        // Synchronous fallback for imported image files. Photos use the async OCR path.
        guard let cgImage = CGImageSourceCreateWithData(data as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage)
        try? handler.perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
    }

    private func recognizeText(in data: Data) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "" }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage)
            try handler.perform([request])
            return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
        }.value
    }

    private func imageDimensions(data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return "Dimensions: \(width)×\(height)"
    }

    private func capText(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let prefix = text.prefix(limit)
        return "\(prefix)\n\n[Truncated locally to \(limit) characters before sending from iPhone.]"
    }

    private var callTranscriptPreview: String {
        callTranscriptLines(limit: 8).joined(separator: "\n")
    }

    private func callTranscriptLines(limit: Int? = nil) -> [String] {
        let callMessages = store.messages.suffix(max(0, store.messages.count - callStartMessageCount))
        let lines = callMessages.compactMap { message -> String? in
            let text = (message.content ?? message.reasoningContent ?? message.reasoning ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let speaker = message.role.lowercased() == "user" ? "you" : (message.role.lowercased() == "assistant" ? "HermesSwift" : message.role.capitalized)
            return "\(speaker): \(text)"
        }
        if let limit { return Array(lines.prefix(limit)) }
        return lines
    }

    private func summarizeEndedCall() {
        let transcript = callTranscriptLines().joined(separator: "\n")
        let fallback = transcript.isEmpty ? "Use the current session transcript." : transcript
        let prompt = """
        Summarize this voice call for you.

        Return concise sections:
        - Summary
        - Decisions
        - Tasks / follow-ups
        - Important context to remember

        Call intent: \(endedCall?.intent.title ?? selectedCallIntent.title)
        Call duration: \(endedCall?.duration ?? callElapsedText)

        Transcript:
        \(fallback)
        """
        sendText(prompt, promptWasVoice: false)
    }

    private func copyCallTranscript() {
        #if canImport(UIKit)
        UIPasteboard.general.string = callTranscriptLines().joined(separator: "\n")
        #endif
    }

    private func prepareVoiceCallSession() {
        organization.setPinned(activeSession, pinned: true)
        let currentTitle = organization.displayTitle(for: activeSession)
        let lower = currentTitle.lowercased()
        guard lower.hasPrefix("iphone ") || lower.hasPrefix("voice call") || lower == "new chat" || lower.contains("untitled") else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        organization.rename(activeSession, to: "Call • \(selectedCallIntent.title) • \(formatter.string(from: Date()))")
    }

    private func injectCallIntentIfNeeded(into transcript: String) -> String {
        guard !callContextInjected else { return transcript }
        callContextInjected = true
        guard !selectedCallIntent.prompt.isEmpty else { return transcript }
        return """
        [Voice call context: \(selectedCallIntent.prompt)]

        \(transcript)
        """
    }

    private func startReplacementChat() async {
        guard let client = try? settings.makeClient() else { return }
        organization.setArchived(activeSession, archived: true)
        let baseTitle = organization.displayTitle(for: activeSession)
        let title = baseTitle.hasPrefix("Replacement for") ? baseTitle : "Replacement for \(baseTitle)"
        if let created = await store.createSession(client: client, title: title, model: settings.selectedModelForRequest, profile: settings.selectedProfileForRequest) {
            replacementSession = created
            organization.togglePinned(created)
            await store.loadMessages(client: client, session: created)
        }
    }

    private func toggleCallMode() async {
        if isCallActive {
            endCallMode()
            return
        }
        isCallActive = true
        endedCall = nil
        callStartedAt = Date()
        callStartMessageCount = store.messages.count
        callContextInjected = false
        callPausedForNoSpeech = false
        callLiveLevel = -120
        callLevelSamples = Array(repeating: -120, count: 18)
        callStatus = "Call: starting…"
        playback.stop()
        if recorder.isRecording { recorder.cancelRecording() }
        prepareVoiceCallSession()
        await beginCallListening()
    }

    private func endCallMode() {
        let startedAt = callStartedAt
        let elapsedText = callElapsedText
        let messageDelta = max(0, store.messages.count - callStartMessageCount)
        let shouldShowEndedCard = isCallActive && startedAt != nil
        isCallActive = false
        callStatus = nil
        callStartedAt = nil
        callPausedForNoSpeech = false
        callLiveLevel = -120
        callLevelSamples = Array(repeating: -120, count: 18)
        callMonitorTask?.cancel()
        callMonitorTask = nil
        if recorder.isRecording { recorder.cancelRecording(status: nil) }
        isHoldRecording = false
        if shouldShowEndedCard {
            endedCall = EndedCallInfo(intent: selectedCallIntent, duration: elapsedText, messageCount: messageDelta, endedAt: Date())
        }
    }

    private func beginCallListening() async {
        guard isCallActive, !callPausedForNoSpeech, !store.isSending, !playback.isSpeaking, !recorder.isRecording, !recorder.isTranscribing else { return }
        do {
            try await recorder.startRecording(status: "Call: listening…")
            callStatus = "Call: listening…"
            startCallMonitor()
        } catch {
            recorder.lastError = error.localizedDescription
            endCallMode()
        }
    }

    private func startCallMonitor() {
        callMonitorTask?.cancel()
        callMonitorTask = Task { @MainActor in
            var heardSpeech = false
            var silenceStartedAt: Date?
            let noSpeechStartedAt = Date()
            while !Task.isCancelled && isCallActive && recorder.isRecording {
                try? await Task.sleep(nanoseconds: 120_000_000)
                let peakPower = recorder.updateMeters()
                callLiveLevel = peakPower
                appendCallLevel(peakPower)
                let isVoice = peakPower > Float(settings.callSilenceThreshold)
                let levelText = "\(Int(peakPower)) dB"
                if isVoice {
                    heardSpeech = true
                    silenceStartedAt = nil
                    callStatus = "Call: listening — voice \(levelText)"
                    continue
                }
                if !heardSpeech {
                    if Date().timeIntervalSince(noSpeechStartedAt) >= 45 {
                        callPausedForNoSpeech = true
                        callStatus = "Call paused — no speech detected"
                        recorder.cancelRecording(status: nil)
                        break
                    }
                    callStatus = "Call: listening — silence \(levelText)"
                    continue
                }
                callStatus = "Call: silence \(levelText) — sending soon"
                guard recorder.recordingDuration >= settings.callMinimumSpeechDuration else { continue }
                if recorder.recordingDuration >= 18 {
                    let audioURL = recorder.stopRecording(status: "Call: transcribing…")
                    await processCallAudio(audioURL)
                    break
                }
                if silenceStartedAt == nil { silenceStartedAt = Date() }
                if let silenceStartedAt, Date().timeIntervalSince(silenceStartedAt) >= settings.callSilenceTimeout {
                    let audioURL = recorder.stopRecording(status: "Call: transcribing…")
                    await processCallAudio(audioURL)
                    break
                }
            }
        }
    }

    private func appendCallLevel(_ level: Float) {
        callLevelSamples.append(level)
        if callLevelSamples.count > 18 {
            callLevelSamples.removeFirst(callLevelSamples.count - 18)
        }
    }

    private func resumeCallListening() async {
        guard isCallActive else { return }
        callPausedForNoSpeech = false
        recorder.lastError = nil
        playback.lastError = nil
        callStatus = "Call: resuming…"
        await beginCallListening()
    }

    private func interruptCallSpeechAndListen() async {
        guard isCallActive else { return }
        if playback.isSpeaking { playback.stop() }
        if store.isSending { store.cancelSend() }
        if recorder.isRecording { recorder.cancelRecording(status: nil) }
        callPausedForNoSpeech = false
        callStatus = "Call: interrupted — listening…"
        await beginCallListening()
    }

    private func handleAudioInterruption(_ notification: Notification) async {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }
        switch type {
        case .began:
            if recorder.isRecording { recorder.cancelRecording(status: nil) }
            if playback.isSpeaking { playback.stop() }
            if isCallActive {
                callPausedForNoSpeech = true
                callStatus = "Call paused — audio interrupted"
            }
        case .ended:
            guard isCallActive else { return }
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            callStatus = options.contains(.shouldResume) ? "Call: audio resumed" : "Call: tap Resume when ready"
            if options.contains(.shouldResume) {
                callPausedForNoSpeech = false
                await beginCallListening()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard isCallActive else { return }
        let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw)
        let route = AVAudioSession.sharedInstance().currentRoute
        let outputs = route.outputs.map(\.portName).joined(separator: ", ")
        let suffix = outputs.isEmpty ? "audio route changed" : "audio route: \(outputs)"
        switch reason {
        case .newDeviceAvailable:
            callStatus = "Call: Bluetooth/audio connected — \(suffix)"
        case .oldDeviceUnavailable:
            callStatus = "Call: audio device disconnected — \(suffix)"
        case .categoryChange:
            callStatus = "Call: audio route refreshed — \(suffix)"
        default:
            callStatus = "Call: \(suffix)"
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) async {
        guard isCallActive else { return }
        switch phase {
        case .background:
            callStatus = "Call continues in background audio mode"
        case .inactive:
            callStatus = "Call: app inactive — audio holding"
        case .active:
            if callPausedForNoSpeech {
                callStatus = "Call paused — tap Resume"
            } else if !recorder.isRecording && !store.isSending && !playback.isSpeaking && !recorder.isTranscribing {
                callStatus = "Call: foreground — listening…"
                await beginCallListening()
            }
        @unknown default:
            break
        }
    }

    private func processCallAudio(_ audioURL: URL?) async {
        guard isCallActive else { return }
        guard let audioURL else {
            await beginCallListening()
            return
        }
        recorder.markTranscribing(true)
        callStatus = "Call: transcribing…"
        defer { recorder.markTranscribing(false) }
        do {
            let transcript = try await transcribeWithRetry(audioURL: audioURL)
            guard isCallActive else { return }
            let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTranscript.isEmpty else {
                callStatus = "Call: didn’t catch that — listening again"
                await beginCallListening()
                return
            }
            callStatus = "Call: sending…"
            sendText(injectCallIntentIfNeeded(into: trimmedTranscript), promptWasVoice: true)
        } catch {
            callStatus = "Call: transcription failed — listening again"
            recorder.lastError = error.localizedDescription
            if isCallActive { await beginCallListening() }
        }
    }

    private func startHoldToTalk() async {
        guard !isCallActive, !store.isSending, !recorder.isRecording, !recorder.isTranscribing else { return }
        if playback.isSpeaking { playback.stop() }
        do {
            try await recorder.startRecording(status: "Hold recording… release to send")
            isHoldRecording = true
        } catch {
            recorder.lastError = error.localizedDescription
        }
    }

    private func finishHoldToTalk() async {
        guard isHoldRecording else { return }
        isHoldRecording = false
        let audioURL = recorder.stopRecording(status: "Transcribing held message…")
        await transcribeOneShot(audioURL: audioURL, autoSend: true)
    }

    private func transcribeOneShot(audioURL: URL?, autoSend: Bool) async {
        guard let audioURL else { return }
        recorder.markTranscribing(true)
        defer { recorder.markTranscribing(false) }
        do {
            let transcript = try await withTimeout(seconds: 20, label: "Voice transcription timed out") {
                try await settings.makeVoiceClient().transcribe(audioURL: audioURL)
            }
            if autoSend || settings.autoSendTranscript {
                draft = transcript
                submitDraft(promptWasVoice: true)
            } else {
                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    draft = transcript
                } else {
                    draft += "\n" + transcript
                }
                draftCameFromVoice = true
                composerFocused = true
            }
        } catch {
            recorder.lastError = error.localizedDescription
        }
    }

    private func handleMicTapped() async {
        guard !isHoldRecording else { return }
        if playback.isSpeaking { playback.stop() }
        let maybeAudioURL = await recorder.toggleRecording()
        guard let audioURL = maybeAudioURL else { return }
        await transcribeOneShot(audioURL: audioURL, autoSend: false)
    }

    private func speakLatestAssistantIfNeeded() async -> Bool {
        let shouldSpeak: Bool
        if isCallActive {
            shouldSpeak = true
        } else {
            switch settings.voiceReplyMode {
            case .never:
                shouldSpeak = false
            case .afterVoice:
                shouldSpeak = lastSubmittedPromptWasVoice
            case .always:
                shouldSpeak = true
            }
        }
        guard shouldSpeak else { return false }
        guard let latest = store.messages.last(where: { $0.role.lowercased() == "assistant" }) else { return false }
        guard latest.stableID != spokenAssistantStableID else { return false }
        let text = (latest.content ?? latest.reasoningContent ?? latest.reasoning ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        spokenAssistantStableID = latest.stableID
        if settings.voiceReplyMode == .afterVoice {
            lastSubmittedPromptWasVoice = false
        }
        if isCallActive { callStatus = "Call: speaking…" }
        do {
            let file = try await withTimeout(seconds: 25, label: "Speech playback request timed out") {
                try await settings.makeVoiceClient().speech(text: text, voice: settings.selectedVoice)
            }
            playback.play(fileURL: file)
            if !playback.isSpeaking, isCallActive {
                callStatus = "Call: playback failed"
                await beginCallListening()
            }
            return playback.isSpeaking
        } catch {
            callStatus = "Call: speech playback failed — listening again"
            playback.lastError = error.localizedDescription
            if isCallActive { await beginCallListening() }
            return false
        }
    }

    private func transcribeWithRetry(audioURL: URL) async throws -> String {
        do {
            return try await withTimeout(seconds: 20, label: "Voice transcription timed out") {
                try await settings.makeVoiceClient().transcribe(audioURL: audioURL)
            }
        } catch {
            callStatus = "Call: transcription retry…"
            return try await withTimeout(seconds: 20, label: "Voice transcription retry timed out") {
                try await settings.makeVoiceClient().transcribe(audioURL: audioURL)
            }
        }
    }

    private func withTimeout<T: Sendable>(seconds: Double, label: String, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                let ns = UInt64(max(0.1, seconds) * 1_000_000_000)
                try await Task.sleep(nanoseconds: ns)
                throw TimeoutError(label)
            }
            guard let value = try await group.next() else { throw TimeoutError(label) }
            group.cancelAll()
            return value
        }
    }

    private struct TimeoutError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private enum ChatCommand {
        case analyzeScreenshot
        case summarizeChat
        case extractTasks
        case debugLastError
        case explainLastAnswer
    }

    private func runCommand(_ command: ChatCommand) {
        Haptics.light()
        switch command {
        case .analyzeScreenshot:
            let imageAttachments = pendingAttachments.filter(\.isImage)
            guard !imageAttachments.isEmpty else {
                attachmentStatus = "Attach a screenshot first"
                Haptics.warning()
                return
            }
            pendingAttachments.removeAll { imageAttachments.map(\.id).contains($0.id) }
            sendText("Analyze this screenshot/photo for you. Focus on visible UI problems, likely root cause, and the next concrete tap/action.", promptWasVoice: false, attachments: imageAttachments)
        case .summarizeChat:
            sendText("""
            Summarize this chat for you.

            Return concise sections:
            - Summary
            - Decisions
            - Tasks / follow-ups
            - Important context

            Recent transcript:
            \(recentTranscript(limit: 14))
            """, promptWasVoice: false)
        case .extractTasks:
            sendText("""
            Extract concrete tasks from this chat for you.

            Return:
            - Task
            - Owner if obvious
            - Priority
            - Blocker/dependency if any

            Recent transcript:
            \(recentTranscript(limit: 18))
            """, promptWasVoice: false)
        case .debugLastError:
            sendText("""
            Debug the latest error or failure signal in this chat.

            Focus on:
            - likely root cause
            - what evidence supports it
            - exact next checks
            - safest fix path

            Recent transcript:
            \(recentTranscript(limit: 20))
            """, promptWasVoice: false)
        case .explainLastAnswer:
            guard let answer = latestAssistantText() else {
                attachmentStatus = "No assistant answer to explain"
                Haptics.warning()
                return
            }
            sendText("""
            Explain your last answer more simply and practically for you.

            Last answer:
            \(answer)
            """, promptWasVoice: false)
        }
    }

    private func recentTranscript(limit: Int) -> String {
        let lines = store.messages.suffix(limit).compactMap { message -> String? in
            let text = (message.content ?? message.reasoningContent ?? message.reasoning ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let speaker = message.role.lowercased() == "user" ? "you" : (message.role.lowercased() == "assistant" ? "HermesSwift" : message.role.capitalized)
            return "\(speaker): \(capText(text, limit: 2_000))"
        }
        return lines.isEmpty ? "[No recent transcript available.]" : lines.joined(separator: "\n\n")
    }

    private func latestAssistantText() -> String? {
        guard let latest = store.messages.last(where: { $0.role.lowercased() == "assistant" }) else { return nil }
        let text = (latest.content ?? latest.reasoningContent ?? latest.reasoning ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func copyLastAssistantAnswer() {
        guard let text = latestAssistantText() else {
            attachmentStatus = "No assistant answer to copy"
            Haptics.warning()
            return
        }
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
        attachmentStatus = "Last answer copied"
        Haptics.success()
    }

    private func speakLastAssistantAnswer() async {
        guard let text = latestAssistantText() else {
            attachmentStatus = "No assistant answer to speak"
            Haptics.warning()
            return
        }
        if playback.isSpeaking { playback.stop() }
        attachmentStatus = "Speaking last answer…"
        do {
            let file = try await withTimeout(seconds: 25, label: "Speech playback request timed out") {
                try await settings.makeVoiceClient().speech(text: text, voice: settings.selectedVoice)
            }
            playback.play(fileURL: file)
            attachmentStatus = playback.isSpeaking ? "Speaking last answer" : "Speech playback failed"
            if playback.isSpeaking { Haptics.success() } else { Haptics.warning() }
        } catch {
            playback.lastError = error.localizedDescription
            attachmentStatus = "Speak failed: \(error.localizedDescription)"
            Haptics.error()
        }
    }

    private func renameFromTopic() {
        let candidates = store.messages.reversed().compactMap { message -> String? in
            guard message.role.lowercased() == "user" else { return nil }
            let text = (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return text
        }
        guard let source = candidates.first else {
            attachmentStatus = "No user topic to rename from"
            Haptics.warning()
            return
        }
        let cleaned = source
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = cleaned.split(separator: " ").prefix(7).joined(separator: " ")
        let title = words.count > 48 ? String(words.prefix(48)) : words
        organization.rename(activeSession, to: title.isEmpty ? "HermesSwift Chat" : title)
        attachmentStatus = "Renamed locally"
        Haptics.success()
    }

    private func submitDraft(promptWasVoice: Bool? = nil) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !store.isSending else { return }
        let cameFromVoice = promptWasVoice ?? draftCameFromVoice
        let attachments = pendingAttachments
        draft = ""
        pendingAttachments = []
        draftCameFromVoice = false
        sendText(text, promptWasVoice: cameFromVoice, attachments: attachments)
        composerFocused = false
    }

    private func sendText(_ text: String, promptWasVoice: Bool, attachments: [HermesAttachment] = []) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !store.isSending else { return }
        lastSubmittedPromptWasVoice = promptWasVoice
        guard let client = try? settings.makeClient() else { return }
        store.startSend(client: client, text: text, model: settings.selectedModelForRequest, profile: settings.selectedProfileForRequest, attachments: attachments)
    }
}

private struct PendingAttachmentCard: View {
    let attachment: HermesAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: attachment.isImage ? "photo.fill" : "doc.text.fill")
                .foregroundStyle(attachment.isImage ? TerminalTheme.text : .blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("\(attachment.mimeType) • \(attachment.displaySize)")
                    .font(.caption2)
                    .foregroundStyle(TerminalTheme.secondaryText)
            }
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(TerminalTheme.secondaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove attachment")
        }
        .padding(8)
        .background(TerminalTheme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(TerminalTheme.faintBorder, lineWidth: 0.8) }
    }
}

private struct VoiceCallIntent: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    let prompt: String

    static let defaultIntent = VoiceCallIntent(id: "quick", title: "Quick", icon: "bolt.fill", prompt: "Answer directly and keep the voice exchange concise.")

    static let all: [VoiceCallIntent] = [
        .defaultIntent,
        .init(id: "debug", title: "Debug", icon: "ladybug.fill", prompt: "Debug with you. Ask targeted questions, reason step-by-step, and focus on root cause before fixes."),
        .init(id: "brainstorm", title: "Brainstorm", icon: "lightbulb.fill", prompt: "Brainstorm with you. Generate options, tradeoffs, and practical next moves."),
        .init(id: "plan", title: "Plan", icon: "checklist", prompt: "Help you plan. Convert the conversation into prioritized steps and decisions."),
        .init(id: "notes", title: "Notes", icon: "note.text", prompt: "Act as a note taker. Capture facts, decisions, tasks, and follow-ups cleanly."),
        .init(id: "driving", title: "Driving", icon: "car.fill", prompt: "you may be driving. Keep replies short, spoken, and low-friction; avoid long lists unless asked.")
    ]
}

private struct EndedCallInfo: Equatable {
    let intent: VoiceCallIntent
    let duration: String
    let messageCount: Int
    let endedAt: Date
}

private struct ProfilePillMenu: View {
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        Menu {
            ForEach(settings.availableProfiles) { profile in
                Button {
                    settings.selectedProfile = profile.id
                } label: {
                    Label(profileLabel(profile), systemImage: profile.id == settings.selectedProfile ? "checkmark.circle.fill" : profileIcon(profile.id))
                }
                .disabled(!isSelectable(profile))
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: profileIcon(settings.selectedProfile))
                Text(settings.selectedProfile)
                    .lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(TerminalTheme.text.opacity(0.18), in: Capsule())
            .overlay {
                Capsule().strokeBorder(TerminalTheme.text.opacity(0.35), lineWidth: 0.8)
            }
        }
        .accessibilityLabel("Switch Hermes profile")
    }

    private func profileLabel(_ profile: HermesProfileInfo) -> String {
        let name = profile.name?.isEmpty == false ? profile.name! : profile.id
        if profile.id == "default" { return "\(name) • default" }
        if profile.apiServerReachable == true { return "\(name) • API ready" }
        if profile.apiServerEnabled == false { return "\(name) • no API server" }
        if profile.apiServerReachable == false { return "\(name) • API offline" }
        if profile.active == true { return "\(name) • active" }
        return "\(name) • unavailable"
    }

    private func isSelectable(_ profile: HermesProfileInfo) -> Bool {
        profile.id == "default" || profile.apiServerReachable == true
    }

    private func profileIcon(_ id: String) -> String {
        switch id.lowercased() {
        case "dev": return "hammer.fill"
        case "scout": return "magnifyingglass"
        case "scribe": return "pencil.and.scribble"
        case "reach": return "megaphone.fill"
        case "voice", "live": return "waveform"
        case "default": return "sparkles"
        default: return "person.crop.circle"
        }
    }
}

private struct CallModeOverlay: View {
    let status: String
    let level: Float
    let threshold: Float
    let levels: [Float]
    let isListening: Bool
    let isTranscribing: Bool
    let isSending: Bool
    let isSpeaking: Bool
    let isPaused: Bool
    let elapsed: String
    let selectedIntent: VoiceCallIntent
    let onSelectIntent: (VoiceCallIntent) -> Void
    let onEnd: () -> Void
    let onResume: () -> Void
    let onInterrupt: () -> Void

    private var phaseTitle: String {
        if isPaused { return "Call paused" }
        if isSpeaking { return "HermesSwift speaking" }
        if isSending { return "HermesSwift thinking" }
        if isTranscribing { return "Transcribing" }
        if isListening { return "Listening" }
        return "Call active"
    }

    private var phaseIcon: String {
        if isPaused { return "pause.circle.fill" }
        if isSpeaking { return "speaker.wave.2.circle.fill" }
        if isSending { return "brain.head.profile" }
        if isTranscribing { return "waveform.badge.magnifyingglass" }
        if isListening { return "waveform.circle.fill" }
        return "phone.circle.fill"
    }

    private var phaseColor: Color {
        if isPaused { return .orange }
        if isSpeaking { return .blue }
        if isSending || isTranscribing { return .purple }
        if isListening { return TerminalTheme.text }
        return .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: phaseIcon)
                    .font(.title2)
                    .foregroundStyle(phaseColor)
                    .symbolEffect(.pulse, options: .repeating, value: isListening || isSpeaking || isSending || isTranscribing)

                VStack(alignment: .leading, spacing: 2) {
                    Text(phaseTitle)
                        .font(.headline)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(TerminalTheme.secondaryText)
                        .lineLimit(2)
                }

                Spacer()

                Text(elapsed)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(TerminalTheme.secondaryText)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(VoiceCallIntent.all) { intent in
                        Button { onSelectIntent(intent) } label: {
                            Label(intent.title, systemImage: intent.icon)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(selectedIntent == intent ? TerminalTheme.text.opacity(0.25) : Color.secondary.opacity(0.14), in: Capsule())
                                .overlay {
                                    Capsule().strokeBorder(selectedIntent == intent ? TerminalTheme.text.opacity(0.45) : Color.clear, lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(isSending || isTranscribing || isSpeaking)
                    }
                }
            }
            .accessibilityLabel("Voice call intent presets")

            VoiceLevelMeter(levels: levels, threshold: threshold)

            HStack(spacing: 10) {
                Label("\(Int(level)) dB", systemImage: level > threshold ? "mic.fill" : "mic.slash")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(level > threshold ? TerminalTheme.text : TerminalTheme.secondaryText)

                Spacer()

                if isPaused {
                    Button(action: onResume) {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(TerminalTheme.text)
                } else if isSpeaking || isSending {
                    Button(action: onInterrupt) {
                        Label("Interrupt", systemImage: "mic.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button(role: .destructive, action: onEnd) {
                    Label("End", systemImage: "phone.down.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(TerminalTheme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(phaseColor.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
    }
}

private struct VoiceLevelMeter: View {
    let levels: [Float]
    let threshold: Float

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule(style: .continuous)
                    .fill(level > threshold ? TerminalTheme.text.gradient : TerminalTheme.faintBorder.gradient)
                    .frame(width: 5, height: barHeight(for: level))
                    .animation(.easeOut(duration: 0.12), value: level)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
        .padding(.horizontal, 6)
        .background(Color.black.opacity(0.12), in: Capsule(style: .continuous))
        .accessibilityLabel("Microphone level meter")
    }

    private func barHeight(for level: Float) -> CGFloat {
        let clamped = min(max(level, -70), 0)
        let normalized = Double((clamped + 70) / 70)
        return CGFloat(8 + normalized * 34)
    }
}

private struct MessageBubble: View {
    let message: HermesMessage
    @State private var copied = false

    private var displayText: String {
        let primary = message.content?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let primary, !primary.isEmpty { return primary }
        return message.reasoningContent ?? message.reasoning ?? ""
    }

    private var roleLabel: String {
        switch message.role.lowercased() {
        case "user": return "you"
        case "assistant": return "HermesSwift"
        case "tool": return message.toolName?.isEmpty == false ? "Tool: \(message.toolName!)" : "Tool"
        case "system": return "System"
        default: return message.role.capitalized
        }
    }

    private var timeLabel: String? {
        guard let timestamp = message.timestamp else { return nil }
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var body: some View {
        HStack(alignment: .bottom) {
            if message.isUser { Spacer(minLength: 36) }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(roleLabel)
                        .font(.caption2)
                        .fontWeight(.semibold)
                    if let timeLabel {
                        Text(timeLabel)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button { copy(displayText) } label: {
                        Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(copied ? TerminalTheme.text : TerminalTheme.secondaryText)
                    .accessibilityLabel("Copy message")
                }
                .foregroundStyle(TerminalTheme.secondaryText)

                MessageMarkdownText(text: displayText.isEmpty ? "…" : displayText, alignment: message.isUser ? .trailing : .leading)
                    .foregroundStyle(TerminalTheme.text)
            }
            .padding(11)
            .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(alignment: message.isUser ? .bottomTrailing : .bottomLeading) {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.5)
            }

            if !message.isUser { Spacer(minLength: 36) }
        }
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

    private var backgroundStyle: Color {
        if message.isUser { return TerminalTheme.userBubble }
        if message.role.lowercased() == "tool" { return Color.orange.opacity(0.10) }
        if message.role.lowercased() == "system" { return Color.blue.opacity(0.09) }
        return TerminalTheme.assistantBubble
    }

    private var borderColor: Color {
        message.isUser ? TerminalTheme.border : TerminalTheme.faintBorder
    }
}

private struct EndedCallCard: View {
    let info: EndedCallInfo
    let transcriptPreview: String
    let onSummarize: () -> Void
    let onCopyTranscript: () -> Void
    let onKeepPinned: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "phone.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(TerminalTheme.text)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Call ended")
                        .font(.headline)
                    Text("\(info.intent.title) • \(info.duration) • \(info.messageCount) new messages")
                        .font(.caption)
                        .foregroundStyle(TerminalTheme.secondaryText)
                }
                Spacer()
                Button(action: onDismiss) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(TerminalTheme.secondaryText)
            }

            if !transcriptPreview.isEmpty {
                Text(transcriptPreview)
                    .font(.caption)
                    .foregroundStyle(TerminalTheme.secondaryText)
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Text("No call transcript captured yet.")
                    .font(.caption)
                    .foregroundStyle(TerminalTheme.secondaryText)
            }

            HStack {
                Button(action: onSummarize) {
                    Label("Summarize", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(TerminalTheme.text)

                Button(action: onCopyTranscript) {
                    Label("Copy transcript", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: onKeepPinned) {
                    Label("Keep pinned", systemImage: "pin.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(TerminalTheme.text.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(TerminalTheme.text.opacity(0.25), lineWidth: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MissingSessionRecoveryCard: View {
    let sessionID: String
    let onArchive: () -> Void
    let onReplace: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Session missing on this API server", systemImage: "exclamationmark.icloud.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text("This chat id returned HTTP 404. It may be an orphan from an unavailable profile route. Archive it locally or start a clean replacement chat on the current API server.")
                .font(.caption)
                .foregroundStyle(TerminalTheme.secondaryText)

            Text(sessionID)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)

            HStack {
                Button(action: onArchive) {
                    Label("Archive locally", systemImage: "archivebox.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: onReplace) {
                    Label("Start replacement", systemImage: "plus.message.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(TerminalTheme.text)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.28), lineWidth: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ErrorBubble: View {
    let error: String

    var body: some View {
        Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .padding(10)
            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
