import Foundation
import Testing
@testable import dropsift

@Test
func transcriptRetrieverFindsRelevantMeetingAcrossLibrary() {
    let transcript = TranscriptDocument(
        engine: "test",
        model: "test",
        createdAt: "2026-07-28T12:00:00Z",
        segments: [
            .init(
                speaker: "them",
                startMs: 1_000,
                endMs: 4_000,
                text: "We decided to ship the new release on Friday."
            ),
            .init(
                speaker: "me",
                startMs: 5_000,
                endMs: 7_000,
                text: "I will prepare the release notes."
            ),
        ]
    )
    let recording = RecordingItem(
        id: "meeting-1",
        directory: URL(fileURLWithPath: "/tmp/meeting-1"),
        title: "Release planning",
        startedAt: Date(),
        endedAt: Date(),
        durationSeconds: 60,
        micURL: nil,
        systemURL: nil,
        transcript: transcript,
        notes: ""
    )

    let matches = TranscriptRetriever.retrieve(
        query: "When are we shipping the release?",
        recordings: [recording],
        scope: .all
    )

    #expect(matches.count == 1)
    #expect(matches[0].recordingID == "meeting-1")
    #expect(matches[0].text.contains("Friday"))
    #expect(matches[0].citation.contains("Release planning"))
}

@Test
func speakerAssignmentUsesGreatestOverlapAndNearbyFallback() {
    let turns = [
        DetectedSpeakerTurn(speaker: "speaker_1", start: 0, end: 4, confidence: 0.9),
        DetectedSpeakerTurn(speaker: "speaker_2", start: 4, end: 9, confidence: 0.8),
    ]

    let overlapping = TranscriptSegment(start: 3.5, end: 7, text: "Remote answer")
    #expect(SpeakerAssignment.speaker(for: overlapping, turns: turns) == "speaker_2")

    let nearby = TranscriptSegment(start: 9.2, end: 9.5, text: "Last word")
    #expect(SpeakerAssignment.speaker(for: nearby, turns: turns) == "speaker_2")

    let distant = TranscriptSegment(start: 20, end: 21, text: "Unknown")
    #expect(SpeakerAssignment.speaker(for: distant, turns: turns) == "them")
}

@Test
func builtInModelCacheDetectionAndResponseCleanup() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AIModelCatalog.defaultModel
    let snapshot = root
        .appendingPathComponent(
            "models--mlx-community--Qwen3.5-2B-4bit/snapshots/test",
            isDirectory: true
        )
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
    try Data().write(to: snapshot.appendingPathComponent("model.safetensors"))

    #expect(BuiltInLLMEngine.hasCachedModel(model, in: root))
    #expect(
        BuiltInLLMEngine.clean("<think>private reasoning</think>\nShip Friday. [1]")
            == "Ship Friday. [1]"
    )
}

@Test
func deviceRecommendationsStayWithinHalfOfUnifiedMemory() {
    let profiles = [
        DeviceProfile(
            chipName: "Test 16 GB",
            totalMemoryBytes: 16 * DeviceProfile.gibibyte,
            processorCount: 8
        ),
        DeviceProfile(
            chipName: "Test 32 GB",
            totalMemoryBytes: 32 * DeviceProfile.gibibyte,
            processorCount: 12
        ),
        DeviceProfile(
            chipName: "Test 128 GB",
            totalMemoryBytes: 128 * DeviceProfile.gibibyte,
            processorCount: 16
        ),
    ]
    let expected = [
        "mlx-community/Qwen3.5-2B-4bit",
        "mlx-community/Qwen3.5-9B-4bit",
        "mlx-community/Qwen3.6-35B-A3B-4bit",
    ]

    for (profile, expectedID) in zip(profiles, expected) {
        let recommendation = AIModelCatalog.recommendation(for: profile)
        #expect(recommendation.model.id == expectedID)
        #expect(
            recommendation.estimatedModelMemoryBytes
                <= profile.totalMemoryBytes / 2
        )
        #expect(recommendation.contextTokens <= recommendation.model.nativeContextTokens)
        #expect(recommendation.contextTokens >= 131_072)
    }
}

@Test
func recordingLoaderReadsCanonicalTranscriptSchema() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let metadata = """
    {
      "started": "2026-07-28T10:00:00Z",
      "ended": "2026-07-28T10:01:00Z",
      "duration_seconds": 60,
      "files": {"mic": "mic.caf", "system": "system.caf"}
    }
    """
    try Data(metadata.utf8).write(to: root.appendingPathComponent("meta.json"))

    let document = TranscriptDocument(
        engine: "parakeet",
        model: "local",
        createdAt: "2026-07-28T10:02:00Z",
        segments: [
            .init(speaker: "me", startMs: 0, endMs: 1_000, text: "Hello")
        ],
        languageCode: "it",
        diarization: .init(
            engine: "offline-vbx",
            model: "local-diarizer",
            track: "system",
            speakerCount: 2
        )
    )
    try document.write(to: root, title: "Test meeting")
    try Data("My meeting".utf8).write(to: root.appendingPathComponent("title.txt"))
    try RecordingLibrary.saveNotes("- Follow up with Marco", to: root)

    let recording = try #require(RecordingItem.load(from: root))
    #expect(recording.title == "My meeting")
    #expect(recording.durationSeconds == 60)
    #expect(recording.transcript?.segments.first?.speaker == "me")
    #expect(recording.transcript?.languageCode == "it")
    #expect(recording.transcript?.diarization?.speakerCount == 2)
    #expect(recording.notes == "- Follow up with Marco")
}

@Test
func transcriptLanguageDetectorRecognizesSupportedLanguages() {
    let segments = [
        TranscriptDocument.Segment(
            speaker: "speaker_1",
            startMs: 0,
            endMs: 5_000,
            text: "Buongiorno, oggi discutiamo il progetto e decidiamo quali attività completare."
        )
    ]

    #expect(TranscriptLanguageDetector.detect(in: segments) == "it")
}

@Test
func chatStoreRoundTripsThreads() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ChatStore(directory: root)
    let thread = ChatThread(
        title: "Project decisions",
        scope: .recording("meeting-1"),
        messages: [
            ChatMessage(role: .user, content: "What did we decide?"),
            ChatMessage(
                role: .assistant,
                content: "Ship Friday. [1]",
                sources: [
                    ChatSource(
                        number: 1,
                        recordingID: "meeting-1",
                        recordingTitle: "Release planning",
                        startMs: 4_000,
                        endMs: 9_000,
                        excerpt: "We decided to ship Friday."
                    )
                ]
            ),
        ]
    )

    try store.save([thread])
    let loaded = store.load()

    #expect(loaded.count == 1)
    #expect(loaded[0].id == thread.id)
    #expect(loaded[0].scope.recordingID == "meeting-1")
    #expect(loaded[0].messages.count == 2)
    #expect(loaded[0].messages[1].sources.first?.startMs == 4_000)
}
