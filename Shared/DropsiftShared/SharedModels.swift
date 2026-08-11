import Foundation

public enum SharedKnowledgeKind: String, Codable, CaseIterable, Sendable {
    case note
    case document
    case image

    public var displayName: String {
        switch self {
        case .note: "Note"
        case .document: "Document"
        case .image: "Image"
        }
    }
}

public struct SharedKnowledgeBlock: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let page: Int?
    public let locator: String

    public init(
        id: UUID = UUID(),
        text: String,
        page: Int? = nil,
        locator: String
    ) {
        self.id = id
        self.text = text
        self.page = page
        self.locator = locator
    }
}

public struct SharedKnowledgeMetadata: Codable, Sendable, Equatable {
    public let id: UUID
    public var kind: SharedKnowledgeKind
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    public var assetFilename: String?
    public var blocks: [SharedKnowledgeBlock]
    public var extractionError: String?

    public init(
        id: UUID = UUID(),
        kind: SharedKnowledgeKind,
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        assetFilename: String? = nil,
        blocks: [SharedKnowledgeBlock] = [],
        extractionError: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.assetFilename = assetFilename
        self.blocks = blocks
        self.extractionError = extractionError
    }
}

public struct SharedKnowledgeItem: Identifiable, Sendable, Equatable {
    public let directory: URL
    public let metadata: SharedKnowledgeMetadata
    public let content: String
    public let additionalNotes: String

    public var id: UUID { metadata.id }
    public var kind: SharedKnowledgeKind { metadata.kind }
    public var title: String { metadata.title }
    public var createdAt: Date { metadata.createdAt }
    public var updatedAt: Date { metadata.updatedAt }
    public var blocks: [SharedKnowledgeBlock] { metadata.blocks }
    public var extractionError: String? { metadata.extractionError }

    public var assetURL: URL? {
        metadata.assetFilename.map { directory.appendingPathComponent($0) }
    }

    public var extractedText: String {
        blocks.map(\.text).joined(separator: "\n\n")
    }

    public var preview: String {
        let source = kind == .note ? content : extractedText
        let flattened = source
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if flattened.isEmpty {
            if let extractionError { return "Extraction failed: \(extractionError)" }
            return kind == .note ? "Empty note" : "No text extracted"
        }
        return String(flattened.prefix(180))
    }
}

public struct SharedTranscriptDocument: Codable, Sendable, Equatable {
    public struct Segment: Codable, Identifiable, Sendable, Equatable {
        public let speaker: String
        public let startMs: Int
        public let endMs: Int
        public let text: String

        public var id: String { "\(speaker)-\(startMs)-\(endMs)-\(text)" }

        public init(speaker: String, startMs: Int, endMs: Int, text: String) {
            self.speaker = speaker
            self.startMs = startMs
            self.endMs = endMs
            self.text = text
        }

        enum CodingKeys: String, CodingKey {
            case speaker
            case startMs = "start_ms"
            case endMs = "end_ms"
            case text
        }
    }

    public let engine: String
    public let model: String
    public let createdAt: String
    public let segments: [Segment]
    public let languageCode: String?

    public init(
        engine: String,
        model: String,
        createdAt: String,
        segments: [Segment],
        languageCode: String? = nil
    ) {
        self.engine = engine
        self.model = model
        self.createdAt = createdAt
        self.segments = segments
        self.languageCode = languageCode
    }

    enum CodingKeys: String, CodingKey {
        case engine
        case model
        case createdAt = "created_at"
        case segments
        case languageCode = "language_code"
    }
}

public struct SharedRecordingMetadata: Codable, Sendable, Equatable {
    public struct Track: Codable, Sendable, Equatable {
        public let file: String
        public let speaker: String
        public let offsetMs: Int

        public init(file: String, speaker: String, offsetMs: Int) {
            self.file = file
            self.speaker = speaker
            self.offsetMs = offsetMs
        }

        enum CodingKeys: String, CodingKey {
            case file
            case speaker
            case offsetMs = "offset_ms"
        }
    }

    public let started: String?
    public let ended: String?
    public let durationSeconds: Int?
    public let files: [String: String]?
    public let startOffsetMs: [String: Int]?
    public let tracks: [Track]?
    public let imported: Bool?
    public let origin: String?
    public let resumeCount: Int?

    public init(
        started: String?,
        ended: String?,
        durationSeconds: Int?,
        files: [String: String]?,
        startOffsetMs: [String: Int]? = nil,
        tracks: [Track]? = nil,
        imported: Bool? = nil,
        origin: String? = nil,
        resumeCount: Int? = nil
    ) {
        self.started = started
        self.ended = ended
        self.durationSeconds = durationSeconds
        self.files = files
        self.startOffsetMs = startOffsetMs
        self.tracks = tracks
        self.imported = imported
        self.origin = origin
        self.resumeCount = resumeCount
    }

    enum CodingKeys: String, CodingKey {
        case started
        case ended
        case durationSeconds = "duration_seconds"
        case files
        case startOffsetMs = "start_offset_ms"
        case tracks
        case imported
        case origin
        case resumeCount = "resume_count"
    }
}

public struct SharedRecordingAudioTrack: Sendable, Equatable {
    public let url: URL
    public let speaker: String
    public let offsetMs: Int

    public init(url: URL, speaker: String, offsetMs: Int) {
        self.url = url
        self.speaker = speaker
        self.offsetMs = offsetMs
    }
}

public struct SharedRecordingItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let directory: URL
    public let title: String
    public let startedAt: Date
    public let durationSeconds: Int
    public let audioURL: URL?
    public let audioTracks: [SharedRecordingAudioTrack]
    public let transcript: SharedTranscriptDocument?
    public let notes: String
    public let speakerNames: [String: String]

    public func speakerName(for speakerID: String) -> String {
        SharedSpeakerNameStore.displayName(for: speakerID, names: speakerNames)
    }

    public var preview: String {
        if let first = transcript?.segments.first?.text, !first.isEmpty {
            return first
        }
        if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return notes
        }
        return transcript == nil ? "Waiting for transcription" : "No speech detected"
    }
}

public enum SharedTimelineKind: String, CaseIterable, Identifiable, Sendable {
    case recording
    case note
    case document
    case image

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .recording: "Recordings"
        case .note: "Notes"
        case .document: "Documents"
        case .image: "Images"
        }
    }
}

public enum SharedTimelineItem: Identifiable, Sendable, Equatable {
    case recording(SharedRecordingItem)
    case knowledge(SharedKnowledgeItem)

    public var id: String {
        switch self {
        case .recording(let item): "recording:\(item.id)"
        case .knowledge(let item): "knowledge:\(item.id.uuidString)"
        }
    }

    public var kind: SharedTimelineKind {
        switch self {
        case .recording: .recording
        case .knowledge(let item):
            switch item.kind {
            case .note: .note
            case .document: .document
            case .image: .image
            }
        }
    }

    public var title: String {
        switch self {
        case .recording(let item): item.title
        case .knowledge(let item): item.title
        }
    }

    public var date: Date {
        switch self {
        case .recording(let item): item.startedAt
        case .knowledge(let item): item.createdAt
        }
    }

    public var preview: String {
        switch self {
        case .recording(let item): item.preview
        case .knowledge(let item): item.preview
        }
    }
}

public struct SharedSearchResult: Identifiable, Sendable, Equatable {
    public let id: String
    public let itemID: String
    public let title: String
    public let kind: SharedTimelineKind
    public let locator: String
    public let text: String
    public let score: Double
    public let startMs: Int?
    public let page: Int?

    public init(
        id: String,
        itemID: String,
        title: String,
        kind: SharedTimelineKind,
        locator: String,
        text: String,
        score: Double,
        startMs: Int? = nil,
        page: Int? = nil
    ) {
        self.id = id
        self.itemID = itemID
        self.title = title
        self.kind = kind
        self.locator = locator
        self.text = text
        self.score = score
        self.startMs = startMs
        self.page = page
    }
}

public struct SharedLibrarySnapshot: Sendable, Equatable {
    public let knowledgeItems: [SharedKnowledgeItem]
    public let recordings: [SharedRecordingItem]
    public let tasks: [SharedTask]
    public let entities: [SharedSemanticEntity]

    public init(
        knowledgeItems: [SharedKnowledgeItem],
        recordings: [SharedRecordingItem],
        tasks: [SharedTask] = [],
        entities: [SharedSemanticEntity] = []
    ) {
        self.knowledgeItems = knowledgeItems
        self.recordings = recordings
        self.tasks = tasks
        self.entities = entities
    }

    public var timeline: [SharedTimelineItem] {
        (
            recordings.map(SharedTimelineItem.recording)
                + knowledgeItems.map(SharedTimelineItem.knowledge)
        )
        .sorted { $0.date > $1.date }
    }
}
