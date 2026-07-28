import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case recordings
        case chats

        var id: String { rawValue }
    }

    enum ChatPipelineStage: Equatable {
        case idle
        case retrieving
        case preparingAI
        case generating
    }

    struct TranscriptJump: Equatable {
        let recordingID: String
        let startMs: Int
        let token = UUID()
    }

    @Published var section: Section = .recordings
    @Published var recordings: [RecordingItem]
    @Published var selectedRecordingID: String?
    @Published var recordingSearch = ""

    @Published var threads: [ChatThread]
    @Published var selectedThreadID: UUID?
    @Published var chatDraft = ""
    @Published var chatStage: ChatPipelineStage = .idle
    @Published var chatError: String?
    @Published var transcriptJump: TranscriptJump?

    @Published var isRecording = false
    @Published var recordingElapsed = "0:00"
    @Published var transcriptionStatus: String?
    @Published var appError: String?

    @Published var aiStatus: BuiltInAIState
    @Published var showingSettings = false

    let root: URL

    var onRecordingStateChange: ((Bool, String?) -> Void)?
    var onTranscriptionStateChange: ((String?) -> Void)?

    private let transcription = TranscriptionCoordinator()
    private let llm: BuiltInLLMEngine
    private let chatStore: ChatStore
    private var session: RecordingSession?
    private var ticker: Timer?
    private var recordingStartedAt: Date?

    init(root: URL) {
        self.root = root
        llm = BuiltInLLMEngine(cacheRoot: Config.modelCacheRoot)
        chatStore = ChatStore(directory: root.deletingLastPathComponent().appendingPathComponent(
            "Threads",
            isDirectory: true
        ))
        aiStatus = BuiltInLLMEngine.hasCachedModel(in: Config.modelCacheRoot)
            ? .loading
            : .notDownloaded

        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        RecordingLibrary.copyLegacyRecordingsIfNeeded(to: root)
        recordings = RecordingLibrary.load(from: root)
        threads = chatStore.load().sorted { $0.updatedAt > $1.updatedAt }
        selectedRecordingID = recordings.first?.id
        selectedThreadID = threads.first?.id
    }

    var filteredRecordings: [RecordingItem] {
        let query = recordingSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return recordings }
        return recordings.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.preview.localizedCaseInsensitiveContains(query)
                || $0.displayDate.localizedCaseInsensitiveContains(query)
        }
    }

    var selectedRecording: RecordingItem? {
        recordings.first { $0.id == selectedRecordingID }
    }

    var selectedThread: ChatThread? {
        threads.first { $0.id == selectedThreadID }
    }

    var isAnswering: Bool {
        chatStage != .idle
    }

    var selectedModel: String {
        BuiltInLLMEngine.modelDisplayName
    }

    var modelCacheRoot: URL {
        Config.modelCacheRoot
    }

    var storageLabel: String {
        root.path.contains("Mobile Documents/com~apple~CloudDocs")
            ? "iCloud Drive"
            : "On this Mac"
    }

    func startServices() {
        let model = self
        Task { [transcription, root, model] in
            await transcription.setStatusHandler { status in
                Task { @MainActor in model.apply(status) }
            }
            await model.llm.setStateHandler { state in
                Task { @MainActor in model.aiStatus = state }
            }
            await transcription.resumePending(root: root)
            if BuiltInLLMEngine.hasCachedModel(in: Config.modelCacheRoot) {
                await model.prepareBuiltInAI()
            }
        }
    }

    func shutdown() {
        if isRecording {
            stopRecording()
        }
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        do {
            let newSession = try RecordingSession(root: root)
            try newSession.start()
            session = newSession
            recordingStartedAt = newSession.startedAt
            isRecording = true
            recordingElapsed = "0:00"
            onRecordingStateChange?(true, recordingElapsed)
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.tickRecording() }
            }
        } catch {
            appError = "Couldn’t start recording: \(error)"
            notifyUser(title: "Quill — recording failed", body: "\(error)")
        }
    }

    func stopRecording() {
        guard let session else { return }
        session.stop()
        let directory = session.dir
        self.session = nil
        recordingStartedAt = nil
        ticker?.invalidate()
        ticker = nil
        isRecording = false
        recordingElapsed = "0:00"
        onRecordingStateChange?(false, nil)
        reloadRecordings(selecting: directory.lastPathComponent)
        Task { [transcription] in await transcription.enqueue(directory) }
    }

    func reloadRecordings(selecting recordingID: String? = nil) {
        recordings = RecordingLibrary.load(from: root)
        if let recordingID, recordings.contains(where: { $0.id == recordingID }) {
            selectedRecordingID = recordingID
        } else if !recordings.contains(where: { $0.id == selectedRecordingID }) {
            selectedRecordingID = recordings.first?.id
        }
    }

    func renameSelectedRecording(to title: String) {
        guard let recording = selectedRecording else { return }
        do {
            try RecordingLibrary.saveTitle(title, for: recording)
            reloadRecordings(selecting: recording.id)
        } catch {
            appError = "Couldn’t rename recording: \(error.localizedDescription)"
        }
    }

    func openRecordingsFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    func openAudio(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    func createThread(scope: ChatScope = .all) {
        let thread = ChatThread(scope: scope)
        threads.insert(thread, at: 0)
        selectedThreadID = thread.id
        section = .chats
        persistThreads()
    }

    func setScope(_ scope: ChatScope, for threadID: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[index].scope = scope
        threads[index].updatedAt = Date()
        persistThreads()
    }

    func openSource(_ source: ChatSource) {
        selectedRecordingID = source.recordingID
        transcriptJump = TranscriptJump(
            recordingID: source.recordingID,
            startMs: source.startMs
        )
        section = .recordings
    }

    func sendChatMessage() {
        let question = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering else { return }
        if selectedThreadID == nil {
            createThread()
        }
        guard let threadID = selectedThreadID,
              let index = threads.firstIndex(where: { $0.id == threadID })
        else { return }

        chatDraft = ""
        chatError = nil
        let userMessage = ChatMessage(role: .user, content: question)
        threads[index].messages.append(userMessage)
        threads[index].updatedAt = Date()
        if threads[index].messages.count == 1 {
            threads[index].title = Self.threadTitle(from: question)
        }
        let scope = threads[index].scope
        let conversation = threads[index].messages
        let retrievalQuery = conversation
            .filter { $0.role == .user }
            .suffix(3)
            .map(\.content)
            .joined(separator: "\n")
        let recordingsSnapshot = recordings
        persistThreads()
        chatStage = .retrieving

        Task { [weak self, llm] in
            guard let self else { return }
            do {
                let chunks = await Task.detached(priority: .userInitiated) {
                    TranscriptRetriever.retrieve(
                        query: retrievalQuery,
                        recordings: recordingsSnapshot,
                        scope: scope
                    )
                }.value
                chatStage = .preparingAI
                try await llm.prepare()
                chatStage = .generating
                let answer = try await llm.complete(
                    systemPrompt: Self.systemPrompt(chunks: chunks, scope: scope),
                    messages: conversation
                )
                guard let currentIndex = threads.firstIndex(where: { $0.id == threadID }) else {
                    chatStage = .idle
                    return
                }
                threads[currentIndex].messages.append(
                    ChatMessage(
                        role: .assistant,
                        content: answer,
                        sources: Self.citedSources(answer: answer, chunks: chunks)
                    )
                )
                threads[currentIndex].updatedAt = Date()
                threads.sort { $0.updatedAt > $1.updatedAt }
                persistThreads()
                chatStage = .idle
            } catch {
                chatError = error.localizedDescription
                chatStage = .idle
                aiStatus = .failed(error.localizedDescription)
            }
        }
    }

    func prepareBuiltInAI() async {
        do {
            try await llm.prepare()
        } catch {
            aiStatus = .failed(error.localizedDescription)
        }
    }

    func downloadBuiltInAI() {
        Task { await prepareBuiltInAI() }
    }

    func openModelFolder() {
        try? FileManager.default.createDirectory(
            at: Config.modelCacheRoot,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(Config.modelCacheRoot)
    }

    private func persistThreads() {
        do {
            try chatStore.save(threads)
        } catch {
            appError = "Couldn’t save chat history: \(error.localizedDescription)"
        }
    }

    private func apply(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            transcriptionStatus = nil
            reloadRecordings()
        case .transcribing(let session, let queued):
            transcriptionStatus = queued > 0
                ? "Transcribing \(session) · \(queued) queued"
                : "Transcribing \(session)"
        case .diarizing(let session, let queued):
            transcriptionStatus = queued > 0
                ? "Detecting speakers in \(session) · \(queued) queued"
                : "Detecting speakers in \(session)"
        case .failed(let session):
            transcriptionStatus = "Transcription failed · \(session)"
            reloadRecordings()
        }
        onTranscriptionStateChange?(transcriptionStatus)
    }

    private func tickRecording() {
        guard let recordingStartedAt else { return }
        let seconds = Int(Date().timeIntervalSince(recordingStartedAt))
        recordingElapsed = Self.clock(seconds)
        onRecordingStateChange?(true, recordingElapsed)
    }

    private static func clock(_ totalSeconds: Int) -> String {
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    private static func threadTitle(from question: String) -> String {
        let singleLine = question.replacingOccurrences(of: "\n", with: " ")
        return singleLine.count > 48 ? String(singleLine.prefix(48)) + "…" : singleLine
    }

    private static func systemPrompt(
        chunks: [TranscriptChunk],
        scope: ChatScope
    ) -> String {
        let context = chunks.enumerated().map { index, chunk in
            """
            [\(index + 1)] \(chunk.recordingTitle) @ \(TranscriptDocument.clock(chunk.startMs))
            \(chunk.text)
            """
        }.joined(separator: "\n\n---\n\n")
        let scopeDescription = scope.kind == .allRecordings
            ? "the user’s complete Quill recording library"
            : "the selected Quill recording"

        return """
        You are Quill, a private local meeting assistant. Answer questions about \(scopeDescription).
        Use only the transcript excerpts below for claims about meetings. If the excerpts do not
        contain the answer, say that clearly. Cite meeting claims inline as [1], [2], and so on,
        matching the numbered excerpts. Be concise, synthesize across recordings when useful,
        and never pretend that you heard audio not represented in the transcript.

        TRANSCRIPT EXCERPTS
        \(context.isEmpty ? "(No transcribed excerpts are available in this scope.)" : context)
        """
    }

    private static func citedSources(
        answer: String,
        chunks: [TranscriptChunk]
    ) -> [ChatSource] {
        let allSources = chunks.enumerated().map {
            $0.element.source(number: $0.offset + 1)
        }
        let cited = allSources.filter { answer.contains("[\($0.number)]") }
        return cited.isEmpty ? Array(allSources.prefix(4)) : cited
    }
}
