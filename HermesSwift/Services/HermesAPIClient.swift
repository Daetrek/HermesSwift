import Foundation

struct HermesAPIClient {
    enum APIError: LocalizedError {
        case invalidBaseURL
        case invalidResponse
        case http(Int, String)
        case emptyToken

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL: return "Invalid gateway URL"
            case .invalidResponse: return "Invalid server response"
            case .http(let code, let message): return "HTTP \(code): \(message)"
            case .emptyToken: return "API token is empty"
            }
        }
    }

    private struct EmptyBody: Encodable {}

    let baseURL: URL
    let token: String
    var session: URLSession = .shared

    init(baseURLString: String, token: String) throws {
        guard let url = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw APIError.invalidBaseURL
        }
        self.baseURL = url
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func status() async throws -> StatusResponse {
        try await request(path: "/health")
    }

    func models() async throws -> ModelsListResponse {
        try await request(path: "/v1/models")
    }

    func profiles() async throws -> ProfilesListResponse {
        try await request(path: "/api/profiles")
    }

    func listSessions(limit: Int = 50) async throws -> SessionsListResponse {
        try await request(path: "/api/sessions?limit=\(limit)&offset=0")
    }

    func createSession(title: String? = nil, model: String? = nil, profile: String? = nil) async throws -> CreateSessionResponse {
        var body: [String: String] = [:]
        if let title, !title.isEmpty { body["title"] = title }
        if let model, !model.isEmpty { body["model"] = model }
        if let profile, !profile.isEmpty, profile != "default" { body["profile"] = profile }
        return try await request(path: "/api/sessions", method: "POST", body: body)
    }

    func messages(sessionID: String) async throws -> SessionMessagesResponse {
        try await request(path: "/api/sessions/\(Self.escapePath(sessionID))/messages")
    }

    func uploadAttachment(sessionID: String, data: Data, filename: String, mimeType: String) async throws -> HermesAttachment {
        if token.isEmpty { throw APIError.emptyToken }
        let path = "/api/sessions/\(Self.escapePath(sessionID))/attachments"
        guard let url = URL(string: path, relativeTo: baseURL) else { throw APIError.invalidBaseURL }
        let boundary = "HermesSwiftBoundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(boundary: boundary, fieldName: "file", filename: filename, mimeType: mimeType, data: data)
        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = Self.extractErrorMessage(from: responseData) ?? String(data: responseData, encoding: .utf8) ?? "Upload failed"
            throw APIError.http(http.statusCode, message)
        }
        return try JSONDecoder.hermes.decode(AttachmentUploadResponse.self, from: responseData).attachment
    }

    func send(sessionID: String, text: String, model: String? = nil, profile: String? = nil, attachments: [HermesAttachment] = []) async throws -> SessionChatResponse {
        let refs = attachments.map { SessionChatAttachmentReference(id: $0.id) }
        return try await request(path: "/api/sessions/\(Self.escapePath(sessionID))/chat", method: "POST", body: SessionChatRequest(message: text, model: model, profile: profile, attachments: refs))
    }

    func stream(sessionID: String, text: String, model: String? = nil, profile: String? = nil, attachments: [HermesAttachment] = []) -> AsyncThrowingStream<ChatStreamUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if token.isEmpty { throw APIError.emptyToken }
                    let path = "/api/sessions/\(Self.escapePath(sessionID))/chat/stream"
                    guard let url = URL(string: path, relativeTo: baseURL) else { throw APIError.invalidBaseURL }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let refs = attachments.map { SessionChatAttachmentReference(id: $0.id) }
                    request.httpBody = try JSONEncoder().encode(SessionChatRequest(message: text, model: model, profile: profile, attachments: refs))

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
                    guard (200..<300).contains(http.statusCode) else {
                        throw APIError.http(http.statusCode, "Streaming request failed")
                    }

                    continuation.yield(.started)
                    var eventName = "message"
                    var dataLines: [String] = []

                    func flushEvent() {
                        guard !dataLines.isEmpty else {
                            eventName = "message"
                            return
                        }
                        let data = dataLines.joined(separator: "\n")
                        Self.emitStreamUpdate(event: eventName, data: data, continuation: continuation)
                        eventName = "message"
                        dataLines.removeAll(keepingCapacity: true)
                    }

                    for try await line in bytes.lines {
                        if line.isEmpty {
                            flushEvent()
                        } else if line.hasPrefix("event:") {
                            eventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            dataLines.append(String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces))
                        }
                    }
                    flushEvent()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func request<T: Decodable, Body: Encodable>(path: String, method: String = "GET", body: Body? = Optional<EmptyBody>.none) async throws -> T {
        if token.isEmpty { throw APIError.emptyToken }
        guard let url = URL(string: path, relativeTo: baseURL) else { throw APIError.invalidBaseURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = Self.extractErrorMessage(from: data) ?? String(data: data, encoding: .utf8) ?? "Request failed"
            throw APIError.http(http.statusCode, message)
        }
        return try JSONDecoder.hermes.decode(T.self, from: data)
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        if let decoded = try? JSONDecoder.hermes.decode(APIErrorResponse.self, from: data) {
            return decoded.error?.message ?? decoded.error?.code
        }
        return nil
    }

    private static func multipartBody(boundary: String, fieldName: String, filename: String, mimeType: String, data: Data) -> Data {
        var body = Data()
        func append(_ string: String) {
            body.append(Data(string.utf8))
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename.replacingOccurrences(of: "\"", with: "_"))\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    private static func emitStreamUpdate(
        event: String,
        data: String,
        continuation: AsyncThrowingStream<ChatStreamUpdate, Error>.Continuation
    ) {
        guard let jsonData = data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else { return }

        switch event {
        case "assistant.delta":
            if let delta = object["delta"] as? String, !delta.isEmpty {
                continuation.yield(.assistantDelta(delta))
            }
        case "assistant.completed":
            if let content = object["content"] as? String {
                continuation.yield(.assistantCompleted(content))
            }
        case "tool.progress", "tool.started", "tool.completed", "tool.failed":
            let toolName = object["tool_name"] as? String ?? "tool"
            let preview = object["preview"] as? String ?? object["delta"] as? String ?? ""
            continuation.yield(.toolProgress([toolName, preview].filter { !$0.isEmpty }.joined(separator: ": ")))
        case "run.completed", "done":
            continuation.yield(.completed)
        case "error":
            continuation.yield(.error(object["message"] as? String ?? "Unknown streaming error"))
        default:
            break
        }
    }

    private static func escapePath(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}

extension JSONDecoder {
    static var hermes: JSONDecoder {
        let decoder = JSONDecoder()
        return decoder
    }
}
