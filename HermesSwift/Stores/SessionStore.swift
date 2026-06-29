import Foundation

@MainActor
final class SessionStore: ObservableObject {
    @Published var sessions: [HermesSession] = []
    @Published var selectedSession: HermesSession?
    @Published var messages: [HermesMessage] = []
    @Published var isLoadingSessions = false
    @Published var isLoadingMessages = false
    @Published var isSending = false
    @Published var lastError: String?
    @Published var streamStatus: String?
    @Published var missingSession: HermesSession?

    private var sendTask: Task<Void, Never>?
    private var localMessageSequence = -1

    var canCancelSend: Bool { sendTask != nil && isSending }

    func loadSessions(client: HermesAPIClient) async {
        isLoadingSessions = true
        defer { isLoadingSessions = false }
        do {
            sessions = try await client.listSessions(limit: 120).data
            lastError = nil
        } catch {
            lastError = "Load sessions failed: \(error.localizedDescription)"
        }
    }

    func createSession(client: HermesAPIClient, title: String? = nil, model: String? = nil, profile: String? = nil) async -> HermesSession? {
        isLoadingSessions = true
        defer { isLoadingSessions = false }
        do {
            let finalTitle = normalizedTitle(title)
            let created = try await client.createSession(title: finalTitle, model: model, profile: profile)
            selectedSession = created.session
            missingSession = nil
            messages = []
            sessions.removeAll { $0.id == created.session.id }
            sessions.insert(created.session, at: 0)
            lastError = nil
            return created.session
        } catch {
            lastError = "Create session failed: \(error.localizedDescription)"
            return nil
        }
    }

    func loadMessages(client: HermesAPIClient, session: HermesSession) async {
        selectedSession = session
        isLoadingMessages = true
        defer { isLoadingMessages = false }
        do {
            messages = try await client.messages(sessionID: session.id).data
            missingSession = nil
            lastError = nil
        } catch {
            if isMissingSessionError(error) {
                messages = []
                missingSession = session
                lastError = "Session not found on this API server. Archive it locally or start a replacement chat."
            } else {
                lastError = "Load messages failed: \(error.localizedDescription)"
            }
        }
    }

    func startSend(client: HermesAPIClient, text: String, model: String? = nil, profile: String? = nil, attachments: [HermesAttachment] = []) {
        guard sendTask == nil else { return }
        sendTask = Task { [weak self] in
            await self?.sendStreamingWithFallback(client: client, text: text, model: model, profile: profile, attachments: attachments)
        }
    }

    func cancelSend() {
        sendTask?.cancel()
        sendTask = nil
        isSending = false
        streamStatus = "Canceled"
    }

    private func sendStreamingWithFallback(client: HermesAPIClient, text: String, model: String? = nil, profile: String? = nil, attachments: [HermesAttachment] = []) async {
        guard let selectedSession else { sendTask = nil; return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { sendTask = nil; return }
        guard isSafeUserMessage(trimmed) else {
            lastError = "Blocked unsafe injected system text. Type your message again."
            sendTask = nil
            return
        }

        isSending = true
        lastError = nil
        streamStatus = "Sending…"

        let userMessage = nextLocalMessage(sessionID: selectedSession.id, role: "user", content: trimmed)
        var assistantMessage = nextLocalMessage(sessionID: selectedSession.id, role: "assistant", content: "")
        messages.append(userMessage)
        messages.append(assistantMessage)
        let assistantStableID = assistantMessage.stableID
        var receivedAssistantContent = false

        defer {
            isSending = false
            streamStatus = nil
            sendTask = nil
        }

        do {
            for try await update in client.stream(sessionID: selectedSession.id, text: trimmed, model: model, profile: profile, attachments: attachments) {
                try Task.checkCancellation()
                switch update {
                case .started:
                    streamStatus = "HermesSwift is responding…"
                case .assistantDelta(let delta):
                    guard !delta.isEmpty else { continue }
                    receivedAssistantContent = true
                    assistantMessage.content = (assistantMessage.content ?? "") + delta
                    replaceMessage(stableID: assistantStableID, with: assistantMessage)
                case .assistantCompleted(let content):
                    if !content.isEmpty {
                        receivedAssistantContent = true
                        assistantMessage.content = content
                        replaceMessage(stableID: assistantStableID, with: assistantMessage)
                    }
                    streamStatus = "Finalizing…"
                case .toolProgress(let progress):
                    if !progress.isEmpty { streamStatus = progress }
                case .completed:
                    streamStatus = "Done"
                case .error(let message):
                    throw HermesAPIClient.APIError.http(500, message)
                }
            }

            if !Task.isCancelled {
                if !receivedAssistantContent {
                    streamStatus = "Refreshing transcript…"
                }
                await loadMessages(client: client, session: selectedSession)
            }
        } catch is CancellationError {
            lastError = "Send canceled."
        } catch {
            guard !Task.isCancelled else {
                lastError = "Send canceled."
                return
            }
            streamStatus = "Streaming failed; retrying sync…"
            await sendSynchronouslyAfterStreamFailure(client: client, session: selectedSession, text: trimmed, assistantStableID: assistantStableID, model: model, profile: profile, attachments: attachments)
        }
    }

    private func sendSynchronouslyAfterStreamFailure(client: HermesAPIClient, session: HermesSession, text: String, assistantStableID: String, model: String? = nil, profile: String? = nil, attachments: [HermesAttachment] = []) async {
        do {
            let response = try await client.send(sessionID: session.id, text: text, model: model, profile: profile, attachments: attachments)
            if let index = messages.firstIndex(where: { $0.stableID == assistantStableID }) {
                messages[index].content = response.message.content
            }
            await loadMessages(client: client, session: session)
            lastError = nil
        } catch {
            lastError = "Send failed: \(error.localizedDescription)"
        }
    }

    private func replaceMessage(stableID: String, with message: HermesMessage) {
        if let index = messages.firstIndex(where: { $0.stableID == stableID }) {
            messages[index] = message
        }
    }

    private func nextLocalMessage(sessionID: String, role: String, content: String) -> HermesMessage {
        localMessageSequence -= 1
        return HermesMessage(id: localMessageSequence, sessionId: sessionID, role: role, content: content, timestamp: Date().timeIntervalSince1970)
    }

    private func normalizedTitle(_ title: String?) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm:ss"
        return "iPhone \(formatter.string(from: Date()))"
    }

    private func isMissingSessionError(_ error: Error) -> Bool {
        if case HermesAPIClient.APIError.http(let code, let message) = error {
            return code == 404 && message.lowercased().contains("session")
        }
        let text = error.localizedDescription.lowercased()
        return text.contains("404") && text.contains("session")
    }

    private func isSafeUserMessage(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("[system:") { return false }
        if lower.contains("continue now") && lower.contains("required tool calls") { return false }
        return true
    }
}
