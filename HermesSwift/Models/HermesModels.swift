import Foundation

struct StatusResponse: Codable {
    let status: String?
    let version: String?
    let model: String?
}

struct HermesModelInfo: Codable, Identifiable, Hashable {
    let id: String
    let object: String?
    let ownedBy: String?

    enum CodingKeys: String, CodingKey {
        case id, object
        case ownedBy = "owned_by"
    }
}

struct ModelsListResponse: Codable {
    let object: String?
    let data: [HermesModelInfo]
}

struct HermesProfileInfo: Codable, Identifiable, Hashable {
    let id: String
    let name: String?
    let active: Bool?
    let gatewayState: String?
    let apiServerEnabled: Bool?
    let apiServerPort: Int?
    let apiServerReachable: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, active
        case gatewayState = "gateway_state"
        case apiServerEnabled = "api_server_enabled"
        case apiServerPort = "api_server_port"
        case apiServerReachable = "api_server_reachable"
    }
}

struct ProfilesListResponse: Codable {
    let object: String?
    let data: [HermesProfileInfo]
}

struct HermesSession: Codable, Identifiable, Hashable {
    let id: String
    let source: String?
    let userId: String?
    let model: String?
    let title: String?
    let startedAt: Double?
    let endedAt: Double?
    let messageCount: Int?
    let toolCallCount: Int?
    let lastActive: Double?
    let preview: String?

    enum CodingKeys: String, CodingKey {
        case id, source, model, title, preview
        case userId = "user_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case messageCount = "message_count"
        case toolCallCount = "tool_call_count"
        case lastActive = "last_active"
    }

    var displayTitle: String { title?.isEmpty == false ? title! : id }

    var subtitle: String {
        [source, model].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " • ")
    }

    var detailLine: String {
        var parts: [String] = []
        if let messageCount { parts.append("\(messageCount) msg") }
        if let toolCallCount, toolCallCount > 0 { parts.append("\(toolCallCount) tools") }
        if let lastActive { parts.append("Active \(Self.relativeTime(lastActive))") }
        return parts.joined(separator: " • ")
    }

    var searchableText: String {
        [displayTitle, id, source, model, preview, detailLine]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
    }

    static func relativeTime(_ unixSeconds: Double) -> String {
        let date = Date(timeIntervalSince1970: unixSeconds)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct SessionsListResponse: Codable {
    let object: String?
    let data: [HermesSession]
    let limit: Int?
    let offset: Int?
    let hasMore: Bool?

    enum CodingKeys: String, CodingKey {
        case object, data, limit, offset
        case hasMore = "has_more"
    }
}

struct CreateSessionResponse: Codable {
    let object: String?
    let session: HermesSession
}

enum ChatStreamUpdate: Hashable {
    case started
    case assistantDelta(String)
    case assistantCompleted(String)
    case toolProgress(String)
    case completed
    case error(String)
}

struct HermesMessage: Codable, Identifiable, Hashable {
    let id: Int?
    let sessionId: String?
    let role: String
    var content: String?
    let toolName: String?
    let timestamp: Double?
    let finishReason: String?
    let reasoning: String?
    let reasoningContent: String?

    enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp, reasoning
        case sessionId = "session_id"
        case toolName = "tool_name"
        case finishReason = "finish_reason"
        case reasoningContent = "reasoning_content"
    }

    init(
        id: Int? = nil,
        sessionId: String? = nil,
        role: String,
        content: String? = nil,
        toolName: String? = nil,
        timestamp: Double? = Date().timeIntervalSince1970,
        finishReason: String? = nil,
        reasoning: String? = nil,
        reasoningContent: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.content = content
        self.toolName = toolName
        self.timestamp = timestamp
        self.finishReason = finishReason
        self.reasoning = reasoning
        self.reasoningContent = reasoningContent
    }

    var stableID: String { "\(sessionId ?? "session")-\(id ?? content.hashValue)" }
    var isUser: Bool { role == "user" }
    var isAssistant: Bool { role == "assistant" }
}

struct SessionMessagesResponse: Codable {
    let object: String?
    let sessionId: String?
    let data: [HermesMessage]

    enum CodingKeys: String, CodingKey {
        case object, data
        case sessionId = "session_id"
    }
}

struct SessionChatAttachmentReference: Codable, Hashable {
    let id: String
}

struct SessionChatRequest: Codable {
    let message: String
    let model: String?
    let profile: String?
    let attachments: [SessionChatAttachmentReference]?

    init(message: String, model: String? = nil, profile: String? = nil, attachments: [SessionChatAttachmentReference]? = nil) {
        self.message = message
        self.model = model?.isEmpty == false ? model : nil
        self.profile = profile?.isEmpty == false ? profile : nil
        self.attachments = attachments?.isEmpty == false ? attachments : nil
    }
}

struct HermesAttachment: Codable, Identifiable, Hashable {
    let id: String
    let sessionId: String?
    let filename: String
    let mimeType: String
    let size: Int
    let createdAt: Double?
    let url: String?

    enum CodingKeys: String, CodingKey {
        case id, filename, size, url
        case sessionId = "session_id"
        case mimeType = "mime_type"
        case createdAt = "created_at"
    }

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    var isImage: Bool { mimeType.lowercased().hasPrefix("image/") }
}

struct AttachmentUploadResponse: Codable {
    let object: String?
    let attachment: HermesAttachment
}

struct AttachmentsListResponse: Codable {
    let object: String?
    let sessionId: String?
    let data: [HermesAttachment]

    enum CodingKeys: String, CodingKey {
        case object, data
        case sessionId = "session_id"
    }
}

struct SessionChatResponse: Codable {
    struct AssistantMessage: Codable {
        let role: String
        let content: String
    }

    let object: String?
    let sessionId: String?
    let message: AssistantMessage

    enum CodingKeys: String, CodingKey {
        case object, message
        case sessionId = "session_id"
    }
}

struct APIErrorResponse: Codable {
    struct ErrorBody: Codable {
        let message: String?
        let type: String?
        let code: String?
    }
    let error: ErrorBody?
}
