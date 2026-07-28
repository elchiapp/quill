import FluidAudio
import Foundation

struct DetectedSpeakerTurn: Sendable, Equatable {
    let speaker: String
    let start: TimeInterval
    let end: TimeInterval
    let confidence: Float
}

/// Batch diarization for completed system-audio tracks. The offline
/// Pyannote/WeSpeaker/VBx pipeline is FluidAudio's highest-quality option for
/// complete meeting files and determines the speaker count automatically.
final class SpeakerDiarizationEngine: @unchecked Sendable {
    let name = "offline-vbx"
    let model = "pyannote-community-1-wespeaker-vbx-coreml"

    // OfflineDiarizerManager uses read-only Core ML models after preparation
    // but does not declare Sendable. TranscriptionCoordinator is an actor and
    // serializes every call into this wrapper.
    private var manager: OfflineDiarizerManager?

    func prepare() async throws {
        guard manager == nil else { return }
        let manager = OfflineDiarizerManager()
        try await manager.prepareModels()
        self.manager = manager
    }

    func diarize(_ audio: URL) async throws -> [DetectedSpeakerTurn] {
        guard let manager else {
            throw DiarizerError.notInitialized
        }
        let result = try await manager.process(audio)
        let rawIDs = Set(result.segments.map(\.speakerId))
            .sorted { lhs, rhs in
                lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        let labels = Dictionary(
            uniqueKeysWithValues: rawIDs.enumerated().map {
                ($0.element, "speaker_\($0.offset + 1)")
            }
        )

        return result.segments
            .compactMap { segment in
                guard let speaker = labels[segment.speakerId] else { return nil }
                return DetectedSpeakerTurn(
                    speaker: speaker,
                    start: TimeInterval(segment.startTimeSeconds),
                    end: TimeInterval(segment.endTimeSeconds),
                    confidence: segment.qualityScore
                )
            }
            .sorted {
                if $0.start == $1.start { return $0.speaker < $1.speaker }
                return $0.start < $1.start
            }
    }

    func release() {
        manager = nil
    }
}

enum SpeakerAssignment {
    /// Select the speaker with the greatest time overlap. Parakeet emits
    /// sentence-like segments, while the diarizer emits voice turns, so
    /// overlap duration is more stable than choosing the nearest boundary.
    static func speaker(
        for transcriptSegment: TranscriptSegment,
        turns: [DetectedSpeakerTurn],
        fallback: String = "them"
    ) -> String {
        guard !turns.isEmpty else { return fallback }

        var overlapBySpeaker: [String: TimeInterval] = [:]
        for turn in turns {
            let overlap = max(
                0,
                min(transcriptSegment.end, turn.end)
                    - max(transcriptSegment.start, turn.start)
            )
            if overlap > 0 {
                overlapBySpeaker[turn.speaker, default: 0] += overlap
            }
        }

        if let best = overlapBySpeaker.max(by: {
            if $0.value == $1.value { return $0.key > $1.key }
            return $0.value < $1.value
        }), best.value >= 0.05 {
            return best.key
        }

        let midpoint = (transcriptSegment.start + transcriptSegment.end) / 2
        let nearest = turns.min { lhs, rhs in
            distance(from: midpoint, to: lhs) < distance(from: midpoint, to: rhs)
        }
        if let nearest, distance(from: midpoint, to: nearest) <= 1.5 {
            return nearest.speaker
        }
        return fallback
    }

    private static func distance(
        from time: TimeInterval,
        to turn: DetectedSpeakerTurn
    ) -> TimeInterval {
        if time < turn.start { return turn.start - time }
        if time > turn.end { return time - turn.end }
        return 0
    }
}
