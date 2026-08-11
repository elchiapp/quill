import Foundation

public enum SharedTaskPriority: String, Codable, CaseIterable, Identifiable,
    Sendable, Comparable
{
    case low
    case medium
    case high
    case urgent

    public var id: String { rawValue }

    public var displayName: String {
        rawValue.capitalized
    }

    public var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        case .urgent: 3
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct SharedSemanticSourceReference: Codable, Identifiable, Sendable,
    Equatable, Hashable
{
    public let itemID: String
    public let title: String
    public let locator: String
    public let excerpt: String
    public let startMs: Int?
    public let page: Int?

    public var id: String {
        [
            itemID,
            locator,
            startMs.map(String.init) ?? "",
            page.map(String.init) ?? "",
        ].joined(separator: "|")
    }

    public init(
        itemID: String,
        title: String,
        locator: String,
        excerpt: String,
        startMs: Int? = nil,
        page: Int? = nil
    ) {
        self.itemID = itemID
        self.title = title
        self.locator = locator
        self.excerpt = excerpt
        self.startMs = startMs
        self.page = page
    }
}

public struct SharedTask: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    public var description: String
    public var dueDate: Date?
    public var priority: SharedTaskPriority
    public var isCompleted: Bool
    public let createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var sources: [SharedSemanticSourceReference]

    public init(
        id: UUID = UUID(),
        title: String,
        description: String = "",
        dueDate: Date? = nil,
        priority: SharedTaskPriority = .medium,
        isCompleted: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil,
        sources: [SharedSemanticSourceReference] = []
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.dueDate = dueDate
        self.priority = priority
        self.isCompleted = isCompleted
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.sources = sources
    }
}

public enum SharedSemanticEntityKind: String, Codable, CaseIterable,
    Identifiable, Sendable
{
    case person
    case place
    case event
    case organization
    case project
    case topic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .person: "People"
        case .place: "Places"
        case .event: "Events"
        case .organization: "Organizations"
        case .project: "Projects"
        case .topic: "Topics"
        }
    }

    public var singularName: String {
        switch self {
        case .person: "Person"
        case .place: "Place"
        case .event: "Event"
        case .organization: "Organization"
        case .project: "Project"
        case .topic: "Topic"
        }
    }

    public var systemImage: String {
        switch self {
        case .person: "person.2"
        case .place: "mappin.and.ellipse"
        case .event: "calendar"
        case .organization: "building.2"
        case .project: "folder"
        case .topic: "tag"
        }
    }
}

public struct SharedSemanticEntity: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var kind: SharedSemanticEntityKind
    public var name: String
    public var summary: String
    public var startDate: Date?
    public var endDate: Date?
    public let createdAt: Date
    public var updatedAt: Date
    public var sources: [SharedSemanticSourceReference]

    public init(
        id: UUID = UUID(),
        kind: SharedSemanticEntityKind,
        name: String,
        summary: String = "",
        startDate: Date? = nil,
        endDate: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sources: [SharedSemanticSourceReference] = []
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.summary = summary
        self.startDate = startDate
        self.endDate = endDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sources = sources
    }
}

public struct SharedTaskDraft: Codable, Sendable, Equatable {
    public var title: String
    public var description: String
    public var dueDate: Date?
    public var priority: SharedTaskPriority

    public init(
        title: String,
        description: String = "",
        dueDate: Date? = nil,
        priority: SharedTaskPriority = .medium
    ) {
        self.title = title
        self.description = description
        self.dueDate = dueDate
        self.priority = priority
    }
}

public struct SharedEntityDraft: Codable, Sendable, Equatable {
    public var kind: SharedSemanticEntityKind
    public var name: String
    public var summary: String
    public var startDate: Date?
    public var endDate: Date?

    public init(
        kind: SharedSemanticEntityKind,
        name: String,
        summary: String = "",
        startDate: Date? = nil,
        endDate: Date? = nil
    ) {
        self.kind = kind
        self.name = name
        self.summary = summary
        self.startDate = startDate
        self.endDate = endDate
    }
}

public enum SharedSemanticCandidateKind: String, Codable, Sendable {
    case task
    case entity
}

public struct SharedSemanticCandidate: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let kind: SharedSemanticCandidateKind
    public var task: SharedTaskDraft?
    public var entity: SharedEntityDraft?
    public var evidence: String

    public init(
        id: UUID = UUID(),
        task: SharedTaskDraft,
        evidence: String
    ) {
        self.id = id
        kind = .task
        self.task = task
        entity = nil
        self.evidence = evidence
    }

    public init(
        id: UUID = UUID(),
        entity: SharedEntityDraft,
        evidence: String
    ) {
        self.id = id
        kind = .entity
        task = nil
        self.entity = entity
        self.evidence = evidence
    }
}

public struct SharedSemanticReview: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let sourceID: String
    public let sourceRevision: String
    public let sourceTitle: String
    public let source: SharedSemanticSourceReference
    public let createdAt: Date
    public var candidates: [SharedSemanticCandidate]

    public init(
        id: UUID = UUID(),
        sourceID: String,
        sourceRevision: String,
        sourceTitle: String,
        source: SharedSemanticSourceReference,
        createdAt: Date = Date(),
        candidates: [SharedSemanticCandidate]
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceRevision = sourceRevision
        self.sourceTitle = sourceTitle
        self.source = source
        self.createdAt = createdAt
        self.candidates = candidates
    }
}

public struct SharedSemanticProcessedRecord: Codable, Identifiable, Sendable,
    Equatable
{
    public let id: UUID
    public let sourceID: String
    public let sourceRevision: String
    public let processedAt: Date

    public init(
        id: UUID = UUID(),
        sourceID: String,
        sourceRevision: String,
        processedAt: Date = Date()
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceRevision = sourceRevision
        self.processedAt = processedAt
    }
}
