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

    enum AIStatus: Equatable {
        case checking
        case connected(String)
        case offline(String)
    }

    enum ChatPipelineStage: Equatable {
        case idle
        case retrieving
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

    @Published var aiStatus: AIStatus = .checking
    @Published var availableModels: [String] = []
    @Published var selectedModel: String
    @Published var endpoint: String
    @Published var showingSettings = false

    let root: URL

    var onRecordingStateChange: ((Bool, String?) -> Void)?
    var onTranscriptionStateChange: ((String?) -> Void)?

    private let transcription = TranscriptionCoordinator()
    private let llm = LocalLLMClient()
    private let chatStore: ChatStore
    private var connection: LocalLLMConnection?
    private var session: RecordingSession?
    private var ticker: Timer?
    private var recordingStartedAt: Date?

    init(root: URL) {
        self.root = root
        chatStore = ChatStore(directory: root.deletingLastPathComponent().appendingPathComponent(
            "Threads",
            isDirectory: true
        ))
        endpoint = UserDefaults.standard.string(forKey: "localLLMEndpoint")
            ?? "http://127.0.0.1:1234/v1"
        selectedModel = UserDefaults.standard.string(forKey: "localLLMModel") ?? ""

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
            await transcription.resumePending(root: root)
            await model.refreshAIConnection()
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
                chatStage = .generating
                let connection = try await ensureConnection()
                let model = try chooseModel(from: connection.models)
                let answer = try await llm.complete(
                    connection: connection,
                    model: model,
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
                aiStatus = .offline(error.localizedDescription)
            }
        }
    }

    func refreshAIConnection() async {
        aiStatus = .checking
        do {
            let found = try await llm.discover(preferredEndpoint: endpoint)
            connection = found
            endpoint = found.baseURL.absoluteString
            availableModels = Self.chatModels(from: found.models)
            if selectedModel.isEmpty || !availableModels.contains(selectedModel) {
                selectedModel = Self.preferredModel(from: availableModels) ?? ""
            }
            aiStatus = .connected(found.serverName)
            UserDefaults.standard.set(endpoint, forKey: "localLLMEndpoint")
            UserDefaults.standard.set(selectedModel, forKey: "localLLMModel")
        } catch {
            connection = nil
            availableModels = []
            aiStatus = .offline(error.localizedDescription)
        }
    }

    func saveAISettings() {
        UserDefaults.standard.set(endpoint, forKey: "localLLMEndpoint")
        UserDefaults.standard.set(selectedModel, forKey: "localLLMModel")
        connection = nil
        Task { await refreshAIConnection() }
    }

    private func ensureConnection() async throws -> LocalLLMConnection {
        if let connection { return connection }
        let found = try await llm.discover(preferredEndpoint: endpoint)
        connection = found
        availableModels = Self.chatModels(from: found.models)
        aiStatus = .connected(found.serverName)
        return found
    }

    private func chooseModel(from models: [String]) throws -> String {
        let chatModels = Self.chatModels(from: models)
        guard !chatModels.isEmpty else { throw LocalLLMClient.ClientError.noChatModel }
        let model = chatModels.contains(selectedModel)
            ? selectedModel
            : Self.preferredModel(from: chatModels) ?? chatModels[0]
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "localLLMModel")
        return model
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

    private static func chatModels(from models: [String]) -> [String] {
        models.filter {
            let value = $0.lowercased()
            return !value.contains("embed") && !value.contains("rerank")
        }
    }

    private static func preferredModel(from models: [String]) -> String? {
        models.first {
            let value = $0.lowercased()
            return value.contains("mlx")
                && (value.contains("2b") || value.contains("3b") || value.contains("4b"))
        }
            ?? models.first { $0.lowercased().contains("mlx") }
            ?? models.first
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
