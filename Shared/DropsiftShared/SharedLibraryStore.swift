import Foundation

public struct SharedLibraryStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var recordingsRoot: URL {
        root.appendingPathComponent("Recordings", isDirectory: true)
    }

    public var itemsRoot: URL {
        root.appendingPathComponent("Items", isDirectory: true)
    }

    public var threadsRoot: URL {
        root.appendingPathComponent("Threads", isDirectory: true)
    }

    public func prepare() throws {
        for directory in [root, recordingsRoot, itemsRoot, threadsRoot] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let marker = root.appendingPathComponent(".dropsift-library")
        if !FileManager.default.fileExists(atPath: marker.path) {
            try Data("Dropsift shared library\n".utf8).write(to: marker, options: .atomic)
        }
    }

    public func loadSnapshot() -> SharedLibrarySnapshot {
        SharedLibrarySnapshot(
            knowledgeItems: loadKnowledgeItems(),
            recordings: loadRecordings()
        )
    }

    public func loadKnowledgeItems() -> [SharedKnowledgeItem] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: itemsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .compactMap(loadKnowledgeItem)
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func loadRecordings() -> [SharedRecordingItem] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: recordingsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .compactMap(loadRecording)
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func createNote(
        title: String = "Untitled note",
        content: String = ""
    ) throws -> SharedKnowledgeItem {
        try prepare()
        let metadata = SharedKnowledgeMetadata(
            kind: .note,
            title: title,
            blocks: []
        )
        let directory = itemsRoot.appendingPathComponent(
            metadata.id.uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try write(metadata, to: directory)
        try Data(content.utf8).write(
            to: directory.appendingPathComponent("content.md"),
            options: .atomic
        )
        guard let item = loadKnowledgeItem(directory) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return item
    }

    public func importKnowledge(
        source: URL,
        kind: SharedKnowledgeKind,
        blocks: [SharedKnowledgeBlock],
        extractionError: String? = nil
    ) throws -> SharedKnowledgeItem {
        try prepare()
        let id = UUID()
        let directory = itemsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let ext = source.pathExtension.lowercased()
        let filename = ext.isEmpty ? "asset" : "asset.\(ext)"
        try FileManager.default.copyItem(
            at: source,
            to: directory.appendingPathComponent(filename)
        )
        let metadata = SharedKnowledgeMetadata(
            id: id,
            kind: kind,
            title: source.deletingPathExtension().lastPathComponent,
            assetFilename: filename,
            blocks: blocks,
            extractionError: extractionError
        )
        try write(metadata, to: directory)
        guard let item = loadKnowledgeItem(directory) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return item
    }

    public func updateKnowledge(
        id: UUID,
        title: String? = nil,
        content: String? = nil,
        additionalNotes: String? = nil
    ) throws {
        let directory = itemsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        guard var item = loadKnowledgeItem(directory)?.metadata else {
            throw CocoaError(.fileNoSuchFile)
        }
        if let title {
            let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
            item.title = value.isEmpty ? "Untitled \(item.kind.displayName.lowercased())" : value
        }
        if let content {
            try Data(content.utf8).write(
                to: directory.appendingPathComponent("content.md"),
                options: .atomic
            )
        }
        if let additionalNotes {
            try Data(additionalNotes.utf8).write(
                to: directory.appendingPathComponent("notes.md"),
                options: .atomic
            )
        }
        item.updatedAt = Date()
        try write(item, to: directory)
    }

    public func importVoiceRecording(
        source: URL,
        startedAt: Date,
        durationSeconds: Int,
        title: String,
        origin: String
    ) throws -> SharedRecordingItem {
        try prepare()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let id = "\(formatter.string(from: startedAt))-mobile-\(UUID().uuidString.prefix(6))"
        let directory = recordingsRoot.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let ext = source.pathExtension.lowercased()
        let filename = ext.isEmpty ? "mic.m4a" : "mic.\(ext)"
        try FileManager.default.copyItem(
            at: source,
            to: directory.appendingPathComponent(filename)
        )
        let iso = ISO8601DateFormatter()
        let metadata = SharedRecordingMetadata(
            started: iso.string(from: startedAt),
            ended: iso.string(
                from: startedAt.addingTimeInterval(TimeInterval(durationSeconds))
            ),
            durationSeconds: durationSeconds,
            files: ["mic": filename],
            startOffsetMs: ["mic": 0],
            imported: true,
            origin: origin
        )
        try encode(metadata).write(
            to: directory.appendingPathComponent("meta.json"),
            options: .atomic
        )
        try Data(title.utf8).write(
            to: directory.appendingPathComponent("title.txt"),
            options: .atomic
        )
        guard let recording = loadRecording(directory) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return recording
    }

    public func saveTranscript(
        _ transcript: SharedTranscriptDocument,
        recordingID: String
    ) throws {
        let directory = recordingsRoot.appendingPathComponent(
            recordingID,
            isDirectory: true
        )
        try encode(transcript).write(
            to: directory.appendingPathComponent("transcript.json"),
            options: .atomic
        )
        let title = (try? String(
            contentsOf: directory.appendingPathComponent("title.txt"),
            encoding: .utf8
        )) ?? recordingID
        var lines = ["# \(title)", "", "engine: \(transcript.engine) (\(transcript.model))", ""]
        for segment in transcript.segments {
            lines.append(
                "**[\(Self.clock(segment.startMs))] \(segment.speaker):** \(segment.text)"
            )
            lines.append("")
        }
        try Data(lines.joined(separator: "\n").utf8).write(
            to: directory.appendingPathComponent("transcript.md"),
            options: .atomic
        )
    }

    public func updateRecordingNotes(_ notes: String, recordingID: String) throws {
        try Data(notes.utf8).write(
            to: recordingsRoot
                .appendingPathComponent(recordingID, isDirectory: true)
                .appendingPathComponent("notes.md"),
            options: .atomic
        )
    }

    public func search(
        _ query: String,
        limit: Int = 8
    ) -> [SharedSearchResult] {
        let terms = Self.tokenize(query)
        guard !terms.isEmpty else { return [] }
        let snapshot = loadSnapshot()
        var candidates: [SharedSearchResult] = []

        for item in snapshot.knowledgeItems {
            let blocks: [SharedKnowledgeBlock]
            if item.kind == .note {
                blocks = [
                    SharedKnowledgeBlock(
                        text: item.content,
                        locator: "Note"
                    ),
                ]
            } else {
                blocks = item.blocks
            }
            let allBlocks = item.additionalNotes.isEmpty
                ? blocks
                : blocks + [
                    SharedKnowledgeBlock(
                        text: item.additionalNotes,
                        locator: "Notes"
                    ),
                ]
            for block in allBlocks where !block.text.isEmpty {
                let score = Self.score(
                    terms: terms,
                    in: item.title + " " + block.text
                )
                if score > 0 {
                    candidates.append(
                        SharedSearchResult(
                            id: "knowledge:\(item.id):\(block.id)",
                            itemID: "knowledge:\(item.id.uuidString)",
                            title: item.title,
                            kind: SharedTimelineKind(rawValue: item.kind.rawValue) ?? .document,
                            locator: block.locator,
                            text: block.text,
                            score: score,
                            page: block.page
                        )
                    )
                }
            }
        }

        for recording in snapshot.recordings {
            for segment in recording.transcript?.segments ?? [] {
                let score = Self.score(
                    terms: terms,
                    in: recording.title + " " + segment.text
                )
                if score > 0 {
                    candidates.append(
                        SharedSearchResult(
                            id: "recording:\(recording.id):\(segment.startMs)",
                            itemID: "recording:\(recording.id)",
                            title: recording.title,
                            kind: .recording,
                            locator: Self.clock(segment.startMs),
                            text: "\(segment.speaker): \(segment.text)",
                            score: score,
                            startMs: segment.startMs
                        )
                    )
                }
            }
            if !recording.notes.isEmpty {
                let score = Self.score(
                    terms: terms,
                    in: recording.title + " " + recording.notes
                )
                if score > 0 {
                    candidates.append(
                        SharedSearchResult(
                            id: "recording:\(recording.id):notes",
                            itemID: "recording:\(recording.id)",
                            title: recording.title,
                            kind: .recording,
                            locator: "Recording notes",
                            text: recording.notes,
                            score: score
                        )
                    )
                }
            }
        }
        return candidates
            .sorted {
                $0.score == $1.score ? $0.title < $1.title : $0.score > $1.score
            }
            .prefix(limit)
            .map { $0 }
    }

    private func loadKnowledgeItem(_ directory: URL) -> SharedKnowledgeItem? {
        guard let data = try? Data(
            contentsOf: directory.appendingPathComponent("item.json")
        ) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let metadata = try? decoder.decode(
            SharedKnowledgeMetadata.self,
            from: data
        ) else { return nil }
        return SharedKnowledgeItem(
            directory: directory,
            metadata: metadata,
            content: (try? String(
                contentsOf: directory.appendingPathComponent("content.md"),
                encoding: .utf8
            )) ?? "",
            additionalNotes: (try? String(
                contentsOf: directory.appendingPathComponent("notes.md"),
                encoding: .utf8
            )) ?? ""
        )
    }

    private func loadRecording(_ directory: URL) -> SharedRecordingItem? {
        guard let metadataData = try? Data(
            contentsOf: directory.appendingPathComponent("meta.json")
        ) else { return nil }
        let decoder = JSONDecoder()
        guard let metadata = try? decoder.decode(
            SharedRecordingMetadata.self,
            from: metadataData
        ) else { return nil }
        let iso = ISO8601DateFormatter()
        let startedAt = metadata.started.flatMap(iso.date)
            ?? Self.dateFromFolderName(directory.lastPathComponent)
            ?? .distantPast
        let title = ((try? String(
            contentsOf: directory.appendingPathComponent("title.txt"),
            encoding: .utf8
        )) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = title.isEmpty
            ? "Voice message · \(startedAt.formatted(date: .abbreviated, time: .shortened))"
            : title
        let transcript = try? decoder.decode(
            SharedTranscriptDocument.self,
            from: Data(
                contentsOf: directory.appendingPathComponent("transcript.json")
            )
        )
        let audioFilename = metadata.files?["mic"] ?? metadata.files?["system"]
        let audioURL = audioFilename.map(directory.appendingPathComponent)
        return SharedRecordingItem(
            id: directory.lastPathComponent,
            directory: directory,
            title: resolvedTitle,
            startedAt: startedAt,
            durationSeconds: metadata.durationSeconds ?? 0,
            audioURL: audioURL,
            transcript: transcript,
            notes: (try? String(
                contentsOf: directory.appendingPathComponent("notes.md"),
                encoding: .utf8
            )) ?? ""
        )
    }

    private func write(
        _ metadata: SharedKnowledgeMetadata,
        to directory: URL
    ) throws {
        try encode(metadata).write(
            to: directory.appendingPathComponent("item.json"),
            options: .atomic
        )
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 }
    }

    private static func score(terms: [String], in text: String) -> Double {
        let tokens = tokenize(text)
        let frequencies = Dictionary(tokens.map { ($0, 1) }, uniquingKeysWith: +)
        return terms.reduce(0) { partial, term in
            partial + Double(frequencies[term, default: 0])
        }
    }

    private static func dateFromFolderName(_ name: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd-HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: String(name.prefix(15)))
    }

    public static func clock(_ milliseconds: Int) -> String {
        let total = milliseconds / 1_000
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        let hours = total / 3_600
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
