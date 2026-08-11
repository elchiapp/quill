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
        let semanticStore = SharedSemanticStore(root: root)
        return SharedLibrarySnapshot(
            knowledgeItems: loadKnowledgeItems(),
            recordings: loadRecordings(),
            tasks: semanticStore.loadTasks(),
            entities: semanticStore.loadEntities()
        )
    }

    public func loadKnowledgeItems() -> [SharedKnowledgeItem] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: itemsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        for directory in entries {
            try? refreshKnowledgeTitle(in: directory)
        }
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
        for directory in entries {
            guard let recording = loadRecording(directory) else { continue }
            let hasContent = !recording.notes
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty || !(recording.transcript?.segments.isEmpty ?? true)
            if hasContent {
                _ = try? refreshRecordingTitle(
                    in: directory,
                    transcript: recording.transcript
                )
            }
        }
        return entries
            .compactMap(loadRecording)
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func createNote(
        title: String = "Untitled note",
        content: String = ""
    ) throws -> SharedKnowledgeItem {
        try prepare()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = trimmedTitle.isEmpty ? "Untitled note" : trimmedTitle
        let isManualTitle = !ContentTitleGenerator.isAutomaticPlaceholder(fallbackTitle)
        let metadata = SharedKnowledgeMetadata(
            kind: .note,
            title: isManualTitle
                ? fallbackTitle
                : ContentTitleGenerator.title(
                    from: [content],
                    fallback: fallbackTitle
                ),
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
        if isManualTitle {
            try ContentTitleGenerator.markManual(in: directory)
        } else {
            try ContentTitleGenerator.markGenerated(in: directory)
        }
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
            title: ContentTitleGenerator.title(
                from: blocks.map(\.text),
                fallback: source.deletingPathExtension().lastPathComponent
            ),
            assetFilename: filename,
            blocks: blocks,
            extractionError: extractionError
        )
        try write(metadata, to: directory)
        try ContentTitleGenerator.markGenerated(in: directory)
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
            try ContentTitleGenerator.markManual(in: directory)
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
        if title == nil,
           ContentTitleGenerator.mayReplaceTitle(item.title, in: directory) {
            let currentContent = (try? String(
                contentsOf: directory.appendingPathComponent("content.md"),
                encoding: .utf8
            )) ?? ""
            let currentNotes = (try? String(
                contentsOf: directory.appendingPathComponent("notes.md"),
                encoding: .utf8
            )) ?? ""
            let sources = item.kind == .note
                ? [currentContent, currentNotes]
                : [currentNotes] + item.blocks.map(\.text)
            item.title = ContentTitleGenerator.title(
                from: sources,
                fallback: item.title
            )
            try ContentTitleGenerator.markGenerated(in: directory)
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
            tracks: [
                .init(file: filename, speaker: "me", offsetMs: 0),
            ],
            imported: true,
            origin: origin,
            resumeCount: 0
        )
        try encode(metadata).write(
            to: directory.appendingPathComponent("meta.json"),
            options: .atomic
        )
        try Data(title.utf8).write(
            to: directory.appendingPathComponent("title.txt"),
            options: .atomic
        )
        try ContentTitleGenerator.markGenerated(in: directory)
        guard let recording = loadRecording(directory) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return recording
    }

    public func appendVoiceRecording(
        source: URL,
        recordingID: String,
        durationSeconds: Int
    ) throws -> SharedRecordingItem {
        let directory = recordingsRoot.appendingPathComponent(
            recordingID,
            isDirectory: true
        )
        let metadataURL = directory.appendingPathComponent("meta.json")
        let decoder = JSONDecoder()
        guard let metadata = try? decoder.decode(
            SharedRecordingMetadata.self,
            from: Data(contentsOf: metadataURL)
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let baseDuration = max(metadata.durationSeconds ?? 0, 0)
        var part = (metadata.resumeCount ?? 0) + 2
        let ext = source.pathExtension.lowercased()
        let suffix = ext.isEmpty ? "m4a" : ext
        var filename = "mic-part-\(part).\(suffix)"
        while FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(filename).path
        ) {
            part += 1
            filename = "mic-part-\(part).\(suffix)"
        }
        try FileManager.default.copyItem(
            at: source,
            to: directory.appendingPathComponent(filename)
        )

        var tracks = metadata.tracks ?? []
        if tracks.isEmpty {
            if let mic = metadata.files?["mic"] {
                tracks.append(
                    .init(
                        file: mic,
                        speaker: "me",
                        offsetMs: metadata.startOffsetMs?["mic"] ?? 0
                    )
                )
            }
            if let system = metadata.files?["system"] {
                tracks.append(
                    .init(
                        file: system,
                        speaker: "them",
                        offsetMs: metadata.startOffsetMs?["system"] ?? 0
                    )
                )
            }
        }
        tracks.append(
            .init(
                file: filename,
                speaker: "me",
                offsetMs: baseDuration * 1_000
            )
        )

        let iso = ISO8601DateFormatter()
        let updated = SharedRecordingMetadata(
            started: metadata.started,
            ended: iso.string(from: Date()),
            durationSeconds: baseDuration + max(durationSeconds, 0),
            files: metadata.files ?? ["mic": filename],
            startOffsetMs: metadata.startOffsetMs,
            tracks: tracks,
            imported: metadata.imported,
            origin: metadata.origin,
            resumeCount: (metadata.resumeCount ?? 0) + 1
        )
        try encode(updated).write(to: metadataURL, options: .atomic)
        try Data().write(
            to: directory.appendingPathComponent(".transcription-pending"),
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
        let title = try refreshRecordingTitle(
            in: directory,
            transcript: transcript
        )
        try writeTranscriptMarkdown(transcript, title: title, to: directory)
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(".transcription-pending")
        )
    }

    public func appendTranscript(
        _ transcript: SharedTranscriptDocument,
        offsetMs: Int,
        recordingID: String
    ) throws {
        let directory = recordingsRoot.appendingPathComponent(
            recordingID,
            isDirectory: true
        )
        let existing = loadRecording(directory)?.transcript
        let shifted = transcript.segments.map {
            SharedTranscriptDocument.Segment(
                speaker: $0.speaker,
                startMs: $0.startMs + offsetMs,
                endMs: $0.endMs + offsetMs,
                text: $0.text
            )
        }
        let merged = SharedTranscriptDocument(
            engine: transcript.engine,
            model: transcript.model,
            createdAt: transcript.createdAt,
            segments: ((existing?.segments ?? []) + shifted).sorted {
                $0.startMs < $1.startMs
            },
            languageCode: transcript.languageCode ?? existing?.languageCode
        )
        try saveTranscript(merged, recordingID: recordingID)
    }

    public func updateRecordingNotes(_ notes: String, recordingID: String) throws {
        let directory = recordingsRoot.appendingPathComponent(
            recordingID,
            isDirectory: true
        )
        try Data(notes.utf8).write(
            to: directory.appendingPathComponent("notes.md"),
            options: .atomic
        )
        let transcript = loadRecording(directory)?.transcript
        let title = try refreshRecordingTitle(
            in: directory,
            transcript: transcript
        )
        if let transcript {
            try writeTranscriptMarkdown(
                transcript,
                title: title,
                to: directory
            )
        }
    }

    public func updateSpeakerNames(
        _ names: [String: String],
        recordingID: String
    ) throws {
        let directory = recordingsRoot.appendingPathComponent(
            recordingID,
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try SharedSpeakerNameStore.save(names, to: directory)
        if let recording = loadRecording(directory),
           let transcript = recording.transcript {
            try writeTranscriptMarkdown(
                transcript,
                title: recording.title,
                to: directory
            )
        }
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
                let speaker = recording.speakerName(for: segment.speaker)
                let score = Self.score(
                    terms: terms,
                    in: recording.title + " " + speaker + " " + segment.text
                )
                if score > 0 {
                    candidates.append(
                        SharedSearchResult(
                            id: "recording:\(recording.id):\(segment.startMs)",
                            itemID: "recording:\(recording.id)",
                            title: recording.title,
                            kind: .recording,
                            locator: Self.clock(segment.startMs),
                            text: "\(speaker): \(segment.text)",
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
        var tracks = metadata.tracks ?? []
        if tracks.isEmpty {
            if let mic = metadata.files?["mic"] {
                tracks.append(
                    .init(
                        file: mic,
                        speaker: "me",
                        offsetMs: metadata.startOffsetMs?["mic"] ?? 0
                    )
                )
            }
            if let system = metadata.files?["system"] {
                tracks.append(
                    .init(
                        file: system,
                        speaker: "them",
                        offsetMs: metadata.startOffsetMs?["system"] ?? 0
                    )
                )
            }
        }
        let audioTracks = tracks.map {
            SharedRecordingAudioTrack(
                url: directory.appendingPathComponent($0.file),
                speaker: $0.speaker,
                offsetMs: $0.offsetMs
            )
        }
        let audioURL = audioTracks.first(where: { $0.speaker == "me" })?.url
            ?? audioTracks.first?.url
        return SharedRecordingItem(
            id: directory.lastPathComponent,
            directory: directory,
            title: resolvedTitle,
            startedAt: startedAt,
            durationSeconds: metadata.durationSeconds ?? 0,
            audioURL: audioURL,
            audioTracks: audioTracks,
            transcript: transcript,
            notes: (try? String(
                contentsOf: directory.appendingPathComponent("notes.md"),
                encoding: .utf8
            )) ?? "",
            speakerNames: SharedSpeakerNameStore.load(from: directory)
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

    private func refreshKnowledgeTitle(in directory: URL) throws {
        guard let loaded = loadKnowledgeItem(directory),
              ContentTitleGenerator.mayReplaceTitle(
                loaded.title,
                in: directory
              )
        else { return }
        let sources = loaded.kind == .note
            ? [loaded.content, loaded.additionalNotes]
            : [loaded.additionalNotes] + loaded.blocks.map(\.text)
        let generated = ContentTitleGenerator.title(
            from: sources,
            fallback: loaded.title
        )
        try ContentTitleGenerator.markGenerated(in: directory)
        guard generated != loaded.title else { return }

        var metadata = loaded.metadata
        metadata.title = generated
        metadata.updatedAt = Date()
        try write(metadata, to: directory)
    }

    private func refreshRecordingTitle(
        in directory: URL,
        transcript: SharedTranscriptDocument?
    ) throws -> String {
        let titleURL = directory.appendingPathComponent("title.txt")
        let existingTitle = (try? String(contentsOf: titleURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard ContentTitleGenerator.mayReplaceTitle(existingTitle, in: directory)
        else {
            return existingTitle.flatMap { $0.isEmpty ? nil : $0 }
                ?? directory.lastPathComponent
        }

        let notes = (try? String(
            contentsOf: directory.appendingPathComponent("notes.md"),
            encoding: .utf8
        )) ?? ""
        let transcriptText = transcript?.segments.map(\.text).joined(separator: "\n") ?? ""
        let generated = ContentTitleGenerator.title(
            from: [notes, transcriptText],
            fallback: existingTitle.flatMap { $0.isEmpty ? nil : $0 }
                ?? directory.lastPathComponent
        )
        if generated != existingTitle {
            try Data(generated.utf8).write(to: titleURL, options: .atomic)
        }
        try ContentTitleGenerator.markGenerated(in: directory)
        return generated
    }

    private func writeTranscriptMarkdown(
        _ transcript: SharedTranscriptDocument,
        title: String,
        to directory: URL
    ) throws {
        var lines = ["# \(title)", "", "engine: \(transcript.engine) (\(transcript.model))", ""]
        let speakerNames = SharedSpeakerNameStore.load(from: directory)
        for segment in transcript.segments {
            let speaker = SharedSpeakerNameStore.displayName(
                for: segment.speaker,
                names: speakerNames
            )
            lines.append(
                "**[\(Self.clock(segment.startMs))] \(speaker):** \(segment.text)"
            )
            lines.append("")
        }
        try Data(lines.joined(separator: "\n").utf8).write(
            to: directory.appendingPathComponent("transcript.md"),
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
