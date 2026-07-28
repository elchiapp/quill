import Foundation

struct ChatSource: Codable, Identifiable, Sendable, Equatable {
    let number: Int
    let recordingID: String
    let recordingTitle: String
    let startMs: Int
    let endMs: Int
    let excerpt: String

    var id: String {
        "\(recordingID)-\(startMs)-\(endMs)-\(number)"
    }
}

struct ChatScope: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case allRecordings
        case recording
    }

    var kind: Kind
    var recordingID: String?

    static let all = ChatScope(kind: .allRecordings, recordingID: nil)

    static func recording(_ id: String) -> ChatScope {
        ChatScope(kind: .recording, recordingID: id)
    }
}

struct ChatMessage: Codable, Identifiable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let content: String
    let createdAt: Date
    let sources: [ChatSource]

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        createdAt: Date = Date(),
        sources: [ChatSource] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.sources = sources
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case createdAt
        case sources
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        sources = try container.decodeIfPresent([ChatSource].self, forKey: .sources) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(createdAt, forKey: .createdAt)
        if !sources.isEmpty {
            try container.encode(sources, forKey: .sources)
        }
    }
}

struct ChatThread: Codable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var scope: ChatScope
    var messages: [ChatMessage]

    init(
        id: UUID = UUID(),
        title: String = "New conversation",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        scope: ChatScope = .all,
        messages: [ChatMessage] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.scope = scope
        self.messages = messages
    }
}
