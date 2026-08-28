import AVFoundation
import DropsiftShared
import Foundation

enum RecordingLibrary {
    enum SplitError: LocalizedError {
        case invalidBoundary
        case missingAudio(String)
        case unsupportedAudio(String)

        var errorDescription: String? {
            switch self {
            case .invalidBoundary:
                "Choose a transcript line that has content before and after it."
            case .missingAudio(let file):
                "The audio track “\(file)” is missing."
            case .unsupportedAudio(let file):
                "DropSift couldn’t split the audio track “\(file)”."
            }
        }
    }

    static let legacyRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    static func load(
        from root: URL,
        refreshGeneratedTitles: Bool = true
    ) -> [RecordingItem] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        if refreshGeneratedTitles {
            for directory in entries {
                guard let recording = RecordingItem.load(from: directory) else { continue }
                let hasContent = !recording.notes
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty || !(recording.transcript?.segments.isEmpty ?? true)
                if hasContent {
                    _ = try? refreshGeneratedTitle(
                        in: directory,
                        transcript: recording.transcript
                    )
                }
            }
        }
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
        try saveTitle(title, to: recording.directory)
        let resolved = resolvedTitle(title)
        try recording.transcript?.write(to: recording.directory, title: resolved)
    }

    static func saveTitle(_ title: String, to directory: URL) throws {
        let resolved = resolvedTitle(title)
        try ContentTitleGenerator.markManual(in: directory)
        try Data(resolved.utf8)
            .write(
                to: directory.appendingPathComponent("title.txt"),
                options: .atomic
            )
    }

    private static func resolvedTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled recording" : trimmed
    }

    static func saveNotes(_ notes: String, to directory: URL) throws {
        try ContentPresentationStore.invalidate(in: directory)
        try RecordingSummaryStore.invalidate(in: directory)
        try Data(notes.utf8).write(
            to: directory.appendingPathComponent("notes.md"),
            options: .atomic
        )
        let transcript = RecordingItem.load(from: directory)?.transcript
        let title = try refreshGeneratedTitle(in: directory, transcript: transcript)
        try transcript?.write(to: directory, title: title)
    }

    static func saveSpeakerNames(
        _ names: [String: String],
        for recording: RecordingItem
    ) throws {
        try RecordingSummaryStore.invalidate(in: recording.directory)
        try SharedSpeakerNameStore.save(names, to: recording.directory)
        try recording.transcript?.write(
            to: recording.directory,
            title: recording.title
        )
    }

    static func saveCorrection(
        source: String,
        replacement: String,
        for recording: RecordingItem
    ) throws {
        let updated = SharedTranscriptCorrectionStore.setting(
            source: source,
            replacement: replacement,
            in: recording.corrections
        )
        guard updated != recording.corrections else { return }
        try SharedTranscriptCorrectionStore.save(
            updated,
            to: recording.directory
        )
        try recording.transcript?.write(
            to: recording.directory,
            title: SharedTranscriptCorrectionStore.apply(
                to: recording.title,
                mappings: updated
            )
        )
    }

    static func saveGeneratedPresentation(
        _ presentation: ContentPresentation,
        in directory: URL,
        replacingManualTitle: Bool
    ) throws {
        let titleURL = directory.appendingPathComponent("title.txt")
        let existingTitle = (try? String(
            contentsOf: titleURL,
            encoding: .utf8
        ))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mayReplaceTitle = replacingManualTitle
            || ContentTitleGenerator.mayReplaceTitle(existingTitle, in: directory)
        let resolvedTitle: String
        if mayReplaceTitle {
            resolvedTitle = presentation.title
            try Data(resolvedTitle.utf8).write(to: titleURL, options: .atomic)
            try ContentTitleGenerator.markGenerated(
                in: directory,
                replacingManual: replacingManualTitle
            )
        } else {
            resolvedTitle = existingTitle.flatMap { $0.isEmpty ? nil : $0 }
                ?? presentation.title
        }

        var stored = presentation
        stored.title = resolvedTitle
        try ContentPresentationStore.save(stored, to: directory)
        try RecordingItem.load(from: directory)?.transcript?.write(
            to: directory,
            title: resolvedTitle
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
        try ContentTitleGenerator.markGenerated(in: directory)
        return directory
    }

    /// Splits a completed recording immediately before the transcript segment
    /// at `startMs`. Audio is exported into two new sets of M4A tracks; the
    /// original source files are deliberately left untouched and unreferenced
    /// in the first item so a split remains recoverable from Finder.
    static func splitTranscript(
        _ recording: RecordingItem,
        at startMs: Int
    ) async throws -> RecordingItem {
        guard let transcript = recording.transcript else {
            throw SplitError.invalidBoundary
        }
        let headSegments = transcript.segments
            .filter { $0.startMs < startMs }
            .map {
                TranscriptDocument.Segment(
                    speaker: $0.speaker,
                    startMs: $0.startMs,
                    endMs: min($0.endMs, startMs),
                    text: $0.text
                )
            }
            .filter { $0.endMs > $0.startMs }
        let tailSegments = transcript.segments
            .filter { $0.startMs >= startMs }
            .map {
                TranscriptDocument.Segment(
                    speaker: $0.speaker,
                    startMs: $0.startMs - startMs,
                    endMs: max($0.endMs - startMs, 0),
                    text: $0.text
                )
            }
        guard !headSegments.isEmpty, !tailSegments.isEmpty else {
            throw SplitError.invalidBoundary
        }

        let root = recording.directory.deletingLastPathComponent()
        let finalDirectory = uniqueSplitDirectory(
            in: root,
            startedAt: recording.startedAt?.addingTimeInterval(
                TimeInterval(startMs) / 1_000
            ) ?? Date()
        )
        let stagingDirectory = root.appendingPathComponent(
            ".split-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagedHead = stagingDirectory.appendingPathComponent(
            ".head",
            isDirectory: true
        )
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: stagedHead,
            withIntermediateDirectories: true
        )
        defer {
            if fileManager.fileExists(atPath: stagingDirectory.path) {
                try? fileManager.removeItem(at: stagingDirectory)
            }
        }

        let manifest = RecordingManifest.read(from: recording.directory)
            ?? RecordingManifest(
                started: recording.startedAt.map {
                    ISO8601DateFormatter().string(from: $0)
                },
                ended: recording.endedAt.map {
                    ISO8601DateFormatter().string(from: $0)
                },
                durationSeconds: recording.durationSeconds,
                files: [
                    "mic": recording.micURL?.lastPathComponent,
                    "system": recording.systemURL?.lastPathComponent,
                ].compactMapValues { $0 },
                startOffsetMs: nil,
                tracks: nil,
                imported: nil,
                resumeCount: nil
            )
        var totalDurationMs = max(
            max(recording.durationSeconds * 1_000, transcript.segments.last?.endMs ?? 0),
            startMs + 1
        )
        var headTracks: [RecordingManifest.Track] = []
        var tailTracks: [RecordingManifest.Track] = []
        let token = String(UUID().uuidString.prefix(8)).lowercased()

        for (index, track) in manifest.transcriptionTracks.enumerated() {
            let source = recording.directory.appendingPathComponent(track.file)
            guard fileManager.fileExists(atPath: source.path) else {
                throw SplitError.missingAudio(track.file)
            }
            let asset = AVURLAsset(url: source)
            let duration = try await asset.load(.duration)
            let durationMs = Int((CMTimeGetSeconds(duration) * 1_000).rounded())
            guard durationMs > 0 else {
                throw SplitError.unsupportedAudio(track.file)
            }
            let globalStart = track.offsetMs
            let globalEnd = globalStart + durationMs
            totalDurationMs = max(totalDurationMs, globalEnd)

            let headEnd = min(globalEnd, startMs)
            if headEnd - globalStart >= 50 {
                let filename = "split-head-\(token)-\(index + 1).m4a"
                try await exportAudioClip(
                    source: source,
                    destination: stagedHead.appendingPathComponent(filename),
                    startMs: 0,
                    endMs: headEnd - globalStart
                )
                headTracks.append(
                    .init(
                        file: filename,
                        speaker: track.speaker,
                        offsetMs: globalStart
                    )
                )
            }

            let tailStart = max(globalStart, startMs)
            if globalEnd - tailStart >= 50 {
                let filename = "audio-\(index + 1).m4a"
                try await exportAudioClip(
                    source: source,
                    destination: stagingDirectory.appendingPathComponent(filename),
                    startMs: tailStart - globalStart,
                    endMs: durationMs
                )
                tailTracks.append(
                    .init(
                        file: filename,
                        speaker: track.speaker,
                        offsetMs: max(globalStart - startMs, 0)
                    )
                )
            }
        }

        let iso = ISO8601DateFormatter()
        let splitDate = recording.startedAt?.addingTimeInterval(
            TimeInterval(startMs) / 1_000
        )
        let headManifest = RecordingManifest(
            started: manifest.started,
            ended: splitDate.map(iso.string),
            durationSeconds: max(1, Int(ceil(Double(startMs) / 1_000))),
            files: primaryFiles(from: headTracks),
            startOffsetMs: primaryOffsets(from: headTracks),
            tracks: headTracks,
            imported: manifest.imported,
            resumeCount: nil
        )
        let tailManifest = RecordingManifest(
            started: splitDate.map(iso.string),
            ended: manifest.ended,
            durationSeconds: max(
                1,
                Int(ceil(Double(totalDurationMs - startMs) / 1_000))
            ),
            files: primaryFiles(from: tailTracks),
            startOffsetMs: primaryOffsets(from: tailTracks),
            tracks: tailTracks,
            imported: manifest.imported,
            resumeCount: nil
        )
        let createdAt = iso.string(from: Date())
        let headTranscript = splitDocument(
            transcript,
            segments: headSegments,
            createdAt: createdAt
        )
        let tailTranscript = splitDocument(
            transcript,
            segments: tailSegments,
            createdAt: createdAt
        )

        try tailManifest.write(to: stagingDirectory)
        try SharedSpeakerNameStore.save(
            recording.speakerNames,
            to: stagingDirectory
        )
        try SharedTranscriptCorrectionStore.save(
            recording.corrections,
            to: stagingDirectory
        )
        let tailTitle = try refreshGeneratedTitle(
            in: stagingDirectory,
            transcript: tailTranscript
        )
        try tailTranscript.write(to: stagingDirectory, title: tailTitle)
        for track in headTracks {
            try fileManager.copyItem(
                at: stagedHead.appendingPathComponent(track.file),
                to: recording.directory.appendingPathComponent(track.file)
            )
        }
        try fileManager.removeItem(at: stagedHead)
        try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)

        try headManifest.write(to: recording.directory)
        try ContentPresentationStore.invalidate(in: recording.directory)
        try RecordingSummaryStore.invalidate(in: recording.directory)
        let headTitle = try refreshGeneratedTitle(
            in: recording.directory,
            transcript: headTranscript
        )
        try headTranscript.write(to: recording.directory, title: headTitle)

        guard let item = RecordingItem.load(from: finalDirectory) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return item
    }

    @discardableResult
    static func refreshGeneratedTitle(
        in directory: URL,
        transcript: TranscriptDocument? = nil
    ) throws -> String {
        let titleURL = directory.appendingPathComponent("title.txt")
        let existingTitle = (try? String(contentsOf: titleURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard ContentTitleGenerator.mayReplaceTitle(existingTitle, in: directory)
        else {
            return existingTitle.flatMap { $0.isEmpty ? nil : $0 }
                ?? "Recording \(directory.lastPathComponent)"
        }

        let notes = (try? String(
            contentsOf: directory.appendingPathComponent("notes.md"),
            encoding: .utf8
        )) ?? ""
        let storedTranscript = transcript ?? RecordingItem.load(from: directory)?.transcript
        let corrections = SharedTranscriptCorrectionStore.load(from: directory)
        let transcriptText = SharedTranscriptCorrectionStore.apply(
            to: storedTranscript?.segments
                .map(\.text)
                .joined(separator: "\n") ?? "",
            mappings: corrections
        )
        let correctedNotes = SharedTranscriptCorrectionStore.apply(
            to: notes,
            mappings: corrections
        )
        let revisionNotes = correctedNotes.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let sourceText = revisionNotes.isEmpty
            ? transcriptText
            : "Notes:\n\(revisionNotes)\n\nTranscript:\n\(transcriptText)"
        let revision = ContentPresentationStore.revision(for: sourceText)
        if ContentPresentationStore.isCurrent(
            in: directory,
            revision: revision
        ) {
            return existingTitle.flatMap { $0.isEmpty ? nil : $0 }
                ?? "Recording \(directory.lastPathComponent)"
        }
        let generated = ContentTitleGenerator.title(
            from: [correctedNotes, transcriptText],
            fallback: existingTitle.flatMap { $0.isEmpty ? nil : $0 }
                ?? "Recording \(directory.lastPathComponent)"
        )
        if generated != existingTitle {
            try Data(generated.utf8).write(to: titleURL, options: .atomic)
        }
        try ContentTitleGenerator.markGenerated(in: directory)
        return generated
    }

    private static func uniqueSplitDirectory(
        in root: URL,
        startedAt: Date
    ) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let base = formatter.string(from: startedAt) + "-split"
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent(
                "\(base)-\(suffix)",
                isDirectory: true
            )
            suffix += 1
        }
        return candidate
    }

    private static func exportAudioClip(
        source: URL,
        destination: URL,
        startMs: Int,
        endMs: Int
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw SplitError.unsupportedAudio(source.lastPathComponent)
        }
        exporter.timeRange = CMTimeRange(
            start: CMTime(
                seconds: Double(startMs) / 1_000,
                preferredTimescale: 48_000
            ),
            end: CMTime(
                seconds: Double(endMs) / 1_000,
                preferredTimescale: 48_000
            )
        )
        try await exporter.export(to: destination, as: .m4a)
    }

    private static func primaryFiles(
        from tracks: [RecordingManifest.Track]
    ) -> [String: String] {
        var files: [String: String] = [:]
        if let mic = tracks.first(where: { $0.speaker == "me" }) {
            files["mic"] = mic.file
        }
        if let system = tracks.first(where: { $0.speaker != "me" }) {
            files["system"] = system.file
        }
        return files
    }

    private static func primaryOffsets(
        from tracks: [RecordingManifest.Track]
    ) -> [String: Int] {
        var offsets: [String: Int] = [:]
        if let mic = tracks.first(where: { $0.speaker == "me" }) {
            offsets["mic"] = mic.offsetMs
        }
        if let system = tracks.first(where: { $0.speaker != "me" }) {
            offsets["system"] = system.offsetMs
        }
        return offsets
    }

    private static func splitDocument(
        _ document: TranscriptDocument,
        segments: [TranscriptDocument.Segment],
        createdAt: String
    ) -> TranscriptDocument {
        let remoteSpeakerCount = Set(
            segments.lazy.map(\.speaker).filter { $0 != "me" }
        ).count
        let diarization = document.diarization.map {
            TranscriptDocument.DiarizationInfo(
                engine: $0.engine,
                model: $0.model,
                track: $0.track,
                speakerCount: remoteSpeakerCount
            )
        }
        return TranscriptDocument(
            engine: document.engine,
            model: document.model,
            createdAt: createdAt,
            segments: segments,
            languageCode: TranscriptLanguageDetector.detect(in: segments),
            diarization: diarization
        )
    }
}
