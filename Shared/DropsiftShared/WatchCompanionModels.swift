import Foundation

public struct WatchCompanionSnapshot: Codable, Sendable, Equatable {
    public var generatedAt: Date
    public var items: [WatchCompanionItem]
    public var tasks: [WatchCompanionTask]
    public var entities: [WatchCompanionEntity]

    public init(
        generatedAt: Date = Date(),
        items: [WatchCompanionItem],
        tasks: [WatchCompanionTask],
        entities: [WatchCompanionEntity]
    ) {
        self.generatedAt = generatedAt
        self.items = items
        self.tasks = tasks
        self.entities = entities
    }

    public static let empty = WatchCompanionSnapshot(
        generatedAt: .distantPast,
        items: [],
        tasks: [],
        entities: []
    )
}

public struct WatchCompanionItem: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let kind: String
    public let date: Date
    public let description: String
    public let summary: String

    public init(
        id: String,
        title: String,
        kind: String,
        date: Date,
        description: String,
        summary: String
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.date = date
        self.description = description
        self.summary = summary
    }
}

public struct WatchCompanionTask: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let description: String
    public let dueDate: Date?
    public let priority: String
    public let isCompleted: Bool

    public init(
        id: UUID,
        title: String,
        description: String,
        dueDate: Date?,
        priority: String,
        isCompleted: Bool
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.dueDate = dueDate
        self.priority = priority
        self.isCompleted = isCompleted
    }
}

public struct WatchCompanionEntity: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let kind: String
    public let summary: String
    public let date: Date?

    public init(
        id: UUID,
        name: String,
        kind: String,
        summary: String,
        date: Date?
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.summary = summary
        self.date = date
    }
}

public struct WatchCompanionAnswer: Codable, Sendable, Equatable {
    public let text: String
    public let sources: [String]

    public init(text: String, sources: [String]) {
        self.text = text
        self.sources = sources
    }
}
