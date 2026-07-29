import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case capture
        case timeline
        case chats

        var id: String { rawValue }
    }

    struct IngestionState: Equatable {
        let completed: Int
        let total: Int
        let currentName: String

        var progress: Double {
            total == 0 ? 0 : Double(completed) / Double(total)
        }
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

    struct KnowledgeJump: Equatable {
        let itemID: UUID
        let page: Int?
        let token = UUID()
    }

    enum DeletionRequest: Identifiable, Equatable {
        case thread(id: UUID, title: String)
        case recording(id: String, title: String)
        case knowledge(id: UUID, title: String)

        var id: String {
            switch self {
            case .thread(let id, _): "thread-\(id)"
            case .recording(let id, _): "recording-\(id)"
            case .knowledge(let id, _): "knowledge-\(id)"
            }
        }

        var confirmationTitle: String {
            switch self {
            case .thread: "Delete this conversation?"
            case .recording: "Move this recording to Trash?"
            case .knowledge: "Move this item to Trash?"
            }
        }

        var actionTitle: String {
            switch self {
            case .thread: "Delete Conversation"
            case .recording, .knowledge: "Move to Trash"
            }
        }

        var message: String {
            switch self {
            case .thread(_, let title):
                "“\(title)” and its messages will be permanently deleted. This cannot be undone."
            case .recording(_, let title):
                "“\(title)” and its audio, transcript, and notes will move to the macOS Trash."
            case .knowledge(_, let title):
                "“\(title)” and its imported file, extracted text, and notes will move to the macOS Trash."
            }
        }
    }

    @Published var section: Section = .capture
    @Published var recordings: [RecordingItem]
    @Published var selectedRecordingID: String?
    @Published var knowledgeItems: [KnowledgeItem]
    @Published var selectedTimelineItemID: String?
    @Published var timelineSearch = ""
    @Published var timelineFilters = Set(TimelineItemKind.allCases)
    @Published var ingestionState: IngestionState?

    @Published var threads: [ChatThread]
    @Published var selectedThreadID: UUID?
    @Published var chatDraft = ""
    @Published var chatStage: ChatPipelineStage = .idle
    @Published var chatError: String?
    @Published var transcriptJump: TranscriptJump?
    @Published var knowledgeJump: KnowledgeJump?

    @Published var isRecording = false
    @Published var recordingElapsed = "0:00"
    @Published var liveNotes = ""
    @Published var transcriptionStatus: String?
    @Published var appError: String?
    @Published var deletionRequest: DeletionRequest?

    @Published var aiStatus: BuiltInAIState
    @Published var selectedModelID: String
    @Published var selectedModelPlan: BuiltInModelPlan
    @Published var showingSettings = false
    @Published var showingModelRecommendation = false
    @Published var meetingDetectionEnabled: Bool

    let root: URL
    let knowledgeRoot: URL
    let deviceProfile: DeviceProfile

    var onRecordingStateChange: ((Bool, String?) -> Void)?
    var onTranscriptionStateChange: ((String?) -> Void)?
    var onMeetingDetected: ((DetectedMeeting) -> Void)?

    private let transcription = TranscriptionCoordinator()
    private let meetingDetector = MeetingDetector()
    private let llm: BuiltInLLMEngine
    private let chatStore: ChatStore
    private var session: RecordingSession?
    private var ticker: Timer?
    private var recordingStartedAt: Date?
    private var notesSaveTask: Task<Void, Never>?
    private var knowledgeSaveTasks: [UUID: Task<Void, Never>] = [:]

    private static let selectedModelKey = "dropsift.builtInAI.selectedModel"
    private static let recommendationKey = "dropsift.builtInAI.recommendationHandled"
    private static let legacySelectedModelKey = "quill.builtInAI.selectedModel"
    private static let legacyRecommendationKey = "quill.builtInAI.recommendationHandled"
    private static let meetingDetectionKey = "dropsift.meetingDetection.enabled"
    private static let legacyDefaults = UserDefaults(suiteName: "com.digimata.quill")

    init(root: URL) {
        let profile = DeviceProfile.current
        let storedModelID = UserDefaults.standard.string(forKey: Self.selectedModelKey)
            ?? UserDefaults.standard.string(forKey: Self.legacySelectedModelKey)
            ?? Self.legacyDefaults?.string(forKey: Self.legacySelectedModelKey)
        let selectedModel = AIModelCatalog.model(id: storedModelID)
        let modelPlan = AIModelCatalog.plan(for: selectedModel, device: profile)

        self.root = root
        knowledgeRoot = root.deletingLastPathComponent().appendingPathComponent(
            "Items",
            isDirectory: true
        )
        deviceProfile = profile
        selectedModelID = selectedModel.id
        selectedModelPlan = modelPlan
        llm = BuiltInLLMEngine(
            cacheRoot: Config.modelCacheRoot,
            plan: modelPlan
        )
        chatStore = ChatStore(directory: root.deletingLastPathComponent().appendingPathComponent(
            "Threads",
            isDirectory: true
        ))
        aiStatus = BuiltInLLMEngine.hasCachedModel(
            selectedModel,
            in: Config.modelCacheRoot
        )
            ? .downloaded
            : .notDownloaded
        meetingDetectionEnabled = UserDefaults.standard.object(
            forKey: Self.meetingDetectionKey
        ) as? Bool ?? true

        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: knowledgeRoot,
            withIntermediateDirectories: true
        )
        RecordingLibrary.copyLegacyRecordingsIfNeeded(to: root)
        recordings = RecordingLibrary.load(from: root)
        knowledgeItems = KnowledgeLibrary.load(from: knowledgeRoot)
        threads = chatStore.load().sorted { $0.updatedAt > $1.updatedAt }
        selectedRecordingID = recordings.first?.id
        selectedTimelineItemID = nil
        selectedThreadID = threads.first?.id
        selectedTimelineItemID = timelineItems.first?.id
    }

    var timelineItems: [TimelineItem] {
        (
            recordings.map(TimelineItem.recording)
                + knowledgeItems.map(TimelineItem.knowledge)
        )
        .sorted { $0.date > $1.date }
    }

    var filteredTimelineItems: [TimelineItem] {
        let query = timelineSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return timelineItems.filter { item in
            timelineFilters.contains(item.kind)
                && (
                    query.isEmpty
                        || item.title.localizedCaseInsensitiveContains(query)
                        || item.preview.localizedCaseInsensitiveContains(query)
                )
        }
    }

    var selectedRecording: RecordingItem? {
        recordings.first { $0.id == selectedRecordingID }
    }

    var selectedKnowledgeItem: KnowledgeItem? {
        guard let selectedTimelineItemID,
              selectedTimelineItemID.hasPrefix("knowledge:"),
              let id = UUID(uuidString: String(selectedTimelineItemID.dropFirst(10)))
        else { return nil }
        return knowledgeItems.first { $0.id == id }
    }

    var selectedTimelineItem: TimelineItem? {
        timelineItems.first { $0.id == selectedTimelineItemID }
    }

    var selectedThread: ChatThread? {
        threads.first { $0.id == selectedThreadID }
    }

    var isAnswering: Bool {
        chatStage != .idle
    }

    var selectedModel: String {
        selectedModelPlan.model.displayName
    }

    var modelCacheRoot: URL {
        Config.modelCacheRoot
    }

    var recommendedModelPlan: BuiltInModelPlan {
        AIModelCatalog.recommendation(for: deviceProfile)
    }

    var modelPlans: [BuiltInModelPlan] {
        AIModelCatalog.models.map {
            AIModelCatalog.plan(for: $0, device: deviceProfile)
        }
    }

    var modelMemoryPolicyLabel: String {
        "Models may use up to \(recommendedModelPlan.budgetLabel) — 50% of unified memory."
    }

    var isAITransitioning: Bool {
        switch aiStatus {
        case .downloading, .loading:
            true
        case .notDownloaded, .downloaded, .ready, .failed:
            false
        }
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
            if BuiltInLLMEngine.hasCachedModel(
                model.selectedModelPlan.model,
                in: Config.modelCacheRoot
            ) {
                await model.prepareBuiltInAI()
            }
            if model.shouldOfferModelRecommendation {
                model.showingModelRecommendation = true
            }
        }
        if meetingDetectionEnabled {
            Task { [meetingDetector] in
                await meetingDetector.start { [weak self] meeting in
                    guard let self, !self.isRecording, self.meetingDetectionEnabled else {
                        return
                    }
                    self.onMeetingDetected?(meeting)
                }
            }
        }
    }

    func shutdown() {
        if isRecording {
            stopRecording()
        }
        Task { [meetingDetector] in await meetingDetector.stop() }
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
            liveNotes = ""
            isRecording = true
            recordingElapsed = "0:00"
            onRecordingStateChange?(true, recordingElapsed)
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.tickRecording() }
            }
        } catch {
            appError = "Couldn’t start recording: \(error)"
            notifyUser(title: "Dropsift — recording failed", body: "\(error)")
        }
    }

    func stopRecording() {
        guard let session else { return }
        flushLiveNotes(to: session.dir)
        session.stop()
        let directory = session.dir
        self.session = nil
        liveNotes = ""
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
            selectedTimelineItemID = "recording:\(recordingID)"
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

    func openKnowledgeFolder() {
        try? FileManager.default.createDirectory(
            at: knowledgeRoot,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(knowledgeRoot)
    }

    func openAudio(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    func updateLiveNotes(_ notes: String) {
        liveNotes = notes
        guard let directory = session?.dir else { return }

        notesSaveTask?.cancel()
        notesSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                try RecordingLibrary.saveNotes(notes, to: directory)
            } catch {
                self?.appError = "Couldn’t save recording notes: \(error.localizedDescription)"
            }
        }
    }

    func createNote() {
        do {
            let item = try KnowledgeLibrary.createNote(in: knowledgeRoot)
            reloadKnowledge(selecting: item.id)
            section = .timeline
        } catch {
            appError = "Couldn’t create a note: \(error.localizedDescription)"
        }
    }

    func chooseDocuments() {
        presentOpenPanel(
            title: "Add documents to Dropsift",
            types: documentTypes
        ) { [weak self] urls in
            self?.importKnowledgeFiles(urls, requestedKind: .document)
        }
    }

    func chooseImages() {
        presentOpenPanel(
            title: "Add images to Dropsift",
            types: [.image]
        ) { [weak self] urls in
            self?.importKnowledgeFiles(urls, requestedKind: .image)
        }
    }

    func chooseAudioRecordings() {
        presentOpenPanel(
            title: "Add audio recordings to Dropsift",
            types: [.audio]
        ) { [weak self] urls in
            self?.importAudioFiles(urls)
        }
    }

    func ingestDroppedFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task { [weak self, transcription] in
            guard let self else { return }
            var lastSelection: String?
            for (index, url) in urls.enumerated() {
                ingestionState = IngestionState(
                    completed: index,
                    total: urls.count,
                    currentName: url.lastPathComponent
                )
                do {
                    let type = contentType(for: url)
                    if type?.conforms(to: .audio) == true {
                        let directory = try await RecordingLibrary.importAudio(
                            from: url,
                            to: root
                        )
                        lastSelection = "recording:\(directory.lastPathComponent)"
                        reloadRecordings(selecting: directory.lastPathComponent)
                        await transcription.enqueue(directory)
                    } else {
                        let kind: KnowledgeItemKind =
                            type?.conforms(to: .image) == true ? .image : .document
                        let destinationRoot = knowledgeRoot
                        let item = try await Task.detached(priority: .userInitiated) {
                            try KnowledgeLibrary.importFile(
                                url,
                                as: kind,
                                into: destinationRoot
                            )
                        }.value
                        lastSelection = "knowledge:\(item.id.uuidString)"
                        reloadKnowledge(selecting: item.id)
                    }
                } catch {
                    appError = "Couldn’t add \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
            ingestionState = nil
            if let lastSelection {
                selectedTimelineItemID = lastSelection
                selectTimelineItem(lastSelection)
                section = .timeline
            }
        }
    }

    func renameKnowledgeItem(_ itemID: UUID, to title: String) {
        guard let item = knowledgeItems.first(where: { $0.id == itemID }) else { return }
        do {
            try KnowledgeLibrary.saveTitle(title, for: item)
            reloadKnowledge(selecting: itemID)
        } catch {
            appError = "Couldn’t rename this item: \(error.localizedDescription)"
        }
    }

    func updateKnowledgeContent(_ content: String, itemID: UUID) {
        guard let item = knowledgeItems.first(where: { $0.id == itemID }) else { return }
        scheduleKnowledgeSave(itemID: itemID) { try KnowledgeLibrary.saveContent(content, for: item) }
    }

    func updateKnowledgeNotes(_ notes: String, itemID: UUID) {
        guard let item = knowledgeItems.first(where: { $0.id == itemID }) else { return }
        scheduleKnowledgeSave(itemID: itemID) {
            try KnowledgeLibrary.saveAdditionalNotes(notes, for: item)
        }
    }

    func updateRecordingNotes(_ notes: String, recordingID: String) {
        guard let recording = recordings.first(where: { $0.id == recordingID }) else { return }
        notesSaveTask?.cancel()
        notesSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                try RecordingLibrary.saveNotes(notes, to: recording.directory)
                self?.reloadRecordings(selecting: recordingID)
            } catch {
                self?.appError = "Couldn’t save recording notes: \(error.localizedDescription)"
            }
        }
    }

    func toggleTimelineFilter(_ kind: TimelineItemKind) {
        if timelineFilters.contains(kind) {
            timelineFilters.remove(kind)
        } else {
            timelineFilters.insert(kind)
        }
    }

    func selectTimelineItem(_ id: String?) {
        selectedTimelineItemID = id
        guard let id else { return }
        if id.hasPrefix("recording:") {
            selectedRecordingID = String(id.dropFirst(10))
        }
    }

    func setMeetingDetectionEnabled(_ enabled: Bool) {
        meetingDetectionEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.meetingDetectionKey)
        Task { [meetingDetector] in
            if enabled {
                await meetingDetector.start { [weak self] meeting in
                    guard let self, !self.isRecording, self.meetingDetectionEnabled else {
                        return
                    }
                    self.onMeetingDetected?(meeting)
                }
            } else {
                await meetingDetector.stop()
            }
        }
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

    func requestDeleteThread(_ thread: ChatThread) {
        deletionRequest = .thread(id: thread.id, title: thread.title)
    }

    func requestDeleteRecording(_ recording: RecordingItem) {
        deletionRequest = .recording(id: recording.id, title: recording.title)
    }

    func requestDeleteKnowledgeItem(_ item: KnowledgeItem) {
        deletionRequest = .knowledge(id: item.id, title: item.title)
    }

    func cancelDeletion() {
        deletionRequest = nil
    }

    func confirmDeletion(_ request: DeletionRequest) {
        deletionRequest = nil
        switch request {
        case .thread(let id, _):
            deleteThread(id)
        case .recording(let id, _):
            moveRecordingToTrash(id)
        case .knowledge(let id, _):
            moveKnowledgeToTrash(id)
        }
    }

    func openSource(_ source: ChatSource) {
        if let itemID = source.knowledgeItemID {
            selectedTimelineItemID = "knowledge:\(itemID.uuidString)"
            knowledgeJump = KnowledgeJump(itemID: itemID, page: source.page)
            section = .timeline
            return
        }
        selectedRecordingID = source.recordingID
        selectedTimelineItemID = "recording:\(source.recordingID)"
        transcriptJump = TranscriptJump(
            recordingID: source.recordingID,
            startMs: source.startMs
        )
        section = .timeline
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
        let knowledgeSnapshot = knowledgeItems
        let retrievalLimit = max(
            10,
            min(512, selectedModelPlan.contextTokens / 512)
        )
        let retrievalCharacterBudget = max(
            16_000,
            min(
                600_000,
                max(4_096, selectedModelPlan.contextTokens - 16_384) * 2
            )
        )
        persistThreads()
        chatStage = .retrieving

        Task { [weak self, llm] in
            guard let self else { return }
            do {
                let chunks = await Task.detached(priority: .userInitiated) {
                    let transcripts = TranscriptRetriever.retrieve(
                        query: retrievalQuery,
                        recordings: recordingsSnapshot,
                        scope: scope,
                        limit: retrievalLimit,
                        characterBudget: retrievalCharacterBudget
                    )
                    let knowledge = scope.kind == .allRecordings
                        ? KnowledgeRetriever.retrieve(
                            query: retrievalQuery,
                            items: knowledgeSnapshot,
                            limit: retrievalLimit,
                            characterBudget: retrievalCharacterBudget
                        )
                        : []
                    return RetrievedContext.interleave(
                        transcripts: transcripts,
                        knowledge: knowledge,
                        limit: retrievalLimit,
                        characterBudget: retrievalCharacterBudget
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

    func selectModel(_ modelID: String, downloadAndUse: Bool = true) {
        guard !isAnswering, !isAITransitioning else { return }
        let model = AIModelCatalog.model(id: modelID)
        let newPlan = AIModelCatalog.plan(for: model, device: deviceProfile)
        guard newPlan.fitsMemoryBudget,
              deviceProfile.totalMemoryBytes >= model.minimumDeviceMemoryBytes
        else {
            appError = "\(model.name) does not fit Dropsift’s 50% memory safety limit on this Mac."
            return
        }

        selectedModelID = model.id
        selectedModelPlan = newPlan
        UserDefaults.standard.set(model.id, forKey: Self.selectedModelKey)
        markRecommendationHandled()

        let cached = BuiltInLLMEngine.hasCachedModel(
            model,
            in: Config.modelCacheRoot
        )
        aiStatus = cached ? .downloaded : .notDownloaded
        Task { [weak self, llm] in
            await llm.configure(newPlan)
            guard let self else { return }
            if downloadAndUse || cached {
                await self.prepareBuiltInAI()
            }
        }
    }

    func keepConservativeModel() {
        markRecommendationHandled()
        showingModelRecommendation = false
        if selectedModelID != AIModelCatalog.defaultModel.id {
            selectModel(AIModelCatalog.defaultModel.id, downloadAndUse: false)
        }
    }

    func useRecommendedModel() {
        let recommendation = recommendedModelPlan
        markRecommendationHandled()
        showingModelRecommendation = false
        selectModel(recommendation.model.id)
    }

    func reviewModelChoices() {
        markRecommendationHandled()
        showingModelRecommendation = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.showingSettings = true
        }
    }

    func isModelCached(_ model: BuiltInModel) -> Bool {
        BuiltInLLMEngine.hasCachedModel(model, in: Config.modelCacheRoot)
    }

    func openModelFolder() {
        try? FileManager.default.createDirectory(
            at: Config.modelCacheRoot,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(Config.modelCacheRoot)
    }

    private var shouldOfferModelRecommendation: Bool {
        let recommendation = recommendedModelPlan
        guard recommendation.model.id != selectedModelID else { return false }
        return (
            UserDefaults.standard.string(forKey: Self.recommendationKey)
                ?? UserDefaults.standard.string(forKey: Self.legacyRecommendationKey)
                ?? Self.legacyDefaults?.string(forKey: Self.legacyRecommendationKey)
        )
            != recommendationSignature
    }

    private var recommendationSignature: String {
        "v2:\(recommendedModelPlan.model.id):\(deviceProfile.totalMemoryBytes)"
    }

    private func markRecommendationHandled() {
        UserDefaults.standard.set(
            recommendationSignature,
            forKey: Self.recommendationKey
        )
    }

    private var documentTypes: [UTType] {
        let extensions = ["pdf", "txt", "md", "rtf", "rtfd", "html", "htm", "csv", "json", "xml", "doc", "docx"]
        return extensions.compactMap { UTType(filenameExtension: $0) }
    }

    private func contentType(for url: URL) -> UTType? {
        UTType(filenameExtension: url.pathExtension)
    }

    private func presentOpenPanel(
        title: String,
        types: [UTType],
        completion: @escaping ([URL]) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Add"
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        completion(panel.urls)
    }

    private func importKnowledgeFiles(
        _ urls: [URL],
        requestedKind: KnowledgeItemKind
    ) {
        guard !urls.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            var lastID: UUID?
            for (index, url) in urls.enumerated() {
                ingestionState = IngestionState(
                    completed: index,
                    total: urls.count,
                    currentName: url.lastPathComponent
                )
                do {
                    let root = knowledgeRoot
                    let item = try await Task.detached(priority: .userInitiated) {
                        try KnowledgeLibrary.importFile(
                            url,
                            as: requestedKind,
                            into: root
                        )
                    }.value
                    lastID = item.id
                    reloadKnowledge(selecting: item.id)
                } catch {
                    appError = "Couldn’t add \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
            ingestionState = nil
            if let lastID {
                reloadKnowledge(selecting: lastID)
                section = .timeline
            }
        }
    }

    private func importAudioFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task { [weak self, transcription] in
            guard let self else { return }
            var lastRecordingID: String?
            for (index, url) in urls.enumerated() {
                ingestionState = IngestionState(
                    completed: index,
                    total: urls.count,
                    currentName: url.lastPathComponent
                )
                do {
                    let directory = try await RecordingLibrary.importAudio(
                        from: url,
                        to: root
                    )
                    lastRecordingID = directory.lastPathComponent
                    reloadRecordings(selecting: directory.lastPathComponent)
                    await transcription.enqueue(directory)
                } catch {
                    appError = "Couldn’t add \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
            ingestionState = nil
            if let lastRecordingID {
                reloadRecordings(selecting: lastRecordingID)
                section = .timeline
            }
        }
    }

    private func reloadKnowledge(selecting itemID: UUID? = nil) {
        knowledgeItems = KnowledgeLibrary.load(from: knowledgeRoot)
        if let itemID, knowledgeItems.contains(where: { $0.id == itemID }) {
            selectedTimelineItemID = "knowledge:\(itemID.uuidString)"
        } else if selectedKnowledgeItem == nil,
                  let first = knowledgeItems.first {
            selectedTimelineItemID = "knowledge:\(first.id.uuidString)"
        }
    }

    private func scheduleKnowledgeSave(
        itemID: UUID,
        action: @escaping @Sendable () throws -> Void
    ) {
        knowledgeSaveTasks[itemID]?.cancel()
        knowledgeSaveTasks[itemID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                try await Task.detached(priority: .utility) {
                    try action()
                }.value
                self?.reloadKnowledge(selecting: itemID)
            } catch {
                self?.appError = "Couldn’t save this item: \(error.localizedDescription)"
            }
        }
    }

    private func persistThreads() {
        do {
            try chatStore.save(threads)
        } catch {
            appError = "Couldn’t save chat history: \(error.localizedDescription)"
        }
    }

    private func deleteThread(_ id: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedThreadID == id
        threads.remove(at: index)
        if wasSelected {
            selectedThreadID = threads.indices.contains(index)
                ? threads[index].id
                : threads.last?.id
            chatDraft = ""
            chatError = nil
        }
        persistThreads()
    }

    private func moveRecordingToTrash(_ id: String) {
        guard let recording = recordings.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.recycle([recording.directory]) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.appError = "Couldn’t move the recording to Trash: \(error.localizedDescription)"
                    return
                }

                for index in self.threads.indices
                where self.threads[index].scope.recordingID == id {
                    self.threads[index].scope = .all
                    self.threads[index].updatedAt = Date()
                }
                self.persistThreads()
                self.reloadRecordings()
                if self.selectedTimelineItemID == "recording:\(id)" {
                    self.selectedTimelineItemID = self.timelineItems.first?.id
                    self.selectTimelineItem(self.selectedTimelineItemID)
                }
            }
        }
    }

    private func moveKnowledgeToTrash(_ id: UUID) {
        guard let item = knowledgeItems.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.recycle([item.directory]) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.appError = "Couldn’t move this item to Trash: \(error.localizedDescription)"
                    return
                }
                self.reloadKnowledge()
                if self.selectedTimelineItemID == "knowledge:\(id.uuidString)" {
                    self.selectedTimelineItemID = self.timelineItems.first?.id
                }
            }
        }
    }

    private func flushLiveNotes(to directory: URL) {
        notesSaveTask?.cancel()
        notesSaveTask = nil
        do {
            try RecordingLibrary.saveNotes(liveNotes, to: directory)
        } catch {
            appError = "Couldn’t save recording notes: \(error.localizedDescription)"
        }
    }

    private func apply(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            transcriptionStatus = nil
            reloadRecordings()
        case .preparingModel(let session, let detail, let progress):
            let percent = Int((progress * 100).rounded())
            transcriptionStatus = "\(detail) · \(percent)% · \(session)"
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
        chunks: [RetrievedContext],
        scope: ChatScope
    ) -> String {
        let context = chunks.enumerated().map { index, chunk in
            """
            [\(index + 1)] \(chunk.title) · \(chunk.locator)
            \(chunk.text)
            """
        }.joined(separator: "\n\n---\n\n")
        let scopeDescription = scope.kind == .allRecordings
            ? "the user’s complete Dropsift knowledge library"
            : "the selected Dropsift recording"

        return """
        You are Dropsift, a private local knowledge assistant. Answer questions about \(scopeDescription).
        Use only the source excerpts below for claims about the user's knowledge. If the excerpts
        do not contain the answer, say that clearly. Cite grounded claims inline as [1], [2], and
        so on, matching the numbered excerpts. Be concise, synthesize across source types when
        useful, and distinguish the user's notes from extracted document, image, and transcript text.

        SOURCE EXCERPTS
        \(context.isEmpty ? "(No indexed excerpts are available in this scope.)" : context)
        """
    }

    private static func citedSources(
        answer: String,
        chunks: [RetrievedContext]
    ) -> [ChatSource] {
        let allSources = chunks.enumerated().map {
            $0.element.source(number: $0.offset + 1)
        }
        let cited = allSources.filter { answer.contains("[\($0.number)]") }
        return cited.isEmpty ? Array(allSources.prefix(4)) : cited
    }
}
