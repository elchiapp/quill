import Foundation

struct DiarizationReprocessResult: Sendable {
    let speakerCount: Int
    let reassignedSegmentCount: Int
    let segmentsPerSpeaker: [String: Int]
}

enum DiarizationReprocessError: LocalizedError {
    case recordingUnavailable
    case transcriptUnavailable
    case unsupportedRemoteTrackCount(Int)
    case audioUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .recordingUnavailable:
            "The recording could not be loaded."
        case .transcriptUnavailable:
            "The recording does not have a transcript to reassign."
        case .unsupportedRemoteTrackCount(let count):
            "Expected one system-audio track, but found \(count)."
        case .audioUnavailable(let filename):
            "The system-audio track is missing: \(filename)."
        }
    }
}

enum DiarizationReprocessor {
    static func reprocess(
        recordingDirectory: URL,
        expectedRemoteSpeakers: Int,
        recoverUnassignedSpeech: Bool = true,
        audioOverride: URL? = nil,
        reassignBeforeSeconds: TimeInterval? = nil
    ) async throws -> DiarizationReprocessResult {
        guard let recording = RecordingItem.load(from: recordingDirectory) else {
            throw DiarizationReprocessError.recordingUnavailable
        }
        guard let transcript = recording.transcript else {
            throw DiarizationReprocessError.transcriptUnavailable
        }

        let remoteTracks = RecordingManifest.read(from: recordingDirectory)?
            .transcriptionTracks
            .filter { $0.speaker == "them" } ?? []
        guard remoteTracks.count == 1 else {
            throw DiarizationReprocessError.unsupportedRemoteTrackCount(remoteTracks.count)
        }

        let remoteTrack = remoteTracks[0]
        let sourceAudioURL = recordingDirectory.appendingPathComponent(remoteTrack.file)
        let audioURL = audioOverride ?? sourceAudioURL
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw DiarizationReprocessError.audioUnavailable(remoteTrack.file)
        }

        let engine = SpeakerDiarizationEngine(
            expectedSpeakerCount: expectedRemoteSpeakers,
            recoverUnassignedSpeech: recoverUnassignedSpeech
        )
        try await engine.prepare()
        defer { engine.release() }
        let turns = try await engine.diarize(audioURL)
        let offsetSeconds = TimeInterval(remoteTrack.offsetMs) / 1_000

        var reassignedSegmentCount = 0
        let segments = transcript.segments.map { segment in
            guard segment.speaker != "me" else { return segment }
            if let reassignBeforeSeconds,
               TimeInterval(segment.startMs) / 1_000 >= reassignBeforeSeconds {
                return segment
            }
            let localSegment = TranscriptSegment(
                start: TimeInterval(segment.startMs) / 1_000 - offsetSeconds,
                end: TimeInterval(segment.endMs) / 1_000 - offsetSeconds,
                text: segment.text
            )
            let speaker = SpeakerAssignment.speaker(
                for: localSegment,
                turns: turns,
                fallback: segment.speaker,
                maximumFallbackDistance: .infinity
            )
            if speaker != segment.speaker {
                reassignedSegmentCount += 1
            }
            return TranscriptDocument.Segment(
                speaker: speaker,
                startMs: segment.startMs,
                endMs: segment.endMs,
                text: segment.text
            )
        }

        let remoteSpeakerCounts = Dictionary(
            grouping: segments.filter { $0.speaker != "me" },
            by: \.speaker
        ).mapValues(\.count)
        let updated = TranscriptDocument(
            engine: transcript.engine,
            model: transcript.model,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            segments: segments,
            languageCode: transcript.languageCode,
            diarization: TranscriptDocument.DiarizationInfo(
                engine: engine.name,
                model: engine.model,
                track: sourceAudioURL.deletingPathExtension().lastPathComponent,
                speakerCount: remoteSpeakerCounts.count
            )
        )
        let title = try RecordingLibrary.refreshGeneratedTitle(
            in: recordingDirectory,
            transcript: updated
        )
        try updated.write(to: recordingDirectory, title: title)

        return DiarizationReprocessResult(
            speakerCount: remoteSpeakerCounts.count,
            reassignedSegmentCount: reassignedSegmentCount,
            segmentsPerSpeaker: remoteSpeakerCounts
        )
    }
}
