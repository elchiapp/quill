import Foundation

enum RecordingLibrary {
    static let legacyRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    static func load(from root: URL) -> [RecordingItem] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .compactMap(RecordingItem.load(from:))
            .sorted {
                ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast)
            }
    }

    /// Copy legacy recordings into iCloud once, but keep the originals as a
    /// safety net. Existing destination sessions always win.
    static func copyLegacyRecordingsIfNeeded(to root: URL) {
        let fileManager = FileManager.default
        let legacy = legacyRoot.standardizedFileURL
        guard root.standardizedFileURL != legacy else { return }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: legacy,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for source in entries {
            let destination = root.appendingPathComponent(
                source.lastPathComponent,
                isDirectory: true
            )
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try? fileManager.copyItem(at: source, to: destination)
        }
    }

    static func saveTitle(_ title: String, for recording: RecordingItem) throws {
        try Data(title.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
            .write(
                to: recording.directory.appendingPathComponent("title.txt"),
                options: .atomic
            )
    }

    static func saveNotes(_ notes: String, to directory: URL) throws {
        try Data(notes.utf8).write(
            to: directory.appendingPathComponent("notes.md"),
            options: .atomic
        )
    }
}
