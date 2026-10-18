import Foundation

struct LibraryFileRevision: Equatable, Sendable {
    let modified: Date?
    let created: Date?
    let size: UInt64
    let inode: UInt64

    init?(url: URL) {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return nil }
        modified = values[.modificationDate] as? Date
        created = values[.creationDate] as? Date
        size = (values[.size] as? NSNumber)?.uint64Value ?? 0
        inode = (values[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}

/// Reuse parsing and echo removal when only a title, note or summary changes.
final class TranscriptFileCache: @unchecked Sendable {
    static let shared = TranscriptFileCache()
    private struct Entry {
        let revision: LibraryFileRevision
        let document: TranscriptDocument
    }
    private let lock = NSLock()
    private var entries: [URL: Entry] = [:]

    func load(
        from url: URL,
        read: (URL) -> TranscriptDocument?
    ) -> TranscriptDocument? {
        let key = url.standardizedFileURL
        guard let revision = LibraryFileRevision(url: key) else {
            _ = lock.withLock { entries.removeValue(forKey: key) }
            return nil
        }
        if let cached = lock.withLock({ entries[key] }), cached.revision == revision {
            return cached.document
        }
        guard let document = read(url) else { return nil }
        // Do not cache a partially written or replaced file under its old revision.
        if LibraryFileRevision(url: key) == revision {
            lock.withLock {
                if entries.count >= 256 { entries.removeAll(keepingCapacity: true) }
                entries[key] = Entry(revision: revision, document: document)
            }
        }
        return document
    }
}

struct LibrarySnapshot: Sendable {
    let recordings: [RecordingItem]
    let knowledgeItems: [KnowledgeItem]
    let changed: Bool
}

/// Metadata checks run only after real events or explicit user actions.
/// Unchanged items retain their parsed transcript and extracted content.
actor LibrarySnapshotLoader {
    private struct Entry<Item: Sendable>: Sendable {
        let revision: [String: LibraryFileRevision]
        let item: Item
    }

    private let root: URL
    private let knowledgeRoot: URL
    private var recordings: [URL: Entry<RecordingItem>] = [:]
    private var knowledge: [URL: Entry<KnowledgeItem>] = [:]
    private static let filenames = [
        "meta.json", "transcript.json", "item.json", "title.txt", "notes.md",
        "content.md", "speakers.json", "terminology.json", "presentation.json",
        "summary.json", ".recording-active", ".transcription-pending",
    ]

    init(root: URL, knowledgeRoot: URL, recordings: [RecordingItem], knowledge: [KnowledgeItem]) {
        self.root = root
        self.knowledgeRoot = knowledgeRoot
        for item in recordings {
            self.recordings[Self.directoryKey(item.directory)] = Entry(
                revision: Self.revision(in: item.directory), item: item
            )
        }
        for item in knowledge {
            self.knowledge[Self.directoryKey(item.directory)] = Entry(
                revision: Self.revision(in: item.directory), item: item
            )
        }
    }

    func load(refreshGeneratedTitles: Bool) -> LibrarySnapshot {
        var changed = false
        if let directories = Self.directories(in: root) {
            let current = Set(directories)
            for key in recordings.keys where !current.contains(key) {
                recordings.removeValue(forKey: key)
                changed = true
            }
            for directory in directories {
                let revision = Self.revision(in: directory)
                guard recordings[directory]?.revision != revision else { continue }
                guard var item = RecordingItem.load(from: directory) else { continue }
                if refreshGeneratedTitles {
                    _ = try? RecordingLibrary.refreshGeneratedTitle(
                        in: directory, transcript: item.transcript
                    )
                    item = RecordingItem.load(from: directory) ?? item
                }
                recordings[directory] = Entry(
                    revision: Self.revision(in: directory), item: item
                )
                changed = true
            }
        }
        if let directories = Self.directories(in: knowledgeRoot) {
            let current = Set(directories)
            for key in knowledge.keys where !current.contains(key) {
                knowledge.removeValue(forKey: key)
                changed = true
            }
            for directory in directories {
                let revision = Self.revision(in: directory)
                guard knowledge[directory]?.revision != revision else { continue }
                guard let item = KnowledgeLibrary.loadItem(
                    from: directory, refreshGeneratedTitles: refreshGeneratedTitles
                ) else { continue }
                knowledge[directory] = Entry(revision: Self.revision(in: directory), item: item)
                changed = true
            }
        }
        return LibrarySnapshot(
            recordings: recordings.values.map(\.item).sorted {
                ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast)
            },
            knowledgeItems: knowledge.values.map(\.item).sorted { $0.createdAt > $1.createdAt },
            changed: changed
        )
    }

    private static func revision(in directory: URL) -> [String: LibraryFileRevision] {
        var result: [String: LibraryFileRevision] = [:]
        // Directory changes also detect audio/asset appearance after metadata sync.
        result["."] = LibraryFileRevision(url: directory)
        for name in filenames {
            result[name] = LibraryFileRevision(url: directory.appendingPathComponent(name))
        }
        return result
    }

    private static func directories(in root: URL) -> [URL]? {
        try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(directoryKey)
    }

    private static func directoryKey(_ directory: URL) -> URL {
        URL(
            fileURLWithPath: directory.resolvingSymlinksInPath().standardizedFileURL.path,
            isDirectory: true
        )
    }
}
