import Foundation

final class VoiceStackClient: @unchecked Sendable {
    enum VoiceError: LocalizedError {
        case invalidURL
        case invalidResponse
        case http(Int, String)
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid VoiceStack URL"
            case .invalidResponse: return "Invalid VoiceStack response"
            case .http(let status, let body): return "VoiceStack HTTP \(status): \(body)"
            case .emptyTranscript: return "VoiceStack returned an empty transcript"
            }
        }
    }

    let baseURL: URL

    init(baseURLString: String) throws {
        guard let url = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw VoiceError.invalidURL
        }
        self.baseURL = url
    }

    func health() async throws -> VoiceHealthResponse {
        try await jsonRequest(path: "/health")
    }

    func voices() async throws -> VoiceListResponse {
        try await jsonRequest(path: "/v1/audio/voices")
    }

    func transcribe(audioURL: URL, language: String? = nil) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try Data(contentsOf: audioURL)
        var body = Data()
        body.appendMultipartField(name: "model", value: "moonshine", boundary: boundary)
        if let language, !language.isEmpty { body.appendMultipartField(name: "language", value: language, boundary: boundary) }
        body.appendFileField(name: "file", filename: audioURL.lastPathComponent, mimeType: "audio/mp4", data: data, boundary: boundary)
        body.appendString("--\(boundary)--\r\n")
        request.httpBody = body

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VoiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw VoiceError.http(http.statusCode, String(data: responseData, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: responseData)
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VoiceError.emptyTranscript }
        return text
    }

    func speech(text: String, voice: String, speed: Double = 1.0) async throws -> URL {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/audio/speech"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/wav, audio/mpeg, application/octet-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "tts-1",
            "input": text,
            "voice": voice,
            "speed": speed
        ], options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VoiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw VoiceError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let ext = contentTypeExtension(http.value(forHTTPHeaderField: "Content-Type"))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("agentone-tts-\(UUID().uuidString).\(ext)")
        try data.write(to: out, options: .atomic)
        return out
    }

    private func jsonRequest<T: Decodable>(path: String) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VoiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw VoiceError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func contentTypeExtension(_ contentType: String?) -> String {
        let lower = contentType?.lowercased() ?? ""
        if lower.contains("mpeg") || lower.contains("mp3") { return "mp3" }
        if lower.contains("m4a") || lower.contains("mp4") { return "m4a" }
        return "wav"
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }

    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }

    mutating func appendFileField(name: String, filename: String, mimeType: String, data: Data, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        appendString("Content-Type: \(mimeType)\r\n\r\n")
        append(data)
        appendString("\r\n")
    }
}
