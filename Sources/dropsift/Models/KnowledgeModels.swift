import DropsiftShared
import Foundation

enum KnowledgeItemKind: String, Codable, CaseIterable, Sendable {
    case note
    case document
    case image

    var displayName: String {
        switch self {
        case .note: "Note"
        case .document: "Document"
        case .image: "Image"
        }
    }

    var systemImage: String {
        switch self {
        case .note: "note.text"
        case .document: "doc.text"
        case .image: "photo"
        }
    }
}

struct KnowledgeBlock: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let text: String
    let page: Int?
    let locator: String

    init(
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

struct KnowledgeItemMetadata: Codable, Sendable {
    let id: UUID
    var kind: KnowledgeItemKind
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var assetFilename: String?
    var blocks: [KnowledgeBlock]
    var extractionError: String?
}

struct KnowledgeItem: Identifiable, Sendable {
    let directory: URL
    let metadata: KnowledgeItemMetadata
    let content: String
    let additionalNotes: String

    var id: UUID { metadata.id }
    var kind: KnowledgeItemKind { metadata.kind }
    var title: String { metadata.title }
    var createdAt: Date { metadata.createdAt }
    var updatedAt: Date { metadata.updatedAt }
    var blocks: [KnowledgeBlock] { metadata.blocks }
    var extractionError: String? { metadata.extractionError }

    var generatedDescription: String {
        ContentPresentationStore.load(from: directory)?.description
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var summary: RecordingSummary? {
        RecordingSummaryStore.load(from: directory)
    }

    var assetURL: URL? {
        metadata.assetFilename.map { directory.appendingPathComponent($0) }
    }

    var isPDF: Bool {
        assetURL?.pathExtension.lowercased() == "pdf"
    }

    var extractedText: String {
        blocks.map(\.text).joined(separator: "\n\n")
    }

    var preview: String {
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

    var listDescription: String {
        generatedDescription.isEmpty ? preview : generatedDescription
    }

    static func load(from directory: URL) -> KnowledgeItem? {
        let metadataURL = directory.appendingPathComponent("item.json")
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let metadata = try? decoder.decode(KnowledgeItemMetadata.self, from: data)
        else { return nil }

        let content = (try? String(
            contentsOf: directory.appendingPathComponent("content.md"),
            encoding: .utf8
        )) ?? ""
        let notes = (try? String(
            contentsOf: directory.appendingPathComponent("notes.md"),
            encoding: .utf8
        )) ?? ""
        return KnowledgeItem(
            directory: directory,
            metadata: metadata,
            content: content,
            additionalNotes: notes
        )
    }
}

enum TimelineItemKind: String, CaseIterable, Identifiable, Sendable {
    case recording
    case note
    case document
    case image

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .recording: "Recordings"
        case .note: "Notes"
        case .document: "Documents"
        case .image: "Images"
        }
    }

    var singularName: String {
        switch self {
        case .recording: "Recording"
        case .note: "Note"
        case .document: "Document"
        case .image: "Image"
        }
    }

    var systemImage: String {
        switch self {
        case .recording: "waveform"
        case .note: "note.text"
        case .document: "doc.text"
        case .image: "photo"
        }
    }
}

enum TimelineItem: Identifiable, Sendable {
    case recording(RecordingItem)
    case knowledge(KnowledgeItem)

    var id: String {
        switch self {
        case .recording(let recording): "recording:\(recording.id)"
        case .knowledge(let item): "knowledge:\(item.id.uuidString)"
        }
    }

    var kind: TimelineItemKind {
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

    var title: String {
        switch self {
        case .recording(let recording): recording.title
        case .knowledge(let item): item.title
        }
    }

    var date: Date {
        switch self {
        case .recording(let recording): recording.startedAt ?? .distantPast
        case .knowledge(let item): item.createdAt
        }
    }

    var preview: String {
        switch self {
        case .recording(let recording): recording.preview
        case .knowledge(let item): item.preview
        }
    }

    var listDescription: String {
        switch self {
        case .recording(let recording): recording.listDescription
        case .knowledge(let item): item.listDescription
        }
    }
}
