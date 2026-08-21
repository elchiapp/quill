import DropsiftShared
import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "me", system.caf → "them"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
actor TranscriptionCoordinator {
    private enum TranscriptionOutcome {
        case completed
        case completedAndRetry
    }

    enum Status: Sendable {
        case idle
        case preparingModel(session: String, detail: String, progress: Double)
        case transcribing(session: String, queued: Int)
        case transcribingProgress(session: String, detail: String, progress: Double)
        case diarizing(session: String, queued: Int)
        case completed(session: String)
        case failed(session: String)
    }

    private var queue: [URL] = []
    private var draining = false
    private var activeSession: URL?
    private var engine: TranscriptionEngine?
    private var engineBackend: AIBackend?
    private var diarizer: (any SpeakerDiarization)?
    private var diarizerBackend: AIBackend?
    private var aiBackend: AIBackend = .native
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    func configureBackend(_ backend: AIBackend) async {
        aiBackend = backend
        guard activeSession == nil else { return }
        if engineBackend != backend {
            await engine?.release()
            engine = nil
            engineBackend = nil
        }
        if diarizerBackend != backend {
            await diarizer?.release()
            diarizer = nil
            diarizerBackend = nil
        }
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard Config.transcriptionEnabled() else {
            runHook(for: sessionDir)
            return
        }
        queue.removeAll { $0.standardizedFileURL == sessionDir.standardizedFileURL }
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Splitting rewrites existing audio and transcript files, so unlike
    /// append-only Resume it still requires exclusive access to the directory.
    func prepareForExclusiveMutation(_ sessionDir: URL) -> Bool {
        let target = sessionDir.standardizedFileURL
        guard activeSession?.standardizedFileURL != target else { return false }
        queue.removeAll { $0.standardizedFileURL == target }
        return true
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort.
    func resumePending(root: URL) {
        guard Config.transcriptionEnabled() else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let fm = FileManager.default
        let pending = entries
            .filter {
                fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
                    && (
                        !fm.fileExists(
                            atPath: $0.appendingPathComponent("transcript.json").path
                        )
                            || fm.fileExists(
                                atPath: $0.appendingPathComponent(
                                    ".transcription-pending"
                                ).path
                            )
                    )
                    && !fm.fileExists(
                        atPath: $0.appendingPathComponent(".recording-active").path
                    )
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where !queue.contains(dir) {
            queue.append(dir)
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(Data(
                "resuming \(pending.count) untranscribed session(s)\n".utf8
            ))
        }
        drainIfIdle()
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastFailure = nil
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            activeSession = dir
            publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))
            do {
                switch try await transcribe(dir) {
                case .completed:
                    try? FileManager.default.removeItem(
                        at: dir.appendingPathComponent(".transcription-pending")
                    )
                    publishCompletedCheckpoint(dir)
                case .completedAndRetry:
                    log(
                        dir,
                        "published checkpoint transcript; recording manifest "
                            + "changed, so retrying with all tracks"
                    )
                    publishCompletedCheckpoint(dir)
                    queue.removeAll {
                        $0.standardizedFileURL == dir.standardizedFileURL
                    }
                    queue.append(dir)
                }
            } catch {
                log(dir, "transcription failed: \(error)")
                lastFailure = dir.lastPathComponent
                notifyUser(
                    title: "Dropsift — transcription failed",
                    body: "\(dir.lastPathComponent) — see transcribe.log"
                )
            }
            activeSession = nil
        }
        await engine?.release()
        engine = nil
        engineBackend = nil
        await diarizer?.release()
        diarizer = nil
        diarizerBackend = nil
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    private func transcribe(_ dir: URL) async throws -> TranscriptionOutcome {
        let manifestSnapshot = try SessionMeta.read(from: dir)
        let selectedBackend = aiBackend
        let engine = try await preparedEngine(
            session: dir.lastPathComponent,
            backend: selectedBackend
        )
        publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))

        var merged: [TranscriptDocument.Segment] = []
        var detectedRemoteSpeakers: Set<String> = []
        var usedDiarization = false
        for track in manifestSnapshot.tracks {
            let audio = dir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing track \(track.file)")
                continue
            }
            log(dir, "transcribing \(track.file) (\(engine.name))")
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript — log it and keep going.
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
            } catch {
                log(dir, "skipping \(track.file): \(error)")
                continue
            }

            var speakerTurns: [DetectedSpeakerTurn] = []
            if track.speaker == "them", Config.diarizationEnabled() {
                publish(.diarizing(session: dir.lastPathComponent, queued: queue.count))
                log(dir, "diarizing \(track.file) (\(Config.diarizationEngine()))")
                do {
                    let diarizer = try await preparedDiarizer(
                        backend: selectedBackend
                    )
                    speakerTurns = try await diarizer.diarize(audio)
                    detectedRemoteSpeakers.formUnion(speakerTurns.map(\.speaker))
                    usedDiarization = !speakerTurns.isEmpty
                    log(
                        dir,
                        "diarization found \(detectedRemoteSpeakers.count) remote speaker(s)"
                    )
                } catch {
                    log(dir, "diarization unavailable; using \"them\": \(error)")
                }
            }

            let offset = TimeInterval(track.offsetMs) / 1000
            merged += segments.map {
                let speaker = track.speaker == "them"
                    ? SpeakerAssignment.speaker(
                        for: $0,
                        turns: speakerTurns,
                        fallback: track.speaker
                    )
                    : track.speaker
                return TranscriptDocument.Segment(
                    speaker: speaker,
                    startMs: Int(($0.start + offset) * 1000),
                    endMs: Int(($0.end + offset) * 1000),
                    text: $0.text
                )
            }
        }
        merged.sort { $0.startMs < $1.startMs }
        let segmentCountBeforeDeduplication = merged.count
        merged = TranscriptEchoDeduplicator.removeEchoes(from: merged)
        let removedEchoes = segmentCountBeforeDeduplication - merged.count
        if removedEchoes > 0 {
            log(
                dir,
                "removed \(removedEchoes) duplicate mic echo segment(s)"
            )
        }

        let transcript = TranscriptDocument(
            engine: engine.name,
            model: engine.model,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            segments: merged,
            languageCode: TranscriptLanguageDetector.detect(in: merged),
            diarization: usedDiarization
                ? TranscriptDocument.DiarizationInfo(
                    engine: preparedDiarizerName(for: selectedBackend),
                    model: preparedDiarizerModel(for: selectedBackend),
                    track: "system",
                    speakerCount: detectedRemoteSpeakers.count
                )
                : nil
        )

        let manifestChanged = try SessionMeta.read(from: dir) != manifestSnapshot

        try ContentPresentationStore.invalidate(in: dir)
        try RecordingSummaryStore.invalidate(in: dir)
        let title = try RecordingLibrary.refreshGeneratedTitle(
            in: dir,
            transcript: transcript
        )
        try transcript.write(
            to: dir,
            title: title
        )
        log(dir, "done — \(merged.count) segments")
        return manifestChanged ? .completedAndRetry : .completed
    }

    private func publishCompletedCheckpoint(_ dir: URL) {
        notifyUser(title: "Dropsift — transcript ready", body: dir.lastPathComponent)
        runHook(for: dir)
        publish(.completed(session: dir.lastPathComponent))
    }

    private func preparedEngine(
        session: String,
        backend: AIBackend
    ) async throws -> TranscriptionEngine {
        if let engine, engineBackend == backend { return engine }
        await engine?.release()
        self.engine = nil
        engineBackend = nil
        if backend == .qvac {
            let engine = QVACTranscriptionEngine(
                onPreparationProgress: { [weak self] progress, detail in
                    Task {
                        await self?.publish(.preparingModel(
                            session: session,
                            detail: detail,
                            progress: progress
                        ))
                    }
                },
                onTranscriptionProgress: { [weak self] progress, detail in
                    Task {
                        await self?.publish(.transcribingProgress(
                            session: session,
                            detail: detail,
                            progress: progress
                        ))
                    }
                }
            )
            try await engine.prepare()
            self.engine = engine
            engineBackend = backend
            return engine
        }
        let configured = Config.transcriptionEngine()
        if configured != "parakeet" {
            FileHandle.standardError.write(Data(
                "warning: unknown transcription engine \"\(configured)\" — using parakeet\n".utf8
            ))
        }
        let engine = ParakeetEngine { [weak self] progress, detail in
            Task {
                await self?.publish(.preparingModel(
                    session: session,
                    detail: detail,
                    progress: progress
                ))
            }
        }
        try await engine.prepare()
        self.engine = engine
        engineBackend = backend
        return engine
    }

    private func preparedDiarizerName(for backend: AIBackend) -> String {
        backend == .qvac ? "qvac-sortformer" : "offline-vbx"
    }

    private func preparedDiarizerModel(for backend: AIBackend) -> String {
        backend == .qvac
            ? "parakeet-sortformer-4spk-v2.1-q8_0"
            : "pyannote-community-1-wespeaker-vbx-coreml"
    }

    private func preparedDiarizer(
        backend: AIBackend
    ) async throws -> any SpeakerDiarization {
        if let diarizer, diarizerBackend == backend { return diarizer }
        await diarizer?.release()
        diarizer = nil
        diarizerBackend = nil
        if backend == .qvac {
            let diarizer = QVACSpeakerDiarizationEngine()
            try await diarizer.prepare()
            self.diarizer = diarizer
            diarizerBackend = backend
            return diarizer
        }
        let configured = Config.diarizationEngine()
        if configured != preparedDiarizerName(for: backend) {
            FileHandle.standardError.write(Data(
                "warning: unknown diarization engine \"\(configured)\" — using offline-vbx\n".utf8
            ))
        }
        let diarizer = SpeakerDiarizationEngine()
        try await diarizer.prepare()
        self.diarizer = diarizer
        diarizerBackend = backend
        return diarizer
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) {
        guard let cmd = Config.onStop() else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
        }
    }

    private func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, and how far each track started after the earliest one.
struct SessionMeta: Equatable {
    struct Track: Equatable {
        let file: String
        let speaker: String
        let offsetMs: Int
    }

    let tracks: [Track]

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            }
        }
    }

    static func read(from dir: URL) throws -> SessionMeta {
        let url = dir.appendingPathComponent("meta.json")
        guard let manifest = RecordingManifest.read(from: dir) else {
            throw MetaError.unreadable(url)
        }
        return SessionMeta(
            tracks: manifest.transcriptionTracks.map {
                Track(
                    file: $0.file,
                    speaker: $0.speaker,
                    offsetMs: $0.offsetMs
                )
            }
        )
    }
}
