import Foundation

struct VoiceHealthResponse: Codable {
    let ok: Bool?
    let service: String?
}

struct VoiceInfo: Codable, Identifiable, Hashable {
    let id: String
    let name: String?
    let language: String?
}

struct VoiceListResponse: Codable {
    let voices: [VoiceInfo]
}

struct TranscriptionResponse: Codable {
    let text: String
}
