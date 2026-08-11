import Foundation
import Testing
@testable import dropsift

@Test(
    "Offline diarization separates a real audio fixture",
    .enabled(
        if: ProcessInfo.processInfo.environment["DROPSIFT_DIARIZATION_FIXTURE"] != nil,
        "Set DROPSIFT_DIARIZATION_FIXTURE to run the model-backed integration test."
    )
)
func offlineDiarizationIntegration() async throws {
    let environment = ProcessInfo.processInfo.environment
    let path = try #require(environment["DROPSIFT_DIARIZATION_FIXTURE"])
    let expectedSpeakerCount = environment["DROPSIFT_DIARIZATION_SPEAKERS"].flatMap(Int.init)
    let clusteringThreshold = environment["DROPSIFT_DIARIZATION_THRESHOLD"].flatMap(Double.init)
    let engine = SpeakerDiarizationEngine(
        expectedSpeakerCount: expectedSpeakerCount,
        clusteringThreshold: clusteringThreshold,
        recoverUnassignedSpeech: environment["DROPSIFT_DIARIZATION_RECOVER"] == "1"
    )
    try await engine.prepare()
    let turns = try await engine.diarize(URL(fileURLWithPath: path))
    let speakers = Set(turns.map(\.speaker))

    if let outputPath = environment["DROPSIFT_DIARIZATION_OUTPUT"] {
        let output = turns.map { turn in
            [
                "speaker": turn.speaker,
                "start": turn.start,
                "end": turn.end,
                "confidence": Double(turn.confidence),
            ] as [String: Any]
        }
        let data = try JSONSerialization.data(
            withJSONObject: output,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    #expect(!turns.isEmpty)
    #expect(speakers.count >= 2)
}

@Test(
    "Reprocess a recording with a known remote-speaker count",
    .enabled(
        if: ProcessInfo.processInfo.environment["DROPSIFT_REDIARIZE_RECORDING"] != nil,
        "Set DROPSIFT_REDIARIZE_RECORDING to run the mutating integration test."
    )
)
func reprocessRecordingDiarizationIntegration() async throws {
    let environment = ProcessInfo.processInfo.environment
    let directory = try #require(environment["DROPSIFT_REDIARIZE_RECORDING"])
    let expectedSpeakers = environment["DROPSIFT_REDIARIZE_SPEAKERS"].flatMap(Int.init) ?? 2
    let audioOverride = environment["DROPSIFT_REDIARIZE_AUDIO"].map {
        URL(fileURLWithPath: $0)
    }
    let reassignBeforeSeconds = environment["DROPSIFT_REDIARIZE_BEFORE_SECONDS"]
        .flatMap(Double.init)
    let result = try await DiarizationReprocessor.reprocess(
        recordingDirectory: URL(fileURLWithPath: directory, isDirectory: true),
        expectedRemoteSpeakers: expectedSpeakers,
        audioOverride: audioOverride,
        reassignBeforeSeconds: reassignBeforeSeconds
    )

    #expect(result.speakerCount >= expectedSpeakers)
    #expect(result.reassignedSegmentCount > 0)
}
