import Foundation
import Testing
@testable import DropsiftShared

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
    #expect(metadata.origin == "apple-watch")
    #expect(recording.durationSeconds == 12)
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
