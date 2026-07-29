import AVFoundation
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

    static func importAudio(from source: URL, to root: URL) async throws -> URL {
        let resourceValues = try? source.resourceValues(
            forKeys: [.contentModificationDateKey]
        )
        let started = resourceValues?.contentModificationDate ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd-HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let base = formatter.string(from: started)
        var directory = root.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: directory.path) {
            directory = root.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let ext = source.pathExtension.lowercased()
        let filename = ext.isEmpty ? "imported-audio" : "imported-audio.\(ext)"
        try FileManager.default.copyItem(
            at: source,
            to: directory.appendingPathComponent(filename)
        )

        let asset = AVURLAsset(url: source)
        let duration = (try? await asset.load(.duration)).map {
            max(0, Int(CMTimeGetSeconds($0).rounded()))
        } ?? 0
        let iso = ISO8601DateFormatter()
        let meta: [String: Any] = [
            "started": iso.string(from: started),
            "ended": iso.string(from: started.addingTimeInterval(TimeInterval(duration))),
            "duration_seconds": duration,
            "files": ["system": filename],
            "start_offset_ms": ["system": 0],
            "imported": true,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: meta,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: directory.appendingPathComponent("meta.json"), options: .atomic)
        try Data(source.deletingPathExtension().lastPathComponent.utf8).write(
            to: directory.appendingPathComponent("title.txt"),
            options: .atomic
        )
        return directory
    }
}
