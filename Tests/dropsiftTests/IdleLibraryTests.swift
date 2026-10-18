import DropsiftShared
import Foundation
import Testing
@testable import dropsift

@Test
func transcriptCacheReusesUnchangedFilesAndDetectsAtomicReplacement() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transcript.json")
    let cache = TranscriptFileCache()
    var reads = 0
    func read(_ url: URL) -> TranscriptDocument? {
        reads += 1
        return try? JSONDecoder().decode(TranscriptDocument.self, from: Data(contentsOf: url))
    }
    func document(_ text: String) -> TranscriptDocument {
        TranscriptDocument(engine: "test", model: "test", createdAt: "", segments: [
            .init(speaker: "me", startMs: 0, endMs: 1000, text: text),
        ])
    }
    try JSONEncoder().encode(document("first")).write(to: url, options: .atomic)
    let originalDate = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
    #expect(cache.load(from: url, read: read)?.segments.first?.text == "first")
    #expect(cache.load(from: url, read: read)?.segments.first?.text == "first")
    #expect(reads == 1)

    // An iCloud atomic replacement may preserve timestamp and byte count.
    try JSONEncoder().encode(document("later")).write(to: url, options: .atomic)
    if let originalDate {
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: url.path)
    }
    #expect(cache.load(from: url, read: read)?.segments.first?.text == "later")
    #expect(reads == 2)
    try FileManager.default.removeItem(at: url)
    #expect(cache.load(from: url, read: read) == nil)
}

@Test
func librarySnapshotsOnlyPublishChangedItems() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let recordings = root.appendingPathComponent("Recordings")
    let items = root.appendingPathComponent("Items")
    try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: items, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try KnowledgeLibrary.createNote(in: items)
    let second = try KnowledgeLibrary.createNote(in: items)
    let loader = LibrarySnapshotLoader(
        root: recordings, knowledgeRoot: items, recordings: [], knowledge: [first, second]
    )
    let idle = await loader.load(refreshGeneratedTitles: false)
    #expect(!idle.changed)
    try Data("Synced mobile note".utf8).write(
        to: first.directory.appendingPathComponent("content.md"), options: .atomic
    )
    let changed = await loader.load(refreshGeneratedTitles: false)
    #expect(changed.changed)
    #expect(changed.knowledgeItems.first { $0.id == first.id }?.content == "Synced mobile note")
    #expect(changed.knowledgeItems.first { $0.id == second.id }?.content == second.content)
    let unchanged = await loader.load(refreshGeneratedTitles: false)
    #expect(!unchanged.changed)
    try FileManager.default.removeItem(at: second.directory)
    let deleted = await loader.load(refreshGeneratedTitles: false)
    #expect(deleted.changed)
    #expect(deleted.knowledgeItems.map(\.id) == [first.id])
}

@Test
func libraryEventsIgnoreContinuousAudioAndTranscriptionLogs() {
    let recordings = URL(fileURLWithPath: "/tmp/library/Recordings")
    let items = URL(fileURLWithPath: "/tmp/library/Items")
    func classify(_ path: String) -> LibraryChanges {
        LibraryChanges.classify(path: path, recordingRoot: recordings, knowledgeRoot: items)
    }
    #expect(classify("/tmp/library/Recordings/call/mic.caf").isEmpty)
    #expect(classify("/tmp/library/Recordings/call/transcribe.log").isEmpty)
    #expect(classify("/tmp/library/Threads/threads.json").isEmpty)
    #expect(classify("/tmp/library/Recordings/call/transcript.json").pendingTranscription)
    #expect(classify("/tmp/library/Recordings/call/.transcript.json.icloud").content)
    #expect(classify("/tmp/library/Items/item/content.md").content)
    #expect(classify("/tmp/library/Semantics/Tasks/task.json").semantics)
    let arrivingAudio = LibraryChanges.classify(
        path: "/tmp/library/Recordings/call/mic.m4a",
        recordingRoot: recordings, knowledgeRoot: items, fileArrived: true
    )
    #expect(arrivingAudio.pendingTranscription)
}

@Test @MainActor
func libraryMonitorDeliversFileChangesAndDoesNoIdleRefresh() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let recordings = root.appendingPathComponent("Recordings")
    let items = root.appendingPathComponent("Items")
    let call = recordings.appendingPathComponent("call")
    try FileManager.default.createDirectory(at: call, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: items, withIntermediateDirectories: true)
    try Data().write(to: call.appendingPathComponent("mic.caf"))
    defer { try? FileManager.default.removeItem(at: root) }
    var deliveries: [LibraryChanges] = []
    let monitor = LibraryChangeMonitor(recordingRoot: recordings, knowledgeRoot: items) {
        deliveries.append($0)
    }
    monitor.start()
    defer { monitor.stop() }
    try Data("Synced notes".utf8).write(to: call.appendingPathComponent("notes.md"), options: .atomic)
    for _ in 0..<80 {
        if deliveries.contains(where: { $0.content }) { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(deliveries.contains(where: { $0.content }))
    try await Task.sleep(for: .seconds(1))
    deliveries.removeAll()
    // Longer than the former eight-second timer. No writes means no refreshes.
    try await Task.sleep(for: .seconds(9))
    #expect(deliveries.isEmpty)
    // Match the recorder's open-file append. Data.write can replace the file,
    // which is correctly treated as newly arrived audio rather than a tick.
    let audio = try FileHandle(forWritingTo: call.appendingPathComponent("mic.caf"))
    try audio.seekToEnd()
    try audio.write(contentsOf: Data(repeating: 0, count: 4096))
    try audio.close()
    try await Task.sleep(for: .seconds(1))
    #expect(deliveries.isEmpty)
    try Data(repeating: 1, count: 2048).write(to: call.appendingPathComponent("new.wav"))
    for _ in 0..<80 {
        if deliveries.contains(where: { $0.pendingTranscription }) { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(deliveries.contains(where: { $0.pendingTranscription }))
}

@Test
func meetingDetectionHasNoScheduledWorkWithoutAStateTransition() {
    var tracker = MeetingDetectionTracker()
    let now = Date(timeIntervalSince1970: 1000)
    let meeting = DetectedMeeting(bundleID: "us.zoom.xos", appName: "Zoom", isBrowser: false)
    #expect(tracker.nextCheckDate == nil)
    #expect(tracker.update(current: nil, now: now) == nil)
    #expect(tracker.nextCheckDate == nil)
    #expect(tracker.update(current: meeting, now: now) == nil)
    #expect(tracker.nextCheckDate == now.addingTimeInterval(4))
    #expect(tracker.update(current: meeting, now: now.addingTimeInterval(4)) == .detected(meeting))
    #expect(tracker.nextCheckDate == nil)
    #expect(tracker.update(current: nil, now: now.addingTimeInterval(5)) == nil)
    #expect(tracker.nextCheckDate == now.addingTimeInterval(15))
    #expect(tracker.update(current: nil, now: now.addingTimeInterval(15)) == .ended(meeting))
    #expect(tracker.nextCheckDate == nil)
}
