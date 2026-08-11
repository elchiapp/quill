import DropsiftShared
import Foundation
import UniformTypeIdentifiers

enum KnowledgeLibrary {
    static func load(from root: URL) -> [KnowledgeItem] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        for directory in entries {
            guard var metadata = KnowledgeItem.load(from: directory)?.metadata
            else { continue }
            if (try? refreshGeneratedTitle(&metadata, in: directory)) == true {
                metadata.updatedAt = Date()
                try? write(metadata, to: directory)
            }
        }
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
        try ContentTitleGenerator.markGenerated(in: directory)
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

        let fallbackTitle = source.deletingPathExtension().lastPathComponent
        let metadata = KnowledgeItemMetadata(
            id: id,
            kind: kind,
            title: ContentTitleGenerator.title(
                from: blocks.map(\.text),
                fallback: fallbackTitle
            ),
            createdAt: Date(),
            updatedAt: Date(),
            assetFilename: assetName,
            blocks: blocks,
            extractionError: extractionError
        )
        try write(metadata, to: directory)
        try ContentTitleGenerator.markGenerated(in: directory)
        return try requireItem(in: directory)
    }

    static func saveTitle(_ title: String, for item: KnowledgeItem) throws {
        var metadata = currentMetadata(for: item)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.title = trimmed.isEmpty ? "Untitled \(metadata.kind.displayName.lowercased())" : trimmed
        metadata.updatedAt = Date()
        try ContentTitleGenerator.markManual(in: item.directory)
        try write(metadata, to: item.directory)
    }

    static func saveContent(_ content: String, for item: KnowledgeItem) throws {
        try ContentPresentationStore.invalidate(in: item.directory)
        try Data(content.utf8).write(
            to: item.directory.appendingPathComponent("content.md"),
            options: .atomic
        )
        var metadata = currentMetadata(for: item)
        try refreshGeneratedTitle(&metadata, in: item.directory)
        metadata.updatedAt = Date()
        try write(metadata, to: item.directory)
    }

    static func saveAdditionalNotes(_ notes: String, for item: KnowledgeItem) throws {
        try ContentPresentationStore.invalidate(in: item.directory)
        try Data(notes.utf8).write(
            to: item.directory.appendingPathComponent("notes.md"),
            options: .atomic
        )
        var metadata = currentMetadata(for: item)
        try refreshGeneratedTitle(&metadata, in: item.directory)
        metadata.updatedAt = Date()
        try write(metadata, to: item.directory)
    }

    static func saveGeneratedPresentation(
        _ presentation: ContentPresentation,
        in directory: URL,
        replacingManualTitle: Bool
    ) throws {
        guard var item = KnowledgeItem.load(from: directory)?.metadata else {
            throw CocoaError(.fileNoSuchFile)
        }
        let mayReplaceTitle = replacingManualTitle
            || ContentTitleGenerator.mayReplaceTitle(item.title, in: directory)
        if mayReplaceTitle {
            item.title = presentation.title
            try ContentTitleGenerator.markGenerated(
                in: directory,
                replacingManual: replacingManualTitle
            )
        }
        item.updatedAt = Date()
        try write(item, to: directory)

        var stored = presentation
        stored.title = item.title
        try ContentPresentationStore.save(stored, to: directory)
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

    @discardableResult
    private static func refreshGeneratedTitle(
        _ metadata: inout KnowledgeItemMetadata,
        in directory: URL
    ) throws -> Bool {
        guard ContentTitleGenerator.mayReplaceTitle(
            metadata.title,
            in: directory
        ) else { return false }

        let content = (try? String(
            contentsOf: directory.appendingPathComponent("content.md"),
            encoding: .utf8
        )) ?? ""
        let notes = (try? String(
            contentsOf: directory.appendingPathComponent("notes.md"),
            encoding: .utf8
        )) ?? ""
        let sources = metadata.kind == .note
            ? [content, notes]
            : [notes] + metadata.blocks.map(\.text)
        let sourceText = sources.joined(separator: "\n\n")
        let revision = ContentPresentationStore.revision(for: sourceText)
        if ContentPresentationStore.isCurrent(
            in: directory,
            revision: revision
        ) {
            return false
        }
        let generated = ContentTitleGenerator.title(
            from: sources,
            fallback: metadata.title
        )
        let changed = generated != metadata.title
        metadata.title = generated
        try ContentTitleGenerator.markGenerated(in: directory)
        return changed
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
