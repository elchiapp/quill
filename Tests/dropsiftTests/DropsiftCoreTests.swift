import AppKit
import AVFoundation
import DropsiftShared
import Foundation
import Testing
@testable import dropsift

@Test
func meetingDetectionWaitsTenSecondsBeforeReportingAnEnd() {
    var tracker = MeetingDetectionTracker()
    let meeting = DetectedMeeting(
        bundleID: "us.zoom.xos",
        appName: "Zoom",
        isBrowser: false
    )
    let started = Date(timeIntervalSince1970: 1_000)

    #expect(tracker.update(current: meeting, now: started) == nil)
    #expect(
        tracker.update(current: meeting, now: started.addingTimeInterval(4))
            == .detected(meeting)
    )
    #expect(tracker.update(current: nil, now: started.addingTimeInterval(5)) == nil)
    #expect(tracker.update(current: nil, now: started.addingTimeInterval(14.9)) == nil)
    #expect(
        tracker.update(current: nil, now: started.addingTimeInterval(15))
            == .ended(meeting)
    )
}

@Test
func meetingDetectionIgnoresBriefMicrophoneDropouts() {
    var tracker = MeetingDetectionTracker()
    let meeting = DetectedMeeting(
        bundleID: "com.microsoft.teams",
        appName: "Microsoft Teams",
        isBrowser: false
    )
    let started = Date(timeIntervalSince1970: 2_000)

    #expect(tracker.update(current: meeting, now: started) == nil)
    #expect(
        tracker.update(current: meeting, now: started.addingTimeInterval(4))
            == .detected(meeting)
    )
    #expect(tracker.update(current: nil, now: started.addingTimeInterval(5)) == nil)
    #expect(tracker.update(current: meeting, now: started.addingTimeInterval(9)) == nil)
    #expect(tracker.update(current: nil, now: started.addingTimeInterval(10)) == nil)
    #expect(tracker.update(current: nil, now: started.addingTimeInterval(20)) == .ended(meeting))
}

@Test
func meetingAutoStopOnlyMatchesTheMeetingThatStartedTheRecording() {
    let zoom = DetectedMeeting(
        bundleID: "us.zoom.xos",
        appName: "Zoom",
        isBrowser: false
    )
    let browser = DetectedMeeting(
        bundleID: "com.apple.Safari",
        appName: "Safari",
        isBrowser: true
    )
    var state = MeetingRecordingAutoStopState()

    state.recordingStarted()
    let endedWithoutDetectedMeeting = state.meetingEnded(zoom)
    #expect(!endedWithoutDetectedMeeting)

    state.meetingDetected(zoom)
    state.recordingStarted()
    let endedDifferentMeeting = state.meetingEnded(browser)
    let endedMatchingMeeting = state.meetingEnded(zoom)
    #expect(!endedDifferentMeeting)
    #expect(endedMatchingMeeting)

    state.meetingDetected(zoom)
    state.recordingStarted()
    state.meetingDetected(browser)
    let endedAfterMeetingAppChanged = state.meetingEnded(browser)
    #expect(endedAfterMeetingAppChanged)

    state.meetingDetected(zoom)
    state.recordingStarted()
    state.recordingStopped()
    let endedAfterManualStop = state.meetingEnded(zoom)
    #expect(!endedAfterManualStop)
}

@Test
func transcriptEchoDeduplicatorRemovesSystemPlaybackFromYouTrack() {
    let segments = [
        TranscriptDocument.Segment(
            speaker: "speaker_3",
            startMs: 161_000,
            endMs: 165_000,
            text: "So it's it's obviously a balance um that we always walk."
        ),
        TranscriptDocument.Segment(
            speaker: "me",
            startMs: 162_000,
            endMs: 166_000,
            text: "So it's it's obviously a a balance um that we always walk."
        ),
        TranscriptDocument.Segment(
            speaker: "speaker_3",
            startMs: 166_000,
            endMs: 171_000,
            text: "But luckily there's many ways to do this very safely with a lot of stuff."
        ),
        TranscriptDocument.Segment(
            speaker: "me",
            startMs: 167_000,
            endMs: 172_000,
            text: "But luckily there's many ways to do this very safely with other stuff."
        ),
        TranscriptDocument.Segment(
            speaker: "speaker_3",
            startMs: 180_000,
            endMs: 185_000,
            text: "The threat picture is always changing."
        ),
        TranscriptDocument.Segment(
            speaker: "me",
            startMs: 190_000,
            endMs: 194_000,
            text: "I think we should pause and discuss this."
        ),
        TranscriptDocument.Segment(
            speaker: "speaker_2",
            startMs: 190_000,
            endMs: 194_000,
            text: "Can everybody see the presentation?"
        ),
    ]

    let deduplicated = TranscriptEchoDeduplicator.removeEchoes(from: segments)

    #expect(deduplicated.count == 5)
    #expect(
        deduplicated.contains {
            $0.speaker == "me" && $0.text.contains("pause and discuss")
        }
    )
    #expect(
        !deduplicated.contains {
            $0.speaker == "me" && $0.text.contains("balance")
        }
    )
}

@Test
func recordingLoaderDeduplicatesExistingTranscriptEchoes() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    try Data(#"{"duration_seconds": 10}"#.utf8).write(
        to: directory.appendingPathComponent("meta.json")
    )
    let transcript = TranscriptDocument(
        engine: "test",
        model: "test",
        createdAt: "2026-07-29T12:00:00Z",
        segments: [
            .init(
                speaker: "speaker_1",
                startMs: 1_000,
                endMs: 5_000,
                text: "The release is ready for Friday."
            ),
            .init(
                speaker: "me",
                startMs: 1_400,
                endMs: 5_400,
                text: "The release is ready for Friday."
            ),
        ]
    )
    try transcript.write(to: directory, title: "Release")

    let recording = try #require(RecordingItem.load(from: directory))
    #expect(recording.transcript?.segments.count == 1)
    #expect(recording.transcript?.segments.first?.speaker == "speaker_1")
}

@Test
func timelineRefreshPreservesSelectionWhileARecordingIsTemporarilyUnavailable() {
    let selectedID = "recording:2026.07.30-1200"

    #expect(
        AppModel.selectionAfterPassiveRefresh(
            current: selectedID,
            availableIDs: ["recording:another-item"]
        ) == selectedID
    )
    #expect(
        AppModel.selectionAfterPassiveRefresh(
            current: selectedID,
            availableIDs: ["recording:another-item", selectedID]
        ) == selectedID
    )
    #expect(
        AppModel.selectionAfterPassiveRefresh(
            current: nil,
            availableIDs: ["recording:another-item"]
        ) == nil
    )
}

@Test
func mainWindowExpandsAnUndersizedRestoredFrame() {
    let visibleFrame = NSRect(x: 20, y: 40, width: 1_720, height: 1_080)
    let preferred = DropsiftWindowController.preferredFrame(
        in: visibleFrame
    )

    #expect(preferred.size == NSSize(width: 1_720, height: 1_050))
    #expect(preferred.midX == visibleFrame.midX)
    #expect(preferred.midY == visibleFrame.midY)
    #expect(
        DropsiftWindowController.shouldExpand(
            NSRect(x: 100, y: 100, width: 1_050, height: 700),
            to: preferred
        )
    )
    #expect(
        !DropsiftWindowController.shouldExpand(
            NSRect(x: 0, y: 0, width: 1_750, height: 1_100),
            to: preferred
        )
    )
}

@Test
func mainWindowKeepsContentBelowTheToolbar() {
    #expect(
        !DropsiftWindowController.styleMask.contains(.fullSizeContentView)
    )
}

@Test
func liveRecordingNeverShowsTwoCompetingNotesPanels() {
    #expect(
        RecordingDetailLayoutPolicy.showsSavedNotes(
            requested: true,
            isAnyRecordingActive: false
        )
    )
    #expect(
        !RecordingDetailLayoutPolicy.showsSavedNotes(
            requested: true,
            isAnyRecordingActive: true
        )
    )
}

@Test
func automaticPresentationGenerationSkipsTheExistingTimelineBaseline() {
    let existing = Set([
        "recording:existing",
        "knowledge:existing",
    ])

    #expect(
        AppModel.newPresentationSourceIDs(
            current: existing,
            previouslyKnown: nil
        ).isEmpty
    )
    #expect(
        AppModel.newPresentationSourceIDs(
            current: existing.union(["recording:new"]),
            previouslyKnown: existing
        ) == Set(["recording:new"])
    )
}

@Test
func resumedRecordingManifestKeepsOriginalTracksAndBuildsOneTimeline() throws {
    let original = RecordingManifest(
        started: "2026-07-30T08:00:00Z",
        ended: "2026-07-30T08:01:00Z",
        durationSeconds: 60,
        files: ["mic": "mic.caf", "system": "system.caf"],
        startOffsetMs: ["mic": 12, "system": 0],
        tracks: nil,
        imported: true,
        resumeCount: nil
    )

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    try original.write(to: directory)
    let inFlightSnapshot = try SessionMeta.read(from: directory)

    let resumed = original.appendingResume(
        ended: "2026-07-30T10:00:15Z",
        addedDurationSeconds: 15,
        micFile: "mic-part-2.caf",
        systemFile: "system-part-2.caf",
        micOffsetMs: 60_020,
        systemOffsetMs: 60_000
    )

    #expect(resumed.started == original.started)
    #expect(resumed.durationSeconds == 75)
    #expect(resumed.resumeCount == 1)
    #expect(resumed.imported == true)
    #expect(resumed.files == original.files)
    #expect(
        resumed.transcriptionTracks == [
            .init(file: "mic.caf", speaker: "me", offsetMs: 12),
            .init(file: "system.caf", speaker: "them", offsetMs: 0),
            .init(file: "mic-part-2.caf", speaker: "me", offsetMs: 60_020),
            .init(file: "system-part-2.caf", speaker: "them", offsetMs: 60_000),
        ]
    )

    try resumed.write(to: directory)

    let transcriptionMeta = try SessionMeta.read(from: directory)
    #expect(inFlightSnapshot.tracks.count == 2)
    #expect(inFlightSnapshot != transcriptionMeta)
    #expect(transcriptionMeta.tracks.count == 4)
    #expect(transcriptionMeta.tracks[2].offsetMs == 60_020)
    #expect(transcriptionMeta.tracks[3].speaker == "them")
}

@Test
func staleRecordingMarkerIsClearedWithoutTouchingSessionContent() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let session = root.appendingPathComponent(
        "2026.07.30-1000",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: session,
        withIntermediateDirectories: true
    )
    try Data().write(to: session.appendingPathComponent(".recording-active"))
    try Data("preserve me".utf8).write(
        to: session.appendingPathComponent("notes.md")
    )

    RecordingSession.clearStaleActiveMarkers(in: root)

    #expect(
        !FileManager.default.fileExists(
            atPath: session.appendingPathComponent(".recording-active").path
        )
    )
    #expect(
        try String(
            contentsOf: session.appendingPathComponent("notes.md"),
            encoding: .utf8
        ) == "preserve me"
    )
}

@Test
func liveAudioMeterDistinguishesSilenceFromSignal() throws {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    ))
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: 1_024
    ))
    buffer.frameLength = 1_024

    #expect(AudioLevelMeter.normalizedLevel(in: buffer) == 0)
    let samples = try #require(buffer.floatChannelData?[0])
    for index in 0..<Int(buffer.frameLength) {
        samples[index] = 0.1
    }
    #expect(AudioLevelMeter.normalizedLevel(in: buffer) > 0.5)
}

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
func transcriptRetrieverUsesAssignedSpeakerNames() {
    let recording = RecordingItem(
        id: "named-speaker",
        directory: URL(fileURLWithPath: "/tmp/named-speaker"),
        title: "Customer interview",
        startedAt: Date(),
        endedAt: Date(),
        durationSeconds: 30,
        micURL: nil,
        systemURL: nil,
        transcript: TranscriptDocument(
            engine: "test",
            model: "test",
            createdAt: "2026-07-31T10:00:00Z",
            segments: [
                .init(
                    speaker: "speaker_2",
                    startMs: 0,
                    endMs: 3_000,
                    text: "We need the final proposal tomorrow."
                ),
            ]
        ),
        notes: "",
        speakerNames: ["speaker_2": "Alice"]
    )

    let matches = TranscriptRetriever.retrieve(
        query: "What did Alice request?",
        recordings: [recording],
        scope: .all
    )

    #expect(matches.first?.text.contains("Alice: We need") == true)
}

@Test
func transcriptRetrieverIndexesRecordingNotes() {
    let recording = RecordingItem(
        id: "meeting-notes",
        directory: URL(fileURLWithPath: "/tmp/meeting-notes"),
        title: "Customer call",
        startedAt: Date(),
        endedAt: Date(),
        durationSeconds: 60,
        micURL: nil,
        systemURL: nil,
        transcript: nil,
        notes: "The customer requested a sapphire launch theme."
    )

    let matches = TranscriptRetriever.retrieve(
        query: "What launch theme did the customer request?",
        recordings: [recording],
        scope: .all
    )

    #expect(matches.count == 1)
    #expect(matches[0].text.contains("sapphire"))
    #expect(matches[0].locator == "Recording notes")
    #expect(matches[0].source(number: 1).locationLabel == "Recording notes")
}

@Test
func transcriptRetrieverBroadensWrongScopeAndFindsLatestNamedCall() {
    func recording(
        id: String,
        title: String,
        startedAt: Date,
        text: String
    ) -> RecordingItem {
        RecordingItem(
            id: id,
            directory: URL(fileURLWithPath: "/tmp/\(id)"),
            title: title,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            durationSeconds: 60,
            micURL: nil,
            systemURL: nil,
            transcript: TranscriptDocument(
                engine: "test",
                model: "test",
                createdAt: "2026-07-30T12:00:00Z",
                segments: [
                    .init(
                        speaker: "speaker_1",
                        startMs: 0,
                        endMs: 10_000,
                        text: text
                    )
                ]
            ),
            notes: ""
        )
    }

    let now = Date()
    let security = recording(
        id: "security",
        title: "This is Security AMA",
        startedAt: now.addingTimeInterval(-86_400),
        text: "We discussed dependency security and package isolation."
    )
    let firstCall = recording(
        id: "bkn-1",
        title: "BKN301 discovery call",
        startedAt: now.addingTimeInterval(-3_600),
        text: "The first discovery session covered onboarding."
    )
    let latestCall = recording(
        id: "bkn-2",
        title: "BKN 301 discovery call part 2",
        startedAt: now,
        text: "The latest session covered the knowledge base and data access."
    )
    let recordings = [security, firstCall, latestCall]
    let query = "What was the call with BKN301 about?\nThe latest one"

    let scope = TranscriptRetriever.resolvedScope(
        query: query,
        recordings: recordings,
        requestedScope: .recording(security.id)
    )
    #expect(scope == .all)

    let matches = TranscriptRetriever.retrieve(
        query: query,
        recordings: recordings,
        scope: scope
    )
    #expect(matches.first?.recordingID == latestCall.id)
    #expect(matches.first?.text.contains("knowledge base") == true)
}

@Test
func richMarkdownEditorRendersAndRoundTripsFormatting() {
    let markdown = """
    # Discovery notes

    **Bold decision** and *important context* with [source](https://example.com).

    - First action
    - [ ] Follow up
    """
    let attributed = MarkdownRichTextCodec.attributedString(from: markdown)

    #expect(attributed.string.contains("Discovery notes"))
    #expect(!attributed.string.contains("**"))
    #expect(attributed.string.contains("• First action"))
    #expect(attributed.string.contains("☐ Follow up"))

    let encoded = MarkdownRichTextCodec.markdown(from: attributed)
    #expect(encoded.contains("# Discovery notes"))
    #expect(encoded.contains("**Bold decision**"))
    #expect(encoded.contains("*important context*"))
    #expect(encoded.contains("[source](https://example.com)"))
    #expect(encoded.contains("- [ ] Follow up"))
}

@Test
func streamingResponseCleanerHidesSplitThinkingBlocks() {
    var cleaner = StreamingResponseCleaner()
    let chunks = [
        "<thi",
        "nk>private chain of thought",
        "</thi",
        "nk>\nThe grounded ",
        "answer is here.",
    ]

    let visible = chunks.map { cleaner.consume($0) }.joined() + cleaner.finish()
    #expect(visible == "\nThe grounded answer is here.")
    #expect(!visible.contains("private"))
    #expect(!visible.contains("<think>"))
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

    #expect(
        BuiltInLLMEngine.modelCacheDirectory(for: model, in: root)
            .lastPathComponent
            == "models--mlx-community--Qwen3.5-2B-4bit"
    )
    #expect(!BuiltInLLMEngine.hasCachedModel(model, in: root))
    #expect(BuiltInLLMEngine.hasPartialModel(model, in: root))

    try Data().write(to: snapshot.appendingPathComponent("model.safetensors"))

    #expect(BuiltInLLMEngine.hasCachedModel(model, in: root))
    #expect(!BuiltInLLMEngine.hasPartialModel(model, in: root))
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
func qwenFourBillionModelSupportsFullContextOnThisMac() throws {
    let model = try #require(
        AIModelCatalog.models.first { $0.name == "Qwen3.5 4B" }
    )
    #expect(model.nativeContextTokens == 262_144)
    let plan = AIModelCatalog.plan(for: model, device: .current)
    #expect(plan.contextTokens == 262_144)
    #expect(plan.estimatedModelMemoryBytes <= plan.memoryBudgetBytes)
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
    let untitledRecording = try #require(RecordingItem.load(from: root))
    try RecordingLibrary.saveTitle("My meeting", for: untitledRecording)
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
        titleIsManual: true,
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
    #expect(loaded[0].titleIsManual)
    #expect(loaded[0].scope.recordingID == "meeting-1")
    #expect(loaded[0].messages.count == 2)
    #expect(loaded[0].messages[1].sources.first?.startMs == 4_000)
}

@Test
func legacyChatThreadsDecodeWithAutomaticTitles() throws {
    let id = UUID()
    let timestamp = "2026-08-19T10:00:00Z"
    let json = """
    {
      "id": "\(id.uuidString)",
      "title": "Existing conversation",
      "createdAt": "\(timestamp)",
      "updatedAt": "\(timestamp)",
      "scope": { "kind": "allRecordings" },
      "messages": []
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let thread = try decoder.decode(ChatThread.self, from: Data(json.utf8))

    #expect(!thread.titleIsManual)
}

@Test
@MainActor
func conversationTitleChangesPersistImmediately() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let recordings = base.appendingPathComponent("Recordings", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(
        at: recordings,
        withIntermediateDirectories: true
    )

    let model = AppModel(root: recordings)
    model.createThread()
    let threadID = try #require(model.selectedThreadID)
    model.renameThread(threadID, to: "Malta tax follow-up")

    let saved = ChatStore(
        directory: base.appendingPathComponent("Threads", isDirectory: true)
    ).load()
    let thread = try #require(saved.first(where: { $0.id == threadID }))
    #expect(thread.title == "Malta tax follow-up")
    #expect(thread.titleIsManual)
}

@Test
func knowledgeLibraryPersistsNotesAndRetrievesTheirContents() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let created = try KnowledgeLibrary.createNote(in: root)
    try KnowledgeLibrary.saveTitle("Launch notes", for: created)
    try KnowledgeLibrary.saveContent(
        "# Launch\n\nThe Barcelona release is scheduled for Friday.",
        for: created
    )

    let loaded = try #require(KnowledgeLibrary.load(from: root).first)
    #expect(loaded.title == "Launch notes")
    #expect(loaded.content.contains("Barcelona"))

    let matches = KnowledgeRetriever.retrieve(
        query: "When is the Barcelona release?",
        items: [loaded]
    )
    #expect(matches.count == 1)
    #expect(matches[0].text.contains("Friday"))
    #expect(matches[0].locator == "Note")
}

@Test
func desktopKnowledgeTitlesFollowContentUntilManuallyRenamed() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let created = try KnowledgeLibrary.createNote(in: root)
    try KnowledgeLibrary.saveContent(
        "# September launch review\n\nCheck the offline search results.",
        for: created
    )
    let generated = try #require(KnowledgeLibrary.load(from: root).first)
    #expect(generated.title == "September launch review")

    try KnowledgeLibrary.saveTitle("Marco’s launch notes", for: generated)
    try KnowledgeLibrary.saveContent(
        "# A later heading must not win",
        for: generated
    )
    #expect(KnowledgeLibrary.load(from: root).first?.title == "Marco’s launch notes")
}

@Test
func documentImportCopiesAndExtractsPlainText() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let source = base.appendingPathComponent("Strategy.md")
    let items = base.appendingPathComponent("Items", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: items, withIntermediateDirectories: true)
    try Data("Project Kestrel targets the education market.".utf8).write(to: source)

    let imported = try KnowledgeLibrary.importFile(
        source,
        as: .document,
        into: items
    )

    #expect(imported.title == "Project Kestrel targets the education market")
    #expect(imported.assetURL != nil)
    #expect(imported.extractedText.contains("Kestrel"))
    #expect(imported.blocks.first?.locator == "Document")
}

@Test
func desktopRecordingNotesGenerateATitleButManualTitlesWin() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("2026.07.29-1130", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(#"{"duration_seconds": 30}"#.utf8).write(
        to: root.appendingPathComponent("meta.json")
    )

    try RecordingLibrary.saveNotes(
        "- Review the multilingual onboarding flow",
        to: root
    )
    let generated = try #require(RecordingItem.load(from: root))
    #expect(generated.title == "Review the multilingual onboarding flow")

    try RecordingLibrary.saveTitle("Design sync", for: generated)
    try RecordingLibrary.saveNotes("- A later note should not rename this", to: root)
    #expect(RecordingItem.load(from: root)?.title == "Design sync")
}

@Test
func passiveRecordingLibraryRefreshDoesNotRegenerateTitles() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let directory = root.appendingPathComponent(
        "2026.08.19-1300",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    try Data(#"{"duration_seconds": 30}"#.utf8).write(
        to: directory.appendingPathComponent("meta.json")
    )
    try Data("Existing generated title".utf8).write(
        to: directory.appendingPathComponent("title.txt")
    )
    try Data("A completely different note".utf8).write(
        to: directory.appendingPathComponent("notes.md")
    )
    try ContentTitleGenerator.markGenerated(in: directory)

    let recordings = RecordingLibrary.load(
        from: root,
        refreshGeneratedTitles: false
    )

    #expect(recordings.first?.title == "Existing generated title")
    let storedTitle = try String(
        contentsOf: directory.appendingPathComponent("title.txt"),
        encoding: .utf8
    )
    #expect(storedTitle == "Existing generated title")
}

@Test
func qvacLongAudioIsSplitIntoBoundedTranscriptionParts() throws {
    let chunks = QVACAudioChunkPlan.make(
        duration: 2 * 60 + 17,
        maximumDuration: QVACTranscriptionEngine.chunkDuration
    )

    #expect(chunks.count == 3)
    #expect(chunks[0] == .init(index: 0, start: 0, duration: 60))
    #expect(chunks[1] == .init(index: 1, start: 60, duration: 60))
    #expect(chunks[2] == .init(index: 2, start: 120, duration: 17))
}

@Test
func qvacTranscriptionUsesParakeetTDT() {
    let engine = QVACTranscriptionEngine()

    #expect(engine.name == "qvac-parakeet")
    #expect(engine.model == "parakeet-tdt-0.6b-v3-q8_0-metal")
}

@Test
func qvacAudioNormalizationProducesRaw16KMonoPCM16() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let source = root.appendingPathComponent("source.caf")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    let format = try #require(AVAudioFormat(
        standardFormatWithSampleRate: 48_000,
        channels: 2
    ))
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: 96_000
    ))
    buffer.frameLength = 96_000
    for channel in 0..<2 {
        let samples = try #require(buffer.floatChannelData?[channel])
        for frame in 0..<96_000 {
            samples[frame] = sin(Float(frame) * 0.03) * 0.1
        }
    }
    let file = try AVAudioFile(forWriting: source, settings: format.settings)
    try file.write(from: buffer)

    let raw = try await QVACAudioConverter.convertToPCM(
        source,
        range: .init(index: 0, start: 0, duration: 2)
    )
    defer { try? FileManager.default.removeItem(at: raw) }
    let size = try #require(
        FileManager.default.attributesOfItem(atPath: raw.path)[.size] as? NSNumber
    ).intValue
    let expectedSize = 2 * 16_000 * MemoryLayout<Int16>.size

    #expect(raw.pathExtension == "raw")
    #expect(abs(size - expectedSize) <= 256)
}

@Test
func activeRecordingTitleCanBeSavedBeforeTheManifestExists() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )

    try RecordingLibrary.saveTitle(
        "Fineco integration review",
        to: directory
    )
    try RecordingLibrary.saveNotes(
        "A later note must not replace the live title",
        to: directory
    )

    let storedTitle = try String(
        contentsOf: directory.appendingPathComponent("title.txt"),
        encoding: .utf8
    )
    #expect(storedTitle == "Fineco integration review")
    #expect(
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(
                ContentTitleGenerator.manualMarkerFilename
            ).path
        )
    )
}

@Test
func recordingTranscriptCanBeSplitIntoASecondTimelineItem() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let directory = root.appendingPathComponent(
        "2026.08.10-1500",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let manifest = RecordingManifest(
        started: "2026-08-10T13:00:00Z",
        ended: "2026-08-10T13:00:20Z",
        durationSeconds: 20,
        files: [:],
        startOffsetMs: [:],
        tracks: [],
        imported: nil,
        resumeCount: nil
    )
    try manifest.write(to: directory)
    let transcript = TranscriptDocument(
        engine: "test",
        model: "test",
        createdAt: "2026-08-10T13:01:00Z",
        segments: [
            .init(
                speaker: "speaker_1",
                startMs: 0,
                endMs: 5_000,
                text: "Fineco integration planning."
            ),
            .init(
                speaker: "speaker_2",
                startMs: 5_000,
                endMs: 9_000,
                text: "We should prepare the data model."
            ),
            .init(
                speaker: "speaker_3",
                startMs: 10_000,
                endMs: 14_000,
                text: "This is a different conversation."
            ),
            .init(
                speaker: "me",
                startMs: 15_000,
                endMs: 19_000,
                text: "Let’s discuss it separately."
            ),
        ]
    )
    try transcript.write(to: directory, title: "Meeting")
    try ContentTitleGenerator.markGenerated(in: directory)
    let recording = try #require(RecordingItem.load(from: directory))

    let newItem = try await RecordingLibrary.splitTranscript(
        recording,
        at: 10_000
    )
    let updatedOriginal = try #require(RecordingItem.load(from: directory))

    #expect(updatedOriginal.transcript?.segments.count == 2)
    #expect(updatedOriginal.durationSeconds == 10)
    #expect(newItem.transcript?.segments.count == 2)
    #expect(newItem.transcript?.segments.first?.startMs == 0)
    #expect(newItem.transcript?.segments.first?.speaker == "speaker_3")
    #expect(newItem.durationSeconds == 10)
}

@Test
func recordingSplitClipsAudioAndKeepsTheUntouchedSource() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let directory = root.appendingPathComponent(
        "2026.08.10-1600",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let sourceAudio = directory.appendingPathComponent("system.caf")
    let format = try #require(
        AVAudioFormat(
            standardFormatWithSampleRate: 16_000,
            channels: 1
        )
    )
    let buffer = try #require(
        AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 64_000
        )
    )
    buffer.frameLength = 64_000
    let samples = try #require(buffer.floatChannelData?[0])
    for frame in 0 ..< 64_000 {
        samples[frame] = sin(Float(frame) * 0.03) * 0.1
    }
    let file = try AVAudioFile(
        forWriting: sourceAudio,
        settings: format.settings
    )
    try file.write(from: buffer)

    try RecordingManifest(
        started: "2026-08-10T14:00:00Z",
        ended: "2026-08-10T14:00:04Z",
        durationSeconds: 4,
        files: ["system": "system.caf"],
        startOffsetMs: ["system": 0],
        tracks: nil,
        imported: nil,
        resumeCount: nil
    ).write(to: directory)
    let transcript = TranscriptDocument(
        engine: "test",
        model: "test",
        createdAt: "2026-08-10T14:01:00Z",
        segments: [
            .init(
                speaker: "speaker_1",
                startMs: 0,
                endMs: 1_900,
                text: "First conversation."
            ),
            .init(
                speaker: "speaker_2",
                startMs: 2_000,
                endMs: 3_900,
                text: "Second conversation."
            ),
        ]
    )
    try transcript.write(to: directory, title: "Meeting")
    try ContentTitleGenerator.markGenerated(in: directory)
    let recording = try #require(RecordingItem.load(from: directory))

    let newItem = try await RecordingLibrary.splitTranscript(
        recording,
        at: 2_000
    )
    let updatedOriginal = try #require(RecordingItem.load(from: directory))
    let headAudio = try #require(updatedOriginal.systemURL)
    let tailAudio = try #require(newItem.systemURL)
    let headDuration = try await AVURLAsset(url: headAudio).load(.duration)
    let tailDuration = try await AVURLAsset(url: tailAudio).load(.duration)

    #expect(FileManager.default.fileExists(atPath: sourceAudio.path))
    #expect(headAudio.lastPathComponent != sourceAudio.lastPathComponent)
    #expect(CMTimeGetSeconds(headDuration) > 1.8)
    #expect(CMTimeGetSeconds(tailDuration) > 1.8)
}

@Test
func chatSourceStillDecodesLegacyTranscriptSources() throws {
    let json = """
    {
      "number": 1,
      "recordingID": "meeting-1",
      "recordingTitle": "Planning",
      "startMs": 5000,
      "endMs": 9000,
      "excerpt": "Ship Friday."
    }
    """
    let source = try JSONDecoder().decode(ChatSource.self, from: Data(json.utf8))
    #expect(source.knowledgeItemID == nil)
    #expect(source.locationLabel == "0:05")
}

@Test
@MainActor
func desktopBatchActionsUpdateAllSelectedTasksAndEntities() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let recordings = base.appendingPathComponent("Recordings", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(
        at: recordings,
        withIntermediateDirectories: true
    )

    let model = AppModel(root: recordings)
    model.createTask()
    model.createTask()
    let taskIDs = Set(model.tasks.map(\.id))
    #expect(taskIDs.count == 2)

    model.setTaskCompletion(taskIDs, completed: true)
    #expect(!model.tasks.contains { !$0.isCompleted })

    model.deleteTasks(taskIDs)
    #expect(model.tasks.isEmpty)

    model.createEntity(kind: .person)
    model.createEntity(kind: .person)
    let entityIDs = Set(model.entities(of: .person).map(\.id))
    #expect(entityIDs.count == 2)

    model.deleteEntities(entityIDs)
    #expect(model.entities(of: .person).isEmpty)
}

@Test
func desktopShiftSelectionIncludesTheEntireContiguousRange() {
    let ordered = ["a", "b", "c", "d", "e"]

    #expect(
        DesktopMultiSelection.range(
            from: "b",
            through: "e",
            in: ordered
        ) == ["b", "c", "d", "e"]
    )
    #expect(
        DesktopMultiSelection.range(
            from: "d",
            through: "b",
            in: ordered
        ) == ["b", "c", "d"]
    )
    #expect(
        DesktopMultiSelection.range(
            from: nil,
            through: "c",
            in: ordered
        ) == ["c"]
    )
}

@Test
func everyCompletedTranscriptionQueuesTheLatestRecordingSummary() {
    #expect(
        AppModel.summaryQueueAfterTranscription(
            ["recording:earlier"],
            recordingID: "meeting"
        ) == ["recording:earlier", "recording:meeting"]
    )
    #expect(
        AppModel.summaryQueueAfterTranscription(
            ["recording:meeting"],
            recordingID: "meeting"
        ) == ["recording:meeting"]
    )
}
