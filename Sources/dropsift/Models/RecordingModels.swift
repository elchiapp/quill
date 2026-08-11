import DropsiftShared
import Foundation

struct TranscriptDocument: Codable, Sendable {
    struct DiarizationInfo: Codable, Sendable {
        let engine: String
        let model: String
        let track: String
        let speakerCount: Int

        enum CodingKeys: String, CodingKey {
            case engine
            case model
            case track
            case speakerCount = "speaker_count"
        }
    }

    struct Segment: Codable, Identifiable, Sendable {
        let speaker: String
        let startMs: Int
        let endMs: Int
        let text: String

        var id: String { "\(speaker)-\(startMs)-\(endMs)-\(text.hashValue)" }

        enum CodingKeys: String, CodingKey {
            case speaker
            case startMs = "start_ms"
            case endMs = "end_ms"
            case text
        }
    }

    let engine: String
    let model: String
    let createdAt: String
    let segments: [Segment]
    let languageCode: String?
    let diarization: DiarizationInfo?

    init(
        engine: String,
        model: String,
        createdAt: String,
        segments: [Segment],
        languageCode: String? = nil,
        diarization: DiarizationInfo? = nil
    ) {
        self.engine = engine
        self.model = model
        self.createdAt = createdAt
        self.segments = segments
        self.languageCode = languageCode
        self.diarization = diarization
    }

    enum CodingKeys: String, CodingKey {
        case engine
        case model
        case createdAt = "created_at"
        case segments
        case languageCode = "language_code"
        case diarization
    }

    func write(to directory: URL, title: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self)
            .write(to: directory.appendingPathComponent("transcript.json"), options: .atomic)
        let speakerNames = SharedSpeakerNameStore.load(from: directory)
        try Data(rendered(title: title, speakerNames: speakerNames).utf8)
            .write(to: directory.appendingPathComponent("transcript.md"), options: .atomic)
    }

    private func rendered(title: String, speakerNames: [String: String]) -> String {
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))", ""]
        if let languageCode {
            lines.append("language: \(languageCode) (detected from transcript text)")
            lines.append("")
        }
        if let diarization {
            lines.append(
                "diarization: \(diarization.engine) (\(diarization.model)), "
                    + "\(diarization.speakerCount) remote speaker(s)"
            )
            lines.append("")
        }
        for segment in segments {
            let speaker = SharedSpeakerNameStore.displayName(
                for: segment.speaker,
                names: speakerNames
            )
            lines.append(
                "**[\(Self.clock(segment.startMs))] \(speaker):** \(segment.text)"
            )
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func clock(_ milliseconds: Int) -> String {
        let total = milliseconds / 1000
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

struct RecordingItem: Identifiable, Sendable {
    struct Metadata: Codable, Sendable {
        let started: String?
        let ended: String?
        let durationSeconds: Int?
        let files: [String: String]?

        enum CodingKeys: String, CodingKey {
            case started
            case ended
            case durationSeconds = "duration_seconds"
            case files
        }
    }

    let id: String
    let directory: URL
    let title: String
    let startedAt: Date?
    let endedAt: Date?
    let durationSeconds: Int
    let micURL: URL?
    let systemURL: URL?
    let transcript: TranscriptDocument?
    let notes: String
    let speakerNames: [String: String]

    init(
        id: String,
        directory: URL,
        title: String,
        startedAt: Date?,
        endedAt: Date?,
        durationSeconds: Int,
        micURL: URL?,
        systemURL: URL?,
        transcript: TranscriptDocument?,
        notes: String,
        speakerNames: [String: String] = [:]
    ) {
        self.id = id
        self.directory = directory
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.micURL = micURL
        self.systemURL = systemURL
        self.transcript = transcript
        self.notes = notes
        self.speakerNames = speakerNames
    }

    func speakerName(for speakerID: String) -> String {
        SharedSpeakerNameStore.displayName(for: speakerID, names: speakerNames)
    }

    var isTranscribed: Bool { transcript != nil }
    var segmentCount: Int { transcript?.segments.count ?? 0 }

    var generatedDescription: String {
        ContentPresentationStore.load(from: directory)?.description
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var summary: RecordingSummary? {
        RecordingSummaryStore.load(from: directory)
    }

    var preview: String {
        guard let segments = transcript?.segments, !segments.isEmpty else {
            return "Waiting for transcription"
        }
        return segments.prefix(2).map(\.text).joined(separator: " ")
    }

    var listDescription: String {
        generatedDescription.isEmpty ? preview : generatedDescription
    }

    var displayDate: String {
        guard let startedAt else { return id }
        return startedAt.formatted(
            .dateTime
                .month(.abbreviated)
                .day()
                .year()
                .hour()
                .minute()
        )
    }

    var displayDuration: String {
        let hours = durationSeconds / 3600
        let minutes = (durationSeconds % 3600) / 60
        let seconds = durationSeconds % 60
        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        }
        if minutes > 0 {
            return String(format: "%dm %02ds", minutes, seconds)
        }
        return "\(seconds)s"
    }

    static func load(from directory: URL) -> RecordingItem? {
        let decoder = JSONDecoder()
        let metadata: Metadata? = {
            let url = directory.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(Metadata.self, from: data)
        }()

        let transcript: TranscriptDocument? = {
            let url = directory.appendingPathComponent("transcript.json")
            guard let data = try? Data(contentsOf: url) else { return nil }
            guard let document = try? decoder.decode(
                TranscriptDocument.self,
                from: data
            ) else { return nil }
            let deduplicated = TranscriptEchoDeduplicator.removeEchoes(
                from: document.segments
            )
            guard deduplicated.count != document.segments.count else {
                return document
            }
            return TranscriptDocument(
                engine: document.engine,
                model: document.model,
                createdAt: document.createdAt,
                segments: deduplicated,
                languageCode: document.languageCode,
                diarization: document.diarization
            )
        }()

        guard metadata != nil || transcript != nil else { return nil }

        let startedAt = metadata?.started.flatMap(Self.parseDate)
            ?? Self.dateFromFolderName(directory.lastPathComponent)
        let endedAt = metadata?.ended.flatMap(Self.parseDate)
        let transcriptDuration = (transcript?.segments.last?.endMs ?? 0) / 1000
        let duration = metadata?.durationSeconds
            ?? endedAt.flatMap { end in startedAt.map { Int(end.timeIntervalSince($0)) } }
            ?? transcriptDuration

        let titleURL = directory.appendingPathComponent("title.txt")
        let customTitle = (try? String(contentsOf: titleURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = customTitle.flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.defaultTitle(startedAt: startedAt, folderName: directory.lastPathComponent)
        let notes = (try? String(
            contentsOf: directory.appendingPathComponent("notes.md"),
            encoding: .utf8
        )) ?? ""

        func trackURL(_ key: String) -> URL? {
            guard let filename = metadata?.files?[key] else { return nil }
            let url = directory.appendingPathComponent(filename)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        return RecordingItem(
            id: directory.lastPathComponent,
            directory: directory,
            title: title,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: max(duration, 0),
            micURL: trackURL("mic"),
            systemURL: trackURL("system"),
            transcript: transcript,
            notes: notes,
            speakerNames: SharedSpeakerNameStore.load(from: directory)
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func dateFromFolderName(_ name: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd-HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: String(name.prefix(15)))
    }

    private static func defaultTitle(startedAt: Date?, folderName: String) -> String {
        guard let startedAt else { return "Recording \(folderName)" }
        return "Meeting · " + startedAt.formatted(
            .dateTime.month(.abbreviated).day().hour().minute()
        )
    }
}
