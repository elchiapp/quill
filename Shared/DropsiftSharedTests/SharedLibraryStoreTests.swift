import Foundation
import Testing
@testable import DropsiftShared

@Test
func generatedTitlesPreferSpecificTopicsOverOpeningFiller() {
    let title = ContentTitleGenerator.title(
        from: [
            """
            Tutto bene.
            It might be helpful just to get a bit of context first.
            BKN301 and Fineco need a shared integration data model.
            """,
        ],
        fallback: "Meeting · Aug 10"
    )

    #expect(title == "BKN301 and Fineco need a shared integration data model")
}

@Test
func localModelPresentationParsesAndCleansStructuredMetadata() throws {
    let presentation = try #require(
        ContentPresentationGenerator.parse(
            """
            ```json
            {"title":"Title: Fineco and BKN301 Integration.","description":"  The teams mapped the integration data model. They also agreed on the next technical validation.  "}
            ```
            """,
            sourceRevision: "abc123",
            model: "Qwen3.5 4B"
        )
    )

    #expect(presentation.title == "Fineco and BKN301 Integration")
    #expect(
        presentation.description
            == "The teams mapped the integration data model. They also agreed on the next technical validation."
    )
    #expect(presentation.sourceRevision == "abc123")
    #expect(presentation.model == "Qwen3.5 4B")
}

@Test
func localModelPresentationRecoversFromProseAndAnInvalidBraceBlock() throws {
    let presentation = try #require(
        ContentPresentationGenerator.parse(
            """
            Here's my analysis: {not valid JSON}.
            Title: Fineco Integration Architecture
            Description: The teams reviewed the BKN301 integration architecture and agreed on the validation sequence.
            """,
            sourceRevision: "recovered",
            model: "Qwen3.5 4B"
        )
    )

    #expect(presentation.title == "Fineco Integration Architecture")
    #expect(presentation.description.contains("BKN301 integration architecture"))
}

@Test
func localModelPresentationRejectsCopiedPromptPlaceholders() throws {
    let response = """
    {"title":"specific title","description":"one or two concise sentences"}
    """

    #expect(
        ContentPresentationGenerator.parse(
            response,
            sourceRevision: "placeholder",
            model: "Qwen3.5 4B"
        ) == nil
    )

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    try ContentPresentationStore.save(
        ContentPresentation(
            title: "specific title",
            description: "one or two concise sentences",
            sourceRevision: "placeholder",
            model: "Qwen3.5 4B"
        ),
        to: root
    )

    #expect(ContentPresentationStore.load(from: root) == nil)
    #expect(
        !ContentPresentationStore.isCurrent(
            in: root,
            revision: "placeholder"
        )
    )
}

@Test
func recordingSummaryParsesAndPersistsMeetingStructure() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    let summary = try #require(
        RecordingSummaryGenerator.parse(
            """
            {
              "overview": "Fineco and BKN301 reviewed the integration data model and agreed on a validation workshop.",
              "participants": ["Davide", "Dario"],
              "topics": ["Integration data model", "Validation plan"],
              "decisions": ["Use the shared asset schema"],
              "action_items": ["Davide will schedule the validation workshop"]
            }
            """,
            detectedSpeakers: ["Davide", "Dario"],
            sourceRevision: "summary-revision",
            model: "Qwen3.5 4B"
        )
    )
    try RecordingSummaryStore.save(summary, to: root)

    let loaded = try #require(RecordingSummaryStore.load(from: root))
    #expect(loaded.participantCount == 2)
    #expect(loaded.topics == ["Integration data model", "Validation plan"])
    #expect(loaded.actionItems == [
        "Davide will schedule the validation workshop",
    ])
    #expect(
        RecordingSummaryStore.isCurrent(
            in: root,
            revision: "summary-revision"
        )
    )
}

@Test
func sharedTimelinePrefersSyncedDescriptionAndPreservesAITitle() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SharedLibraryStore(root: root)
    let content = "Discuss the Fineco and BKN301 integration data model."
    let note = try store.createNote(content: content)
    let sourceText = [content, ""].joined(separator: "\n\n")
    let presentation = ContentPresentation(
        title: "Fineco and BKN301 Integration",
        description: "A working session about the shared integration model and its next validation steps.",
        sourceRevision: ContentPresentationStore.revision(for: sourceText),
        model: "Qwen3.5 4B"
    )

    var metadata = note.metadata
    metadata.title = presentation.title
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(metadata).write(
        to: note.directory.appendingPathComponent("item.json"),
        options: .atomic
    )
    try ContentTitleGenerator.markGenerated(in: note.directory)
    try ContentPresentationStore.save(presentation, to: note.directory)

    let loaded = try #require(store.loadKnowledgeItems().first)
    let timeline = SharedTimelineItem.knowledge(loaded)
    #expect(loaded.title == "Fineco and BKN301 Integration")
    #expect(timeline.listDescription == presentation.description)

    try store.updateKnowledge(id: note.id, content: "The scope changed.")
    let updated = try #require(store.loadKnowledgeItems().first)
    #expect(updated.generatedDescription.isEmpty)
    #expect(updated.listDescription == updated.preview)
}

@Test
func sharedKnowledgeLoadsItsPortableSummary() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SharedLibraryStore(root: root)
    let note = try store.createNote(
        title: "Launch brief",
        content: "The launch brief covers positioning, timing, and ownership."
    )
    let summary = RecordingSummary(
        overview: "A concise launch brief covering the release position and plan.",
        participantCount: 0,
        participants: [],
        topics: ["Positioning", "Launch timing"],
        decisions: [],
        actionItems: [],
        sourceRevision: "knowledge-summary-revision",
        model: "Qwen3.5 4B"
    )
    try RecordingSummaryStore.save(summary, to: note.directory)

    let loaded = try #require(store.loadKnowledgeItems().first)
    #expect(loaded.summary?.overview == summary.overview)
    #expect(loaded.summary?.topics == summary.topics)

    try store.updateKnowledge(
        id: note.id,
        content: "The launch plan changed after the summary was generated."
    )
    #expect(store.loadKnowledgeItems().first?.summary == nil)
}

@Test
func sharedLibraryRoundTripsNoteAndSearchesIt() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SharedLibraryStore(root: root)

    let note = try store.createNote(
        title: "Watch launch",
        content: "The cobalt prototype ships on Friday."
    )
    let loaded = store.loadSnapshot()
    let results = store.search("When does the cobalt prototype ship?")

    #expect(loaded.knowledgeItems.first?.id == note.id)
    #expect(results.first?.text.contains("Friday") == true)
    #expect(results.first?.itemID == "knowledge:\(note.id.uuidString)")
}

@Test
func sharedLibraryGeneratesTitlesAndPreservesManualRenames() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SharedLibraryStore(root: root)

    let note = try store.createNote(
        content: "# Piano editor launch\n\nShip the multilingual editor in September."
    )
    #expect(note.title == "Piano editor launch")

    try store.updateKnowledge(
        id: note.id,
        content: "# Revised launch plan\n\nMove the release to October."
    )
    #expect(store.loadKnowledgeItems().first?.title == "Revised launch plan")

    try store.updateKnowledge(id: note.id, title: "My permanent title")
    try store.updateKnowledge(
        id: note.id,
        content: "# This must not replace my title"
    )
    #expect(store.loadKnowledgeItems().first?.title == "My permanent title")
}

@Test
func sharedLibraryImportsMobileVoiceInDesktopSchema() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let root = base.appendingPathComponent("Library", isDirectory: true)
    let source = base.appendingPathComponent("message.m4a")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try Data([0, 1, 2, 3]).write(to: source)
    let store = SharedLibraryStore(root: root)

    let recording = try store.importVoiceRecording(
        source: source,
        startedAt: Date(timeIntervalSince1970: 1_785_000_000),
        durationSeconds: 12,
        title: "Watch voice message",
        origin: "apple-watch"
    )

    let metadataData = try Data(
        contentsOf: recording.directory.appendingPathComponent("meta.json")
    )
    let metadata = try JSONDecoder().decode(
        SharedRecordingMetadata.self,
        from: metadataData
    )
    #expect(metadata.files?["mic"] == "mic.m4a")
    #expect(metadata.tracks == [
        .init(file: "mic.m4a", speaker: "me", offsetMs: 0),
    ])
    #expect(metadata.origin == "apple-watch")
    #expect(recording.durationSeconds == 12)
}

@Test
func sharedLibraryPersistsSpeakerNamesAndUsesThemInSearch() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let root = base.appendingPathComponent("Library", isDirectory: true)
    let source = base.appendingPathComponent("meeting.m4a")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try Data([0, 1]).write(to: source)
    let store = SharedLibraryStore(root: root)
    let recording = try store.importVoiceRecording(
        source: source,
        startedAt: Date(timeIntervalSince1970: 1_785_000_000),
        durationSeconds: 10,
        title: "Planning call",
        origin: "iphone"
    )
    try store.saveTranscript(
        SharedTranscriptDocument(
            engine: "test",
            model: "test",
            createdAt: "2026-07-31T10:00:00Z",
            segments: [
                .init(
                    speaker: "speaker_1",
                    startMs: 0,
                    endMs: 2_000,
                    text: "The launch is on Friday."
                ),
            ]
        ),
        recordingID: recording.id
    )

    try store.updateSpeakerNames(
        ["speaker_1": "  Alice Chen  ", "them": ""],
        recordingID: recording.id
    )

    let loaded = try #require(
        store.loadRecordings().first(where: { $0.id == recording.id })
    )
    #expect(loaded.speakerNames == ["speaker_1": "Alice Chen"])
    #expect(loaded.speakerName(for: "speaker_1") == "Alice Chen")
    #expect(loaded.speakerName(for: "me") == "You")
    let result = try #require(store.search("What did Alice say?").first)
    #expect(result.text == "Alice Chen: The launch is on Friday.")
    let markdown = try String(
        contentsOf: recording.directory.appendingPathComponent("transcript.md"),
        encoding: .utf8
    )
    #expect(markdown.contains("Alice Chen:"))
}

@Test
func sharedLibraryAppendsMobileVoiceToExistingRecording() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let root = base.appendingPathComponent("Library", isDirectory: true)
    let original = base.appendingPathComponent("original.m4a")
    let resumed = base.appendingPathComponent("resumed.m4a")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(
        at: base,
        withIntermediateDirectories: true
    )
    try Data([0, 1, 2, 3]).write(to: original)
    try Data([4, 5, 6, 7]).write(to: resumed)
    let store = SharedLibraryStore(root: root)

    let recording = try store.importVoiceRecording(
        source: original,
        startedAt: Date(timeIntervalSince1970: 1_785_000_000),
        durationSeconds: 12,
        title: "Interview",
        origin: "iphone"
    )
    let updated = try store.appendVoiceRecording(
        source: resumed,
        recordingID: recording.id,
        durationSeconds: 8
    )

    let metadata = try JSONDecoder().decode(
        SharedRecordingMetadata.self,
        from: Data(
            contentsOf: recording.directory.appendingPathComponent("meta.json")
        )
    )
    #expect(metadata.durationSeconds == 20)
    #expect(metadata.resumeCount == 1)
    #expect(metadata.tracks?.count == 2)
    #expect(metadata.tracks?.last?.speaker == "me")
    #expect(metadata.tracks?.last?.offsetMs == 12_000)
    #expect(updated.audioTracks.count == 2)
    #expect(
        FileManager.default.fileExists(
            atPath: recording.directory
                .appendingPathComponent(".transcription-pending").path
        )
    )
}

@Test
func sharedLibraryMergesTranscriptFromResumedMobileVoice() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let root = base.appendingPathComponent("Library", isDirectory: true)
    let original = base.appendingPathComponent("original.m4a")
    let resumed = base.appendingPathComponent("resumed.m4a")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(
        at: base,
        withIntermediateDirectories: true
    )
    try Data([0]).write(to: original)
    try Data([1]).write(to: resumed)
    let store = SharedLibraryStore(root: root)
    let recording = try store.importVoiceRecording(
        source: original,
        startedAt: Date(timeIntervalSince1970: 1_785_000_000),
        durationSeconds: 12,
        title: "Interview",
        origin: "iphone"
    )
    try store.saveTranscript(
        SharedTranscriptDocument(
            engine: "test",
            model: "original",
            createdAt: "2026-07-30T10:00:00Z",
            segments: [
                .init(
                    speaker: "me",
                    startMs: 1_000,
                    endMs: 2_000,
                    text: "Original"
                ),
            ]
        ),
        recordingID: recording.id
    )
    _ = try store.appendVoiceRecording(
        source: resumed,
        recordingID: recording.id,
        durationSeconds: 8
    )

    try store.appendTranscript(
        SharedTranscriptDocument(
            engine: "test",
            model: "resumed",
            createdAt: "2026-07-30T10:01:00Z",
            segments: [
                .init(
                    speaker: "me",
                    startMs: 500,
                    endMs: 1_500,
                    text: "Resumed"
                ),
            ]
        ),
        offsetMs: 12_000,
        recordingID: recording.id
    )

    let loaded = try #require(
        store.loadRecordings().first(where: { $0.id == recording.id })
    )
    #expect(loaded.transcript?.segments.map(\.text) == ["Original", "Resumed"])
    #expect(loaded.transcript?.segments.last?.startMs == 12_500)
    #expect(
        !FileManager.default.fileExists(
            atPath: recording.directory
                .appendingPathComponent(".transcription-pending").path
        )
    )
}

@Test
func sharedRecordingUsesNotesThenTranscriptForItsGeneratedTitle() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let root = base.appendingPathComponent("Library", isDirectory: true)
    let source = base.appendingPathComponent("message.m4a")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try Data([0, 1, 2, 3]).write(to: source)
    let store = SharedLibraryStore(root: root)
    let recording = try store.importVoiceRecording(
        source: source,
        startedAt: Date(timeIntervalSince1970: 1_785_000_000),
        durationSeconds: 12,
        title: "Voice message",
        origin: "iphone"
    )
    let transcript = SharedTranscriptDocument(
        engine: "test",
        model: "test",
        createdAt: "2026-07-29T10:00:00Z",
        segments: [
            .init(speaker: "me", startMs: 0, endMs: 500, text: "Yeah"),
            .init(
                speaker: "me",
                startMs: 500,
                endMs: 4_000,
                text: "Plan the multilingual launch for September."
            ),
        ]
    )

    try store.saveTranscript(transcript, recordingID: recording.id)
    #expect(
        store.loadRecordings().first?.title
            == "Plan the multilingual launch for September"
    )

    try store.updateRecordingNotes(
        "- Customer interview about offline search",
        recordingID: recording.id
    )
    #expect(
        store.loadRecordings().first?.title
            == "Customer interview about offline search"
    )
}

@Test
func sharedSearchPreservesDeepLinkLocations() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let source = base.appendingPathComponent("brief.pdf")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try Data("placeholder".utf8).write(to: source)
    let store = SharedLibraryStore(root: base.appendingPathComponent("Library"))

    _ = try store.importKnowledge(
        source: source,
        kind: .document,
        blocks: [
            SharedKnowledgeBlock(
                text: "The cobalt launch is scheduled for Friday.",
                page: 7,
                locator: "Page 7"
            ),
        ]
    )

    let result = try #require(store.search("cobalt launch").first)
    #expect(result.page == 7)
    #expect(result.locator == "Page 7")
}
