import AVFoundation
import Combine
import DropsiftShared
import Foundation

@MainActor
final class MobileAppModel: ObservableObject {
    @Published var selectedTab: MobileTab = .capture
    @Published private(set) var snapshot = SharedLibrarySnapshot(
        knowledgeItems: [],
        recordings: []
    )
    @Published var selectedKinds = Set(SharedTimelineKind.allCases)
    @Published var timelineSearch = ""
    @Published var selectedTimelineItemID: String?
    @Published private(set) var selectedSource: SharedSearchResult?
    @Published var importState: MobileImportState = .idle
    @Published var errorMessage: String?
    @Published var chatDraft = ""
    @Published private(set) var chatMessages: [MobileChatMessage] = []
    @Published private(set) var isAnswering = false

    let locator = MobileLibraryLocator()
    let recorder = VoiceRecorder()
    let watchBridge = PhoneWatchBridge()

    private var cancellables: Set<AnyCancellable> = []
    private var refreshTask: Task<Void, Never>?
    private var processingWatchInbox = false

    init() {
        locator.$rootURL
            .dropFirst()
            .sink { [weak self] _ in
                self?.reload()
                self?.processWatchInbox()
            }
            .store(in: &cancellables)
        watchBridge.onInboxChanged = { [weak self] in
            self?.processWatchInbox()
        }
        reload()
        processWatchInbox()
    }

    var timeline: [SharedTimelineItem] {
        snapshot.timeline
    }

    var filteredTimeline: [SharedTimelineItem] {
        let query = timelineSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return timeline.filter { item in
            selectedKinds.contains(item.kind)
                && (
                    query.isEmpty
                        || item.title.localizedCaseInsensitiveContains(query)
                        || item.preview.localizedCaseInsensitiveContains(query)
                )
        }
    }

    var selectedTimelineItem: SharedTimelineItem? {
        timeline.first { $0.id == selectedTimelineItemID }
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                self.reload()
                self.processWatchInbox()
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func reload() {
        let root = locator.rootURL
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) {
                SharedLibraryStore(root: root).loadSnapshot()
            }.value
            guard let self else { return }
            snapshot = loaded
            if selectedTimelineItemID == nil
                || !loaded.timeline.contains(where: { $0.id == selectedTimelineItemID }) {
                selectedTimelineItemID = loaded.timeline.first?.id
            }
        }
    }

    func connectLibrary(_ url: URL) {
        locator.connect(to: url)
    }

    func createNote(title: String, content: String) {
        let root = locator.rootURL
        Task { [weak self] in
            do {
                let item = try await Task.detached(priority: .userInitiated) {
                    try SharedLibraryStore(root: root).createNote(
                        title: title,
                        content: content
                    )
                }.value
                self?.reload(selecting: "knowledge:\(item.id.uuidString)")
                self?.selectedTab = .timeline
            } catch {
                self?.errorMessage = "Couldn’t save the note: \(error.localizedDescription)"
            }
        }
    }

    func importKnowledgeFile(_ url: URL, kind: SharedKnowledgeKind) {
        let accessed = url.startAccessingSecurityScopedResource()
        let root = locator.rootURL
        importState = .importing(url.lastPathComponent)
        Task { [weak self] in
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
                self?.importState = .idle
            }
            guard let self else { return }
            var blocks: [SharedKnowledgeBlock] = []
            var extractionError: String?
            do {
                blocks = try await MobileKnowledgeExtractor.extract(
                    from: url,
                    kind: kind
                )
            } catch {
                extractionError = error.localizedDescription
            }
            do {
                let item = try await Task.detached(priority: .userInitiated) {
                    try SharedLibraryStore(root: root).importKnowledge(
                        source: url,
                        kind: kind,
                        blocks: blocks,
                        extractionError: extractionError
                    )
                }.value
                reload(selecting: "knowledge:\(item.id.uuidString)")
                selectedTab = .timeline
            } catch {
                errorMessage = "Couldn’t import \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    func importAudioFile(_ url: URL, origin: String = "iphone-import") {
        let accessed = url.startAccessingSecurityScopedResource()
        let root = locator.rootURL
        importState = .importing(url.lastPathComponent)
        Task { [weak self] in
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            guard let self else { return }
            do {
                let duration = try await Self.durationSeconds(of: url)
                let recording = try await Task.detached(priority: .userInitiated) {
                    try SharedLibraryStore(root: root).importVoiceRecording(
                        source: url,
                        startedAt: Date(),
                        durationSeconds: duration,
                        title: url.deletingPathExtension().lastPathComponent,
                        origin: origin
                    )
                }.value
                reload(selecting: "recording:\(recording.id)")
                selectedTab = .timeline
                await transcribe(recording)
            } catch {
                errorMessage = "Couldn’t import \(url.lastPathComponent): \(error.localizedDescription)"
            }
            importState = .idle
        }
    }

    func toggleRecording() {
        if recorder.isRecording {
            guard let capture = recorder.stop() else { return }
            importVoiceCapture(capture, origin: "iphone")
        } else {
            Task { await recorder.start() }
        }
    }

    func updateKnowledge(
        id: UUID,
        title: String? = nil,
        content: String? = nil,
        notes: String? = nil
    ) {
        let root = locator.rootURL
        Task { [weak self] in
            do {
                try await Task.detached(priority: .utility) {
                    try SharedLibraryStore(root: root).updateKnowledge(
                        id: id,
                        title: title,
                        content: content,
                        additionalNotes: notes
                    )
                }.value
                self?.reload(selecting: "knowledge:\(id.uuidString)")
            } catch {
                self?.errorMessage = "Couldn’t save this item: \(error.localizedDescription)"
            }
        }
    }

    func updateRecordingNotes(_ notes: String, recordingID: String) {
        let root = locator.rootURL
        Task { [weak self] in
            do {
                try await Task.detached(priority: .utility) {
                    try SharedLibraryStore(root: root).updateRecordingNotes(
                        notes,
                        recordingID: recordingID
                    )
                }.value
                self?.reload(selecting: "recording:\(recordingID)")
            } catch {
                self?.errorMessage = "Couldn’t save recording notes: \(error.localizedDescription)"
            }
        }
    }

    func delete(_ item: SharedTimelineItem) {
        do {
            switch item {
            case .knowledge(let knowledge):
                try FileManager.default.removeItem(at: knowledge.directory)
            case .recording(let recording):
                try FileManager.default.removeItem(at: recording.directory)
            }
            reload()
        } catch {
            errorMessage = "Couldn’t delete this item: \(error.localizedDescription)"
        }
    }

    func ask() {
        let question = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering else { return }
        chatDraft = ""
        chatMessages.append(
            MobileChatMessage(role: .user, text: question, sources: [])
        )
        isAnswering = true
        let root = locator.rootURL
        Task { [weak self] in
            guard let self else { return }
            let sources = await Task.detached(priority: .userInitiated) {
                SharedLibraryStore(root: root).search(question, limit: 8)
            }.value
            do {
                let answer = try await MobileAnswerService.answer(
                    question: question,
                    sources: sources
                )
                chatMessages.append(
                    MobileChatMessage(
                        role: .assistant,
                        text: answer,
                        sources: sources
                    )
                )
            } catch {
                chatMessages.append(
                    MobileChatMessage(
                        role: .assistant,
                        text: "I couldn’t answer that locally: \(error.localizedDescription)",
                        sources: sources
                    )
                )
            }
            isAnswering = false
        }
    }

    func openSource(_ source: SharedSearchResult) {
        selectedSource = source
        selectedTimelineItemID = source.itemID
        selectedTab = .timeline
    }

    func processWatchInbox() {
        guard !processingWatchInbox else { return }
        let entries = watchBridge.inboxEntries()
        guard !entries.isEmpty else { return }
        processingWatchInbox = true
        let root = locator.rootURL
        Task { [weak self] in
            guard let self else { return }
            for entry in entries {
                let startedAt = entry.metadata["started"].flatMap {
                    ISO8601DateFormatter().date(from: $0)
                } ?? Date()
                let duration = Int(entry.metadata["duration_seconds"] ?? "") ?? 0
                let title = entry.metadata["title"] ?? "Apple Watch voice message"
                do {
                    let recording = try await Task.detached(priority: .userInitiated) {
                        try SharedLibraryStore(root: root).importVoiceRecording(
                            source: entry.audioURL,
                            startedAt: startedAt,
                            durationSeconds: duration,
                            title: title,
                            origin: "apple-watch"
                        )
                    }.value
                    watchBridge.markProcessed(entry)
                    await transcribe(recording)
                } catch {
                    errorMessage = "Couldn’t import a Watch recording: \(error.localizedDescription)"
                }
            }
            processingWatchInbox = false
            reload()
        }
    }

    private func importVoiceCapture(_ capture: VoiceCapture, origin: String) {
        let root = locator.rootURL
        importState = .importing("voice message")
        Task { [weak self] in
            guard let self else { return }
            do {
                let recording = try await Task.detached(priority: .userInitiated) {
                    try SharedLibraryStore(root: root).importVoiceRecording(
                        source: capture.url,
                        startedAt: capture.startedAt,
                        durationSeconds: capture.durationSeconds,
                        title: "Voice message · \(capture.startedAt.formatted(date: .abbreviated, time: .shortened))",
                        origin: origin
                    )
                }.value
                try? FileManager.default.removeItem(at: capture.url)
                reload(selecting: "recording:\(recording.id)")
                selectedTab = .timeline
                await transcribe(recording)
            } catch {
                errorMessage = "Couldn’t save the recording: \(error.localizedDescription)"
            }
            importState = .idle
        }
    }

    private func transcribe(_ recording: SharedRecordingItem) async {
        guard let audioURL = recording.audioURL else { return }
        importState = .transcribing(recording.title)
        do {
            if let transcript = try await MobileTranscriber.transcribe(audioURL) {
                let root = locator.rootURL
                try await Task.detached(priority: .userInitiated) {
                    try SharedLibraryStore(root: root).saveTranscript(
                        transcript,
                        recordingID: recording.id
                    )
                }.value
            }
        } catch {
            // Leave the recording without transcript.json. The macOS app sees
            // that as pending work and runs its multilingual Parakeet pipeline.
        }
        importState = .idle
        reload(selecting: "recording:\(recording.id)")
    }

    private func reload(selecting id: String) {
        selectedTimelineItemID = id
        reload()
    }

    private static func durationSeconds(of url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? max(1, Int(seconds.rounded())) : 0
    }
}
