import Foundation
import Testing
@testable import quill

@Test(
    "Offline diarization separates a real audio fixture",
    .enabled(
        if: ProcessInfo.processInfo.environment["QUILL_DIARIZATION_FIXTURE"] != nil,
        "Set QUILL_DIARIZATION_FIXTURE to run the model-backed integration test."
    )
)
func offlineDiarizationIntegration() async throws {
    let path = try #require(
        ProcessInfo.processInfo.environment["QUILL_DIARIZATION_FIXTURE"]
    )
    let engine = SpeakerDiarizationEngine()
    try await engine.prepare()
    let turns = try await engine.diarize(URL(fileURLWithPath: path))
    let speakers = Set(turns.map(\.speaker))

    #expect(!turns.isEmpty)
    #expect(speakers.count >= 2)
}
