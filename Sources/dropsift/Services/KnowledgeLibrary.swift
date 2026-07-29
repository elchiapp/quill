import Foundation
import UniformTypeIdentifiers

enum KnowledgeLibrary {
    static func load(from root: URL) -> [KnowledgeItem] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .compactMap(KnowledgeItem.load(from:))
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func createNote(in root: URL) throws -> KnowledgeItem {
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let metadata = KnowledgeItemMetadata(
            id: id,
            kind: .note,
            title: "Untitled note",
            createdAt: Date(),
            updatedAt: Date(),
            assetFilename: nil,
            blocks: [],
            extractionError: nil
        )
        try write(metadata, to: directory)
        try Data().write(to: directory.appendingPathComponent("content.md"))
        return try requireItem(in: directory)
    }

    static func importFile(
        _ source: URL,
        as requestedKind: KnowledgeItemKind,
        into root: URL
    ) throws -> KnowledgeItem {
        let kind = resolvedKind(for: source, requested: requestedKind)
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let ext = source.pathExtension.lowercased()
        let assetName = ext.isEmpty ? "asset" : "asset.\(ext)"
        let destination = directory.appendingPathComponent(assetName)
        try FileManager.default.copyItem(at: source, to: destination)

        var blocks: [KnowledgeBlock] = []
        var extractionError: String?
        do {
            blocks = try KnowledgeExtractor.extract(from: destination, kind: kind)
        } catch {
            extractionError = error.localizedDescription
        }

        let metadata = KnowledgeItemMetadata(
            id: id,
            kind: kind,
            title: source.deletingPathExtension().lastPathComponent,
            createdAt: Date(),
            updatedAt: Date(),
            assetFilename: assetName,
            blocks: blocks,
            extractionError: extractionError
        )
        try write(metadata, to: directory)
        return try requireItem(in: directory)
    }

    static func saveTitle(_ title: String, for item: KnowledgeItem) throws {
        var metadata = currentMetadata(for: item)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.title = trimmed.isEmpty ? "Untitled \(metadata.kind.displayName.lowercased())" : trimmed
        metadata.updatedAt = Date()
        try write(metadata, to: item.directory)
    }

    static func saveContent(_ content: String, for item: KnowledgeItem) throws {
        try Data(content.utf8).write(
            to: item.directory.appendingPathComponent("content.md"),
            options: .atomic
        )
        var metadata = currentMetadata(for: item)
        metadata.updatedAt = Date()
        try write(metadata, to: item.directory)
    }

    static func saveAdditionalNotes(_ notes: String, for item: KnowledgeItem) throws {
        try Data(notes.utf8).write(
            to: item.directory.appendingPathComponent("notes.md"),
            options: .atomic
        )
        var metadata = currentMetadata(for: item)
        metadata.updatedAt = Date()
        try write(metadata, to: item.directory)
    }

    private static func resolvedKind(
        for url: URL,
        requested: KnowledgeItemKind
    ) -> KnowledgeItemKind {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return requested
        }
        if type.conforms(to: .image) { return .image }
        return .document
    }

    private static func currentMetadata(for item: KnowledgeItem) -> KnowledgeItemMetadata {
        KnowledgeItem.load(from: item.directory)?.metadata ?? item.metadata
    }

    private static func write(
        _ metadata: KnowledgeItemMetadata,
        to directory: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(
            to: directory.appendingPathComponent("item.json"),
            options: .atomic
        )
    }

    private static func requireItem(in directory: URL) throws -> KnowledgeItem {
        if let item = KnowledgeItem.load(from: directory) { return item }
        throw CocoaError(.fileReadCorruptFile)
    }
}
