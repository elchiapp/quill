import Foundation

/// The on-disk recording manifest. `files` and `start_offset_ms` retain
/// compatibility with original one-part sessions; `tracks` is the canonical
/// ordered list used once a recording has been resumed.
struct RecordingManifest: Codable, Equatable {
    struct Track: Codable, Equatable {
        let file: String
        let speaker: String
        let offsetMs: Int

        enum CodingKeys: String, CodingKey {
            case file
            case speaker
            case offsetMs = "offset_ms"
        }
    }

    var started: String?
    var ended: String?
    var durationSeconds: Int?
    var files: [String: String]?
    var startOffsetMs: [String: Int]?
    var tracks: [Track]?
    var imported: Bool?
    var resumeCount: Int?

    enum CodingKeys: String, CodingKey {
        case started
        case ended
        case durationSeconds = "duration_seconds"
        case files
        case startOffsetMs = "start_offset_ms"
        case tracks
        case imported
        case resumeCount = "resume_count"
    }

    var transcriptionTracks: [Track] {
        if let tracks, !tracks.isEmpty {
            return tracks
        }

        var legacy: [Track] = []
        if let mic = files?["mic"] {
            legacy.append(
                Track(
                    file: mic,
                    speaker: "me",
                    offsetMs: startOffsetMs?["mic"] ?? 0
                )
            )
        }
        if let system = files?["system"] {
            legacy.append(
                Track(
                    file: system,
                    speaker: "them",
                    offsetMs: startOffsetMs?["system"] ?? 0
                )
            )
        }
        return legacy
    }

    func appendingResume(
        ended: String,
        addedDurationSeconds: Int,
        micFile: String,
        systemFile: String,
        micOffsetMs: Int,
        systemOffsetMs: Int
    ) -> RecordingManifest {
        var updated = self
        let addedDurationSeconds = max(addedDurationSeconds, 0)
        updated.ended = ended
        updated.durationSeconds = max(durationSeconds ?? 0, 0) + addedDurationSeconds
        updated.resumeCount = (resumeCount ?? 0) + 1

        var allTracks = transcriptionTracks
        allTracks.append(
            Track(file: micFile, speaker: "me", offsetMs: micOffsetMs)
        )
        allTracks.append(
            Track(file: systemFile, speaker: "them", offsetMs: systemOffsetMs)
        )
        updated.tracks = allTracks

        var primaryFiles = files ?? [:]
        if primaryFiles["mic"] == nil {
            primaryFiles["mic"] = micFile
        }
        if primaryFiles["system"] == nil {
            primaryFiles["system"] = systemFile
        }
        updated.files = primaryFiles
        return updated
    }

    static func read(from directory: URL) -> RecordingManifest? {
        let url = directory.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RecordingManifest.self, from: data)
    }

    func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(
            to: directory.appendingPathComponent("meta.json"),
            options: .atomic
        )
    }
}

/// One meeting recording: a timestamped folder holding two independent tracks
/// (mic = you, system = them) plus a meta.json written on clean stop. Tracks
/// are separate on purpose — whisper does better on clean single-source audio,
/// and two tracks give free two-party diarization.
final class RecordingSession {
    enum AudioSource: Sendable {
        case microphone
        case system
    }

    let dir: URL
    let startedAt: Date
    let elapsedBaseSeconds: Int

    private let mic: MicRecorder
    private let system: SystemAudioRecorder
    private let micFilename: String
    private let systemFilename: String
    private let baseManifest: RecordingManifest?

    private static let activeMarkerName = ".recording-active"

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Create the session folder under `root` (yyyy.MM.dd-HHmm, suffixed on
    /// collision) without starting capture yet.
    init(
        root: URL,
        onAudioLevel: @escaping @Sendable (AudioSource, Float) -> Void = { _, _ in }
    ) throws {
        startedAt = Date()
        elapsedBaseSeconds = 0
        mic = MicRecorder { onAudioLevel(.microphone, $0) }
        system = SystemAudioRecorder { onAudioLevel(.system, $0) }
        let base = Self.folderFormat.string(from: startedAt)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        dir = candidate
        micFilename = "mic.caf"
        systemFilename = "system.caf"
        baseManifest = nil
    }

    /// Continue an existing item without touching its original audio. The new
    /// capture is stored as another pair of tracks and placed directly after
    /// the previous duration in the shared transcript clock.
    init(
        resuming recording: RecordingItem,
        onAudioLevel: @escaping @Sendable (AudioSource, Float) -> Void = { _, _ in }
    ) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: recording.directory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }

        startedAt = Date()
        dir = recording.directory
        mic = MicRecorder { onAudioLevel(.microphone, $0) }
        system = SystemAudioRecorder { onAudioLevel(.system, $0) }

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
        elapsedBaseSeconds = max(
            manifest.durationSeconds ?? recording.durationSeconds,
            0
        )
        baseManifest = manifest

        var part = (manifest.resumeCount ?? 0) + 2
        while fileManager.fileExists(
            atPath: recording.directory
                .appendingPathComponent("mic-part-\(part).caf").path
        ) || fileManager.fileExists(
            atPath: recording.directory
                .appendingPathComponent("system-part-\(part).caf").path
        ) {
            part += 1
        }
        micFilename = "mic-part-\(part).caf"
        systemFilename = "system-part-\(part).caf"
    }

    /// Start both tracks. If the mic fails after the system tap started, the
    /// tap is torn down so we never run half a session silently.
    func start() throws {
        let marker = dir.appendingPathComponent(Self.activeMarkerName)
        try Data().write(to: marker, options: .atomic)
        do {
            try system.start(
                writingTo: dir.appendingPathComponent(systemFilename)
            )
        } catch {
            try? FileManager.default.removeItem(at: marker)
            discardNewTrackFiles()
            throw error
        }
        do {
            try mic.start(writingTo: dir.appendingPathComponent(micFilename))
        } catch {
            system.stop()
            try? FileManager.default.removeItem(at: marker)
            discardNewTrackFiles()
            throw error
        }
    }

    /// Stop both tracks and write meta.json.
    func stop() {
        mic.stop()
        system.stop()

        let ended = Date()
        let iso = ISO8601DateFormatter()

        // The tracks don't start on the same buffer; record how far each
        // lags the earliest so transcript timestamps share one clock.
        let micStart = mic.firstBufferAt ?? startedAt
        let systemStart = system.firstBufferAt ?? startedAt
        let earliest = min(micStart, systemStart)
        let baseOffsetMs = elapsedBaseSeconds * 1_000
        let micOffsetMs = baseOffsetMs
            + Int(micStart.timeIntervalSince(earliest) * 1_000)
        let systemOffsetMs = baseOffsetMs
            + Int(systemStart.timeIntervalSince(earliest) * 1_000)
        let addedDuration = max(Int(ended.timeIntervalSince(startedAt)), 0)

        let manifest: RecordingManifest
        if let baseManifest {
            manifest = baseManifest.appendingResume(
                ended: iso.string(from: ended),
                addedDurationSeconds: addedDuration,
                micFile: micFilename,
                systemFile: systemFilename,
                micOffsetMs: micOffsetMs,
                systemOffsetMs: systemOffsetMs
            )
        } else {
            manifest = RecordingManifest(
                started: iso.string(from: startedAt),
                ended: iso.string(from: ended),
                durationSeconds: addedDuration,
                files: ["mic": micFilename, "system": systemFilename],
                startOffsetMs: [
                    "mic": micOffsetMs,
                    "system": systemOffsetMs,
                ],
                tracks: [
                    .init(
                        file: micFilename,
                        speaker: "me",
                        offsetMs: micOffsetMs
                    ),
                    .init(
                        file: systemFilename,
                        speaker: "them",
                        offsetMs: systemOffsetMs
                    ),
                ],
                imported: nil,
                resumeCount: 0
            )
        }
        try? manifest.write(to: dir)
        if baseManifest != nil {
            try? Data().write(
                to: dir.appendingPathComponent(".transcription-pending"),
                options: .atomic
            )
        }
        try? FileManager.default.removeItem(
            at: dir.appendingPathComponent(Self.activeMarkerName)
        )
    }

    private func discardNewTrackFiles() {
        try? FileManager.default.removeItem(
            at: dir.appendingPathComponent(micFilename)
        )
        try? FileManager.default.removeItem(
            at: dir.appendingPathComponent(systemFilename)
        )
    }

    /// A crash can leave a marker behind. There is no active capture before
    /// AppModel starts services, so markers found at launch are necessarily
    /// stale and must not suppress transcription forever.
    static func clearStaleActiveMarkers(in root: URL) {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for directory in directories {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(activeMarkerName)
            )
        }
    }
}
