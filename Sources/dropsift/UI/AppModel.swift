import AppKit
import Combine
import DropsiftShared
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case capture
        case timeline
        case tasks
        case people
        case places
        case events
        case organizations
        case projects
        case topics
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

    private struct SemanticSourceContent: Sendable {
        let sourceID: String
        let revision: String
        let title: String
        let text: String
        let presentationRevision: String
        let presentationKind: String
        let directory: URL
        let speakerLabels: [String]
        let reference: SharedSemanticSourceReference
    }

    private struct ThreadTitleRequest: Sendable {
        let threadID: UUID
        let reportsErrors: Bool
    }

    enum DeletionRequest: Identifiable, Equatable {
        case thread(id: UUID, title: String)
        case recording(id: String, title: String)
        case knowledge(id: UUID, title: String)
        case threads(ids: Set<UUID>, count: Int)
        case timelineItems(
            recordingIDs: Set<String>,
            knowledgeIDs: Set<UUID>,
            count: Int
        )

        var id: String {
            switch self {
            case .thread(let id, _): "thread-\(id)"
            case .recording(let id, _): "recording-\(id)"
            case .knowledge(let id, _): "knowledge-\(id)"
            case .threads(let ids, _):
                "threads-" + ids.map(\.uuidString).sorted().joined(separator: "-")
            case .timelineItems(let recordingIDs, let knowledgeIDs, _):
                "timeline-"
                    + recordingIDs.sorted().joined(separator: "-")
                    + knowledgeIDs.map(\.uuidString).sorted().joined(separator: "-")
            }
        }

        var confirmationTitle: String {
            switch self {
            case .thread: "Delete this conversation?"
            case .recording: "Move this recording to Trash?"
            case .knowledge: "Move this item to Trash?"
            case .threads(_, let count): "Delete \(count) conversations?"
            case .timelineItems(_, _, let count):
                "Move \(count) items to Trash?"
            }
        }

        var actionTitle: String {
            switch self {
            case .thread: "Delete Conversation"
            case .recording, .knowledge: "Move to Trash"
            case .threads: "Delete Conversations"
            case .timelineItems: "Move Items to Trash"
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
            case .threads(_, let count):
                "\(count) conversations and their messages will be permanently deleted. This cannot be undone."
            case .timelineItems(_, _, let count):
                "\(count) selected items and their files will move to the macOS Trash."
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
    @Published var tasks: [SharedTask]
    @Published var entities: [SharedSemanticEntity]
    @Published var selectedTaskID: UUID?
    @Published var selectedEntityID: UUID?
    @Published private(set) var semanticReviews: [SharedSemanticReview]
    @Published var semanticProcessingLabel: String?
    @Published private(set) var semanticProcessingSourceID: String?

    @Published var threads: [ChatThread]
    @Published var selectedThreadID: UUID?
    @Published var chatDraft = ""
    @Published var chatStage: ChatPipelineStage = .idle
    @Published var chatError: String?
    @Published private(set) var regeneratingThreadID: UUID?
    @Published private(set) var metadataGenerationItemID: String?
    @Published private(set) var summaryGenerationItemID: String?
    @Published var transcriptJump: TranscriptJump?
    @Published var knowledgeJump: KnowledgeJump?
    @Published var modelDeletionRequest: BuiltInModel?

    @Published var isRecording = false
    @Published private(set) var isPreparingRecording = false
    @Published private(set) var recordingSessionID: String?
    @Published var recordingElapsed = "0:00"
    @Published var liveRecordingTitle = ""
    @Published var liveNotes = ""
    @Published private(set) var microphoneAudioLevels = Array(
        repeating: Float.zero,
        count: 14
    )
    @Published private(set) var systemAudioLevels = Array(
        repeating: Float.zero,
        count: 14
    )
    @Published private(set) var splittingRecordingID: String?
    @Published var transcriptionStatus: String?
    @Published var appError: String?
    @Published var deletionRequest: DeletionRequest?

    @Published var aiStatus: BuiltInAIState
    @Published private(set) var aiDownloadIsStalled = false
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
    var onMeetingEnded: ((DetectedMeeting) -> Void)?

    private let transcription = TranscriptionCoordinator()
    private let meetingDetector = MeetingDetector()
    private let llm: BuiltInLLMEngine
    private let chatStore: ChatStore
    private let semanticStore: SharedSemanticStore
    private var session: RecordingSession?
    private var ticker: Timer?
    private var recordingStartedAt: Date?
    private var recordingElapsedBaseSeconds = 0
    private var titleSaveTask: Task<Void, Never>?
    private var notesSaveTask: Task<Void, Never>?
    private var knowledgeSaveTasks: [UUID: Task<Void, Never>] = [:]
    private var libraryRefreshTask: Task<Void, Never>?
    private var aiPreparationTask: Task<Void, Never>?
    private var aiDownloadStallTask: Task<Void, Never>?
    private var semanticAnalysisTask: Task<Void, Never>?
    private var requestedSemanticSourceIDs: [String] = []
    private var requestedPresentationSourceIDs: [String] = []
    private var requestedSummarySourceIDs: [String] = []
    private var automaticPresentationSourceIDs: [String] = []
    private var automaticSummarySourceIDs: [String] = []
    private var automaticSemanticSourceIDs: [String] = []
    private var knownPresentationSourceIDs = Set<String>()
    private var requestedThreadTitles: [ThreadTitleRequest] = []
    private var failedPresentationKeys = Set<String>()
    private var aiDownloadProgress = 0.0
    private var microphoneLevelUpdatedAt: Date?
    private var systemLevelUpdatedAt: Date?

    private static let selectedModelKey = "dropsift.builtInAI.selectedModel"
    private static let recommendationKey = "dropsift.builtInAI.recommendationHandled"
    private static let legacySelectedModelKey = "quill.builtInAI.selectedModel"
    private static let legacyRecommendationKey = "quill.builtInAI.recommendationHandled"
    private static let meetingDetectionKey = "dropsift.meetingDetection.enabled"
    private static let pendingModelDownloadKey = "dropsift.builtInAI.pendingModelDownload"
    private static let knownPresentationSourceIDsKey =
        "dropsift.presentation.knownSourceIDs"
    private static let automaticPresentationSourceIDsKey =
        "dropsift.presentation.pendingSourceIDs"
    private static let automaticSummarySourceIDsKey =
        "dropsift.summary.pendingSourceIDs"
    private static let automaticSemanticSourceIDsKey =
        "dropsift.semantics.pendingSourceIDs"
    private static let legacyDefaults = UserDefaults(suiteName: "com.digimata.quill")
    private static let audioLevelHistoryCount = 14
    private static var emptyAudioLevels: [Float] {
        Array(repeating: 0, count: audioLevelHistoryCount)
    }

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
        semanticStore = SharedSemanticStore(
            root: root.deletingLastPathComponent()
        )
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
        RecordingSession.clearStaleActiveMarkers(in: root)
        recordings = RecordingLibrary.load(from: root)
        knowledgeItems = KnowledgeLibrary.load(from: knowledgeRoot)
        tasks = semanticStore.loadTasks()
        entities = semanticStore.loadEntities()
        semanticReviews = semanticStore.loadPendingReviews()
        threads = chatStore.load().sorted { $0.updatedAt > $1.updatedAt }
        selectedRecordingID = recordings.first?.id
        selectedTaskID = tasks.first?.id
        selectedEntityID = entities.first?.id
        selectedTimelineItemID = nil
        selectedThreadID = threads.first?.id
        selectedTimelineItemID = timelineItems.first?.id
        restoreAutomaticProcessingQueues()
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
                        || item.listDescription.localizedCaseInsensitiveContains(query)
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
        case .downloading where aiDownloadIsStalled:
            false
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
                Task { @MainActor in model.applyAIState(state) }
            }
            await transcription.resumePending(root: root)
            let selectedModel = model.selectedModelPlan.model
            let selectedModelIsCached = BuiltInLLMEngine.hasCachedModel(
                selectedModel,
                in: Config.modelCacheRoot
            )
            let selectedModelIsPartial = BuiltInLLMEngine.hasPartialModel(
                selectedModel,
                in: Config.modelCacheRoot
            )
            let pendingModelID = UserDefaults.standard.string(
                forKey: Self.pendingModelDownloadKey
            )
            if selectedModelIsCached
                || selectedModelIsPartial
                || pendingModelID == selectedModel.id
            {
                await model.prepareBuiltInAI()
            }
            if model.shouldOfferModelRecommendation {
                model.showingModelRecommendation = true
            }
        }
        if meetingDetectionEnabled {
            Task { [meetingDetector] in
                await meetingDetector.start(
                    onDetected: { [weak self] meeting in
                        guard let self, self.meetingDetectionEnabled
                        else { return }
                        self.onMeetingDetected?(meeting)
                    },
                    onEnded: { [weak self] meeting in
                        guard let self, self.meetingDetectionEnabled
                        else { return }
                        self.onMeetingEnded?(meeting)
                    }
                )
            }
        }
        if libraryRefreshTask == nil {
            libraryRefreshTask = Task { [weak self, transcription, root] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(8))
                    guard let self, !Task.isCancelled else { return }
                    await transcription.resumePending(root: root)
                    self.refreshLibrary()
                }
            }
        }
        scanForSemanticCandidates()
    }

    func shutdown() {
        if isRecording {
            stopRecording()
        }
        isPreparingRecording = false
        Task { [meetingDetector] in await meetingDetector.stop() }
        libraryRefreshTask?.cancel()
        libraryRefreshTask = nil
        aiPreparationTask?.cancel()
        aiPreparationTask = nil
        aiDownloadStallTask?.cancel()
        aiDownloadStallTask = nil
        semanticAnalysisTask?.cancel()
        semanticAnalysisTask = nil
        semanticProcessingSourceID = nil
        semanticProcessingLabel = nil
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard !isRecording, !isPreparingRecording else { return }
        resetAudioLevels()
        do {
            try beginRecording()
        } catch {
            handleRecordingStartFailure(error)
        }
    }

    func resumeRecording(_ recording: RecordingItem) {
        guard !isRecording, !isPreparingRecording else { return }
        isPreparingRecording = true
        do {
            try beginRecording(resuming: recording)
        } catch {
            handleRecordingStartFailure(error)
        }
        isPreparingRecording = false
    }

    func stopRecording() {
        guard let session else { return }
        flushLiveRecordingTitle(to: session.dir)
        flushLiveNotes(to: session.dir)
        session.stop()
        let directory = session.dir
        self.session = nil
        liveRecordingTitle = ""
        liveNotes = ""
        recordingStartedAt = nil
        recordingElapsedBaseSeconds = 0
        recordingSessionID = nil
        ticker?.invalidate()
        ticker = nil
        isRecording = false
        recordingElapsed = "0:00"
        resetAudioLevels()
        onRecordingStateChange?(false, nil)
        reloadRecordings(selecting: directory.lastPathComponent)
        Task { [transcription] in await transcription.enqueue(directory) }
    }

    private func beginRecording(resuming recording: RecordingItem? = nil) throws {
        resetAudioLevels()
        let newSession: RecordingSession
        if let recording {
            newSession = try RecordingSession(resuming: recording) {
                [weak self] source, level in
                Task { @MainActor [weak self] in
                    self?.recordAudioLevel(level, from: source)
                }
            }
        } else {
            newSession = try RecordingSession(root: root) {
                [weak self] source, level in
                Task { @MainActor [weak self] in
                    self?.recordAudioLevel(level, from: source)
                }
            }
        }

        try newSession.start()
        session = newSession
        recordingStartedAt = newSession.startedAt
        recordingElapsedBaseSeconds = newSession.elapsedBaseSeconds
        recordingSessionID = newSession.dir.lastPathComponent
        liveRecordingTitle = recording?.title ?? ""
        liveNotes = recording?.notes ?? ""
        isRecording = true
        recordingElapsed = Self.clock(recordingElapsedBaseSeconds)
        if let recording {
            selectedRecordingID = recording.id
            selectedTimelineItemID = "recording:\(recording.id)"
            section = .timeline
        }
        onRecordingStateChange?(true, recordingElapsed)
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.tickRecording() }
        }
    }

    private func handleRecordingStartFailure(_ error: Error) {
        resetAudioLevels()
        appError = "Couldn’t start recording: \(error)"
        notifyUser(title: "Dropsift — recording failed", body: "\(error)")
    }

    func reloadRecordings(selecting recordingID: String? = nil) {
        recordings = RecordingLibrary.load(from: root)
        enqueueNewSourceProcessing()
        if let recordingID, recordings.contains(where: { $0.id == recordingID }) {
            selectedRecordingID = recordingID
            selectedTimelineItemID = "recording:\(recordingID)"
        } else if let selectedTimelineItemID,
                  selectedTimelineItemID.hasPrefix("recording:") {
            // Passive reloads update content only. In particular, do not
            // reinterpret an iCloud/transcription write that briefly hides a
            // directory as a request to navigate somewhere else.
            selectedRecordingID = String(selectedTimelineItemID.dropFirst(10))
        }
    }

    func refreshLibrary() {
        // Load the complete snapshot before publishing either collection.
        // Publishing half a snapshot used to make SwiftUI reconcile selection
        // against an intermediate timeline and write the previous row back.
        let selectionBeforeRefresh = selectedTimelineItemID
        let loadedRecordings = RecordingLibrary.load(from: root)
        let loadedKnowledge = KnowledgeLibrary.load(from: knowledgeRoot)
        recordings = loadedRecordings
        knowledgeItems = loadedKnowledge
        enqueueNewSourceProcessing()
        refreshSemantics()
        selectedTimelineItemID = Self.selectionAfterPassiveRefresh(
            current: selectionBeforeRefresh,
            availableIDs: timelineItems.map(\.id)
        )

        if let selectedTimelineItemID,
           selectedTimelineItemID.hasPrefix("recording:") {
            selectedRecordingID = String(selectedTimelineItemID.dropFirst(10))
        }
        scanForSemanticCandidates()
    }

    nonisolated static func selectionAfterPassiveRefresh(
        current: String?,
        availableIDs _: [String]
    ) -> String? {
        // Availability is content state, not navigation state. iCloud and
        // transcript writes can make an item temporarily unreadable; only a
        // user action or confirmed deletion may change selection.
        current
    }

    func renameSelectedRecording(to title: String) {
        guard let recording = selectedRecording else { return }
        do {
            try RecordingLibrary.saveTitle(title, for: recording)
            if isRecording, recordingSessionID == recording.id {
                liveRecordingTitle = title.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            }
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

    func updateLiveRecordingTitle(_ title: String) {
        liveRecordingTitle = title
        guard let directory = session?.dir else { return }

        titleSaveTask?.cancel()
        titleSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            guard !title.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else { return }
            do {
                try RecordingLibrary.saveTitle(title, to: directory)
            } catch {
                self?.appError = "Couldn’t save recording title: \(error.localizedDescription)"
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
                self?.reloadRecordings()
            } catch {
                self?.appError = "Couldn’t save recording notes: \(error.localizedDescription)"
            }
        }
    }

    func updateSpeakerNames(
        _ names: [String: String],
        recordingID: String
    ) {
        guard let recording = recordings.first(where: { $0.id == recordingID })
        else { return }
        do {
            try RecordingLibrary.saveSpeakerNames(names, for: recording)
            reloadRecordings(selecting: recordingID)
        } catch {
            appError = "Couldn’t save speaker names: \(error.localizedDescription)"
        }
    }

    func splitRecording(
        _ recording: RecordingItem,
        before segment: TranscriptDocument.Segment
    ) {
        guard splittingRecordingID == nil, !isRecording else { return }
        splittingRecordingID = recording.id
        Task { [weak self, transcription] in
            guard let self else { return }
            let canEdit = await transcription.prepareForExclusiveMutation(
                recording.directory
            )
            guard canEdit else {
                splittingRecordingID = nil
                appError = "This recording is still being transcribed. Wait for it to finish, then split it."
                return
            }
            do {
                let newItem = try await RecordingLibrary.splitTranscript(
                    recording,
                    at: segment.startMs
                )
                try? semanticStore.resetProcessing(
                    sourceID: "recording:\(recording.id)"
                )
                reloadRecordings(selecting: newItem.id)
                refreshSemantics()
                scanForSemanticCandidates()
            } catch {
                appError = "Couldn’t split this recording: "
                    + error.localizedDescription
            }
            splittingRecordingID = nil
        }
    }

    func createTask() {
        do {
            let task = try semanticStore.createTask()
            refreshSemantics()
            selectedTaskID = task.id
            section = .tasks
        } catch {
            appError = "Couldn’t create the task: \(error.localizedDescription)"
        }
    }

    func saveTask(_ task: SharedTask) {
        do {
            try semanticStore.saveTask(task)
            refreshSemantics()
            selectedTaskID = task.id
        } catch {
            appError = "Couldn’t save the task: \(error.localizedDescription)"
        }
    }

    func toggleTaskCompletion(_ task: SharedTask) {
        var updated = task
        updated.isCompleted.toggle()
        saveTask(updated)
    }

    func deleteTask(_ task: SharedTask) {
        do {
            try semanticStore.deleteTask(task.id)
            refreshSemantics()
            if selectedTaskID == task.id {
                selectedTaskID = tasks.first?.id
            }
        } catch {
            appError = "Couldn’t delete the task: \(error.localizedDescription)"
        }
    }

    func setTaskCompletion(_ taskIDs: Set<UUID>, completed: Bool) {
        do {
            for var task in tasks where taskIDs.contains(task.id) {
                task.isCompleted = completed
                try semanticStore.saveTask(task)
            }
            refreshSemantics()
        } catch {
            appError = "Couldn’t update the selected tasks: \(error.localizedDescription)"
        }
    }

    func deleteTasks(_ taskIDs: Set<UUID>) {
        do {
            for id in taskIDs {
                try semanticStore.deleteTask(id)
            }
            refreshSemantics()
        } catch {
            appError = "Couldn’t delete the selected tasks: \(error.localizedDescription)"
        }
    }

    func createEntity(kind: SharedSemanticEntityKind) {
        let entity = SharedSemanticEntity(
            kind: kind,
            name: "New \(kind.singularName.lowercased())"
        )
        do {
            try semanticStore.saveEntity(entity)
            refreshSemantics()
            selectedEntityID = entity.id
            section = Self.section(for: kind)
        } catch {
            appError = "Couldn’t create the \(kind.singularName.lowercased()): "
                + error.localizedDescription
        }
    }

    func saveEntity(_ entity: SharedSemanticEntity) {
        do {
            try semanticStore.saveEntity(entity)
            refreshSemantics()
            selectedEntityID = entity.id
        } catch {
            appError = "Couldn’t save this item: \(error.localizedDescription)"
        }
    }

    func deleteEntity(_ entity: SharedSemanticEntity) {
        do {
            try semanticStore.deleteEntity(entity.id)
            refreshSemantics()
            if selectedEntityID == entity.id {
                selectedEntityID = entities.first {
                    $0.kind == entity.kind
                }?.id
            }
        } catch {
            appError = "Couldn’t delete this item: \(error.localizedDescription)"
        }
    }

    func deleteEntities(_ entityIDs: Set<UUID>) {
        do {
            for id in entityIDs {
                try semanticStore.deleteEntity(id)
            }
            refreshSemantics()
        } catch {
            appError = "Couldn’t delete the selected items: \(error.localizedDescription)"
        }
    }

    func entities(of kind: SharedSemanticEntityKind) -> [SharedSemanticEntity] {
        entities.filter { $0.kind == kind }
    }

    func semanticReview(for sourceID: String) -> SharedSemanticReview? {
        semanticReviews.first { $0.sourceID == sourceID }
    }

    func requestSemanticExtraction(for sourceID: String) {
        guard semanticSources().contains(where: { $0.sourceID == sourceID })
        else {
            appError = "There isn’t enough text in this item to extract tasks or details yet."
            return
        }
        if !requestedSemanticSourceIDs.contains(sourceID) {
            requestedSemanticSourceIDs.append(sourceID)
        }
        automaticSemanticSourceIDs.removeAll { $0 == sourceID }
        persistAutomaticProcessingQueues()
        scanForSemanticCandidates()
    }

    func acceptSemanticReview(
        _ review: SharedSemanticReview,
        selectedCandidateIDs: Set<UUID>
    ) {
        do {
            try semanticStore.acceptReview(
                review,
                selectedCandidateIDs: selectedCandidateIDs
            )
            refreshSemantics()
        } catch {
            appError = "Couldn’t add these findings: \(error.localizedDescription)"
        }
    }

    func dismissSemanticReview(_ review: SharedSemanticReview) {
        do {
            try semanticStore.dismissReview(review)
            refreshSemantics()
        } catch {
            appError = "Couldn’t dismiss these findings: \(error.localizedDescription)"
        }
    }

    func openSemanticSource(_ source: SharedSemanticSourceReference) {
        section = .timeline
        selectTimelineItem(source.itemID)
        if source.itemID.hasPrefix("recording:"),
           let startMs = source.startMs {
            transcriptJump = TranscriptJump(
                recordingID: String(source.itemID.dropFirst(10)),
                startMs: startMs
            )
        } else if source.itemID.hasPrefix("knowledge:"),
                  let id = UUID(
                    uuidString: String(source.itemID.dropFirst(10))
                  ) {
            knowledgeJump = KnowledgeJump(itemID: id, page: source.page)
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
                await meetingDetector.start(
                    onDetected: { [weak self] meeting in
                        guard let self, self.meetingDetectionEnabled
                        else { return }
                        self.onMeetingDetected?(meeting)
                    },
                    onEnded: { [weak self] meeting in
                        guard let self, self.meetingDetectionEnabled
                        else { return }
                        self.onMeetingEnded?(meeting)
                    }
                )
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

    func regenerateThreadTitle(_ threadID: UUID) {
        guard threads.contains(where: { $0.id == threadID }) else { return }
        requestedThreadTitles.removeAll { $0.threadID == threadID }
        requestedThreadTitles.insert(
            ThreadTitleRequest(threadID: threadID, reportsErrors: true),
            at: 0
        )
        scanForSemanticCandidates()
    }

    func regeneratePresentation(for item: TimelineItem) {
        failedPresentationKeys = failedPresentationKeys.filter {
            !$0.hasPrefix(item.id + "|")
        }
        automaticPresentationSourceIDs.removeAll { $0 == item.id }
        persistAutomaticProcessingQueues()
        requestedPresentationSourceIDs.removeAll { $0 == item.id }
        requestedPresentationSourceIDs.insert(item.id, at: 0)
        scanForSemanticCandidates()
    }

    func regenerateSummary(for recording: RecordingItem) {
        let sourceID = "recording:\(recording.id)"
        automaticSummarySourceIDs.removeAll { $0 == sourceID }
        persistAutomaticProcessingQueues()
        requestedSummarySourceIDs.removeAll { $0 == sourceID }
        requestedSummarySourceIDs.insert(sourceID, at: 0)
        scanForSemanticCandidates()
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

    func requestDeleteThreads(_ ids: Set<UUID>) {
        let existing = ids.intersection(Set(threads.map(\.id)))
        guard !existing.isEmpty else { return }
        deletionRequest = .threads(ids: existing, count: existing.count)
    }

    func requestDeleteTimelineItems(_ ids: Set<String>) {
        let recordings = Set(
            self.recordings
                .filter { ids.contains("recording:\($0.id)") }
                .map(\.id)
        )
        let knowledge = Set(
            knowledgeItems
                .filter { ids.contains("knowledge:\($0.id.uuidString)") }
                .map(\.id)
        )
        let count = recordings.count + knowledge.count
        guard count > 0 else { return }
        if let activeID = recordingSessionID, recordings.contains(activeID) {
            appError = "Stop the active recording before moving it to Trash."
            return
        }
        deletionRequest = .timelineItems(
            recordingIDs: recordings,
            knowledgeIDs: knowledge,
            count: count
        )
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
        case .threads(let ids, _):
            deleteThreads(ids)
        case .timelineItems(let recordingIDs, let knowledgeIDs, _):
            moveTimelineItemsToTrash(
                recordingIDs: recordingIDs,
                knowledgeIDs: knowledgeIDs
            )
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
            var streamingResponseID: UUID?
            do {
                let retrieval = await Task.detached(priority: .userInitiated) {
                    let effectiveScope = TranscriptRetriever.resolvedScope(
                        query: retrievalQuery,
                        recordings: recordingsSnapshot,
                        requestedScope: scope
                    )
                    let transcripts = TranscriptRetriever.retrieve(
                        query: retrievalQuery,
                        recordings: recordingsSnapshot,
                        scope: effectiveScope,
                        limit: retrievalLimit,
                        characterBudget: retrievalCharacterBudget
                    )
                    let knowledge = effectiveScope.kind == .allRecordings
                        ? KnowledgeRetriever.retrieve(
                            query: retrievalQuery,
                            items: knowledgeSnapshot,
                            limit: retrievalLimit,
                            characterBudget: retrievalCharacterBudget
                        )
                        : []
                    let chunks = RetrievedContext.interleave(
                        transcripts: transcripts,
                        knowledge: knowledge,
                        limit: retrievalLimit,
                        characterBudget: retrievalCharacterBudget
                    )
                    return (chunks: chunks, scope: effectiveScope)
                }.value
                if retrieval.scope != scope,
                   let currentIndex = threads.firstIndex(where: { $0.id == threadID }),
                   threads[currentIndex].scope == scope {
                    threads[currentIndex].scope = retrieval.scope
                    threads[currentIndex].updatedAt = Date()
                    persistThreads()
                }
                chatStage = .preparingAI
                try await llm.prepare()
                chatStage = .generating
                let responseID = UUID()
                streamingResponseID = responseID
                guard let responseThreadIndex = threads.firstIndex(
                    where: { $0.id == threadID }
                ) else {
                    chatStage = .idle
                    return
                }
                threads[responseThreadIndex].messages.append(
                    ChatMessage(
                        id: responseID,
                        role: .assistant,
                        content: ""
                    )
                )

                let stream = try await llm.stream(
                    systemPrompt: Self.systemPrompt(
                        chunks: retrieval.chunks,
                        scope: retrieval.scope
                    ),
                    messages: conversation
                )
                var streamedAnswer = ""
                for try await chunk in stream {
                    streamedAnswer += chunk
                    guard let currentIndex = threads.firstIndex(
                        where: { $0.id == threadID }
                    ),
                    let messageIndex = threads[currentIndex].messages.firstIndex(
                        where: { $0.id == responseID }
                    ) else {
                        continue
                    }
                    threads[currentIndex].messages[messageIndex].content = streamedAnswer
                }

                let answer = BuiltInLLMEngine.clean(streamedAnswer)
                guard !answer.isEmpty else {
                    throw BuiltInLLMEngine.EngineError.emptyResponse
                }
                guard let currentIndex = threads.firstIndex(where: { $0.id == threadID }) else {
                    chatStage = .idle
                    return
                }
                guard let messageIndex = threads[currentIndex].messages.firstIndex(
                    where: { $0.id == responseID }
                ) else {
                    chatStage = .idle
                    return
                }
                threads[currentIndex].messages[messageIndex].content = answer
                threads[currentIndex].messages[messageIndex].sources = Self.citedSources(
                    answer: answer,
                    chunks: retrieval.chunks
                )
                let shouldGenerateConversationTitle = threads[currentIndex]
                    .messages
                    .filter { $0.role == .user }
                    .count == 1
                threads[currentIndex].updatedAt = Date()
                threads.sort { $0.updatedAt > $1.updatedAt }
                persistThreads()
                chatStage = .idle
                if shouldGenerateConversationTitle,
                   !requestedThreadTitles.contains(where: {
                       $0.threadID == threadID
                   }) {
                    requestedThreadTitles.append(
                        ThreadTitleRequest(
                            threadID: threadID,
                            reportsErrors: false
                        )
                    )
                }
                scanForSemanticCandidates()
            } catch {
                if let streamingResponseID,
                   let currentIndex = threads.firstIndex(where: { $0.id == threadID }),
                   let messageIndex = threads[currentIndex].messages.firstIndex(
                       where: { $0.id == streamingResponseID }
                   ) {
                    if threads[currentIndex].messages[messageIndex].content.isEmpty {
                        threads[currentIndex].messages.remove(at: messageIndex)
                    } else {
                        threads[currentIndex].updatedAt = Date()
                        persistThreads()
                    }
                }
                chatError = error.localizedDescription
                chatStage = .idle
                aiStatus = .failed(error.localizedDescription)
                scanForSemanticCandidates()
            }
        }
    }

    func prepareBuiltInAI() async {
        do {
            try await llm.prepare()
        } catch {
            let cocoaError = error as NSError
            guard !(error is CancellationError),
                  !(cocoaError.domain == NSURLErrorDomain
                    && cocoaError.code == NSURLErrorCancelled)
            else { return }
            aiStatus = .failed(error.localizedDescription)
        }
    }

    func downloadBuiltInAI() {
        beginBuiltInAIPreparation(restarting: false)
    }

    func restartBuiltInAIDownload() {
        beginBuiltInAIPreparation(restarting: true)
    }

    func cancelBuiltInAIDownload() {
        aiPreparationTask?.cancel()
        aiPreparationTask = nil
        aiDownloadStallTask?.cancel()
        aiDownloadStallTask = nil
        aiDownloadIsStalled = false
        UserDefaults.standard.removeObject(forKey: Self.pendingModelDownloadKey)
        Task { [llm] in
            await llm.cancelPreparation()
        }
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
        if downloadAndUse {
            UserDefaults.standard.set(
                model.id,
                forKey: Self.pendingModelDownloadKey
            )
        }
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

    private func beginBuiltInAIPreparation(restarting: Bool) {
        UserDefaults.standard.set(
            selectedModelPlan.model.id,
            forKey: Self.pendingModelDownloadKey
        )
        aiDownloadIsStalled = false
        aiDownloadStallTask?.cancel()
        aiDownloadStallTask = nil
        aiPreparationTask?.cancel()

        aiPreparationTask = Task { [weak self, llm] in
            if restarting {
                await llm.cancelPreparation()
            }
            guard let self, !Task.isCancelled else { return }
            await self.prepareBuiltInAI()
            self.aiPreparationTask = nil
        }
    }

    private func applyAIState(_ state: BuiltInAIState) {
        let priorProgress = aiDownloadProgress
        aiStatus = state

        switch state {
        case .downloading(let fraction):
            let madeProgress = fraction > priorProgress + 0.000_001
            aiDownloadProgress = max(aiDownloadProgress, fraction)
            if madeProgress || aiDownloadStallTask == nil {
                aiDownloadIsStalled = false
                scheduleDownloadStallCheck(progress: fraction)
            }
        case .ready:
            aiDownloadStallTask?.cancel()
            aiDownloadStallTask = nil
            aiDownloadIsStalled = false
            aiDownloadProgress = 1
            UserDefaults.standard.removeObject(
                forKey: Self.pendingModelDownloadKey
            )
            scanForSemanticCandidates()
        case .notDownloaded, .downloaded, .loading, .failed:
            aiDownloadStallTask?.cancel()
            aiDownloadStallTask = nil
            aiDownloadIsStalled = false
            if case .notDownloaded = state {
                aiDownloadProgress = 0
            }
        }
    }

    private func scheduleDownloadStallCheck(progress: Double) {
        aiDownloadStallTask?.cancel()
        aiDownloadStallTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, !Task.isCancelled else { return }
            guard case .downloading(let currentProgress) = self.aiStatus,
                  abs(currentProgress - progress) < 0.000_001
            else { return }

            self.aiDownloadIsStalled = true
            self.aiDownloadStallTask = nil
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

    func requestDeleteModel(_ model: BuiltInModel) {
        guard isModelCached(model) else { return }
        modelDeletionRequest = model
    }

    func cancelModelDeletion() {
        modelDeletionRequest = nil
    }

    func confirmModelDeletion(_ model: BuiltInModel) {
        modelDeletionRequest = nil
        let directory = BuiltInLLMEngine.modelCacheDirectory(
            for: model,
            in: Config.modelCacheRoot
        )
        guard FileManager.default.fileExists(atPath: directory.path) else {
            if model.id == selectedModelID {
                aiStatus = .notDownloaded
            }
            return
        }

        let deletingSelectedModel = model.id == selectedModelID
        if deletingSelectedModel {
            aiPreparationTask?.cancel()
            aiPreparationTask = nil
            aiDownloadStallTask?.cancel()
            aiDownloadStallTask = nil
            aiDownloadIsStalled = false
            UserDefaults.standard.removeObject(
                forKey: Self.pendingModelDownloadKey
            )
        }

        Task { [weak self, llm] in
            if deletingSelectedModel {
                await llm.unloadModel(model.id)
            }
            guard let self else { return }
            NSWorkspace.shared.recycle([directory]) { [weak self] _, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.appError =
                            "Couldn’t move \(model.name) to Trash: \(error.localizedDescription)"
                        if deletingSelectedModel {
                            self.aiStatus = .downloaded
                        }
                        return
                    }
                    if deletingSelectedModel {
                        self.aiStatus = .notDownloaded
                    }
                    self.objectWillChange.send()
                }
            }
        }
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
        enqueueNewSourceProcessing()
        if let itemID, knowledgeItems.contains(where: { $0.id == itemID }) {
            selectedTimelineItemID = "knowledge:\(itemID.uuidString)"
        }
        scanForSemanticCandidates()
    }

    private func refreshSemantics() {
        tasks = semanticStore.loadTasks()
        entities = semanticStore.loadEntities()
        semanticReviews = semanticStore.loadPendingReviews()
        if selectedTaskID == nil || !tasks.contains(where: { $0.id == selectedTaskID }) {
            selectedTaskID = tasks.first?.id
        }
        if let selectedEntityID,
           !entities.contains(where: { $0.id == selectedEntityID }) {
            self.selectedEntityID = nil
        }
    }

    private func scanForSemanticCandidates() {
        guard semanticAnalysisTask == nil, chatStage == .idle else { return }

        if let request = requestedThreadTitles.first {
            requestedThreadTitles.removeFirst()
            guard let thread = threads.first(where: {
                $0.id == request.threadID
            }), !thread.messages.isEmpty else {
                scanForSemanticCandidates()
                return
            }

            regeneratingThreadID = thread.id
            let engine = llm
            let conversation = Self.titlePrompt(for: thread)
            semanticAnalysisTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let response = try await engine.complete(
                        systemPrompt: ContentPresentationGenerator
                            .conversationTitleSystemPrompt,
                        messages: [
                            ChatMessage(role: .user, content: conversation),
                        ],
                        maxTokens: 128
                    )
                    try Task.checkCancellation()
                    guard let title = ContentPresentationGenerator.cleanTitle(
                        response
                    ) else {
                        throw CocoaError(.formatting)
                    }
                    if let index = threads.firstIndex(where: {
                        $0.id == request.threadID
                    }) {
                        threads[index].title = title
                        threads[index].updatedAt = Date()
                        persistThreads()
                    }
                } catch {
                    if request.reportsErrors, !(error is CancellationError) {
                        chatError = "Couldn’t generate a conversation title: "
                            + error.localizedDescription
                    }
                }
                regeneratingThreadID = nil
                semanticAnalysisTask = nil
                scanForSemanticCandidates()
            }
            return
        }

        let sources = semanticSources()
        let manuallyRequestedSource = requestedSemanticSourceIDs
            .compactMap { requestedID in
                sources.first { $0.sourceID == requestedID }
            }
            .first
        if let manuallyRequestedSource {
            requestedSemanticSourceIDs.removeAll {
                $0 == manuallyRequestedSource.sourceID
            }
            do {
                try semanticStore.resetProcessing(
                    sourceID: manuallyRequestedSource.sourceID
                )
                refreshSemantics()
            } catch {
                appError = "Couldn’t re-extract this item: "
                    + error.localizedDescription
                scanForSemanticCandidates()
                return
            }
        }
        let manuallyRequestedPresentation = requestedPresentationSourceIDs
            .compactMap { requestedID in
                sources.first { $0.sourceID == requestedID }
            }
            .first
        if let manuallyRequestedPresentation {
            requestedPresentationSourceIDs.removeAll {
                $0 == manuallyRequestedPresentation.sourceID
            }
        }
        let manuallyRequestedSummary = requestedSummarySourceIDs
            .compactMap { requestedID in
                sources.first {
                    $0.sourceID == requestedID
                        && $0.sourceID.hasPrefix("recording:")
                }
            }
            .first
        if let manuallyRequestedSummary {
            requestedSummarySourceIDs.removeAll {
                $0 == manuallyRequestedSummary.sourceID
            }
        }
        let pendingKeys = Set(
            semanticStore.loadPendingReviews().map {
                $0.sourceID + "|" + $0.sourceRevision
            }
        )
        removeCompletedAutomaticSemanticRequests(
            from: sources,
            pendingKeys: pendingKeys
        )
        let automaticSemanticSource = automaticSemanticSourceIDs.compactMap {
            requestedID in
            sources.first { source in
                source.sourceID == requestedID
                    && !source.text.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                    && !semanticStore.isProcessed(
                        sourceID: source.sourceID,
                        revision: source.revision
                    )
                    && !pendingKeys.contains(
                        source.sourceID + "|" + source.revision
                    )
            }
        }.first
        let semanticSource = manuallyRequestedSource
            ?? automaticSemanticSource
        let modelIsCached = BuiltInLLMEngine.hasCachedModel(
            selectedModelPlan.model,
            in: Config.modelCacheRoot
        )
        removeCompletedAutomaticPresentationRequests(from: sources)
        removeCompletedAutomaticSummaryRequests(from: sources)
        let automaticPresentationSource = modelIsCached
            ? automaticPresentationSourceIDs.compactMap { requestedID in
                sources.first { source in
                    source.sourceID == requestedID
                        && !source.text.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                        && !failedPresentationKeys.contains(
                            source.sourceID + "|" + source.presentationRevision
                        )
                        && !ContentPresentationStore.isCurrent(
                            in: source.directory,
                            revision: source.presentationRevision
                        )
                }
            }.first
            : nil
        let automaticSummarySource = modelIsCached
            ? automaticSummarySourceIDs.compactMap { requestedID in
                sources.first { source in
                    source.sourceID == requestedID
                        && source.sourceID.hasPrefix("recording:")
                        && !source.text.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                        && !RecordingSummaryStore.isCurrent(
                            in: source.directory,
                            revision: source.presentationRevision
                        )
                }
            }.first
            : nil
        let source = manuallyRequestedPresentation
            ?? manuallyRequestedSummary
            ?? manuallyRequestedSource
            ?? automaticPresentationSource
            ?? automaticSummarySource
            ?? semanticSource
        guard let source else {
            refreshSemantics()
            return
        }

        let presentationWasRequested = manuallyRequestedPresentation?.sourceID
            == source.sourceID
        let presentationWasQueued = automaticPresentationSource?.sourceID
            == source.sourceID
        let summaryWasRequested = manuallyRequestedSummary?.sourceID
            == source.sourceID
        let summaryWasQueued = automaticSummarySource?.sourceID
            == source.sourceID
        let semanticsWereQueued = automaticSemanticSource?.sourceID
            == source.sourceID
        let needsPresentation = presentationWasRequested
            || presentationWasQueued
        let needsSummary = summaryWasRequested || summaryWasQueued
        let needsSemantics = semanticSource?.sourceID == source.sourceID
        semanticProcessingLabel = if needsPresentation {
            "Writing title and description for \(source.title)…"
        } else if needsSummary {
            "Summarizing \(source.title)…"
        } else {
            "Organizing \(source.title)…"
        }
        semanticProcessingSourceID = source.sourceID
        metadataGenerationItemID = needsPresentation ? source.sourceID : nil
        summaryGenerationItemID = needsSummary ? source.sourceID : nil
        let store = semanticStore
        let engine = llm
        let modelName = selectedModelPlan.model.name
        semanticAnalysisTask = Task { [weak self] in
            guard let self else { return }
            var presentationSaved = false
            if needsPresentation {
                do {
                    let response = try await engine.complete(
                        systemPrompt: ContentPresentationGenerator.systemPrompt,
                        messages: [
                            ChatMessage(
                                role: .user,
                                content: ContentPresentationGenerator.userPrompt(
                                    kind: source.presentationKind,
                                    currentTitle: source.title,
                                    text: source.text,
                                )
                            ),
                        ],
                        maxTokens: 512
                    )
                    try Task.checkCancellation()
                    guard let presentation = ContentPresentationGenerator.parse(
                        response,
                        sourceRevision: source.presentationRevision,
                        model: modelName
                    ) else {
                        throw LocalModelOutputError.unreadableStructuredResponse
                    }
                    if source.sourceID.hasPrefix("recording:") {
                        try RecordingLibrary.saveGeneratedPresentation(
                            presentation,
                            in: source.directory,
                            replacingManualTitle: presentationWasRequested
                        )
                    } else {
                        try KnowledgeLibrary.saveGeneratedPresentation(
                            presentation,
                            in: source.directory,
                            replacingManualTitle: presentationWasRequested
                        )
                    }
                    presentationSaved = true
                } catch {
                    failedPresentationKeys.insert(
                        source.sourceID + "|" + source.presentationRevision
                    )
                    if presentationWasRequested, !(error is CancellationError) {
                        appError = "Couldn’t generate this item’s title and description: "
                            + error.localizedDescription
                    }
                }
            }

            var summarySaved = false
            if needsSummary, !Task.isCancelled {
                do {
                    let response = try await engine.complete(
                        systemPrompt: RecordingSummaryGenerator.systemPrompt,
                        messages: [
                            ChatMessage(
                                role: .user,
                                content: RecordingSummaryGenerator.userPrompt(
                                    text: source.text,
                                    detectedSpeakers: source.speakerLabels,
                                    characterLimit: min(
                                        240_000,
                                        max(
                                            32_000,
                                            selectedModelPlan.contextTokens - 8_192
                                        )
                                    )
                                )
                            ),
                        ],
                        maxTokens: 1_536
                    )
                    try Task.checkCancellation()
                    guard let summary = RecordingSummaryGenerator.parse(
                        response,
                        detectedSpeakers: source.speakerLabels,
                        sourceRevision: source.presentationRevision,
                        model: modelName
                    ) else {
                        throw LocalModelOutputError.unreadableStructuredResponse
                    }
                    try RecordingSummaryStore.save(
                        summary,
                        to: source.directory
                    )
                    summarySaved = true
                } catch {
                    if summaryWasRequested, !(error is CancellationError) {
                        appError = "Couldn’t generate this recording’s summary: "
                            + error.localizedDescription
                    }
                }
            }

            if needsSemantics, !Task.isCancelled {
                var candidates: [SharedSemanticCandidate] = []
                if modelIsCached {
                    do {
                        let response = try await engine.complete(
                            systemPrompt: SharedSemanticExtraction.systemPrompt,
                            messages: [
                                ChatMessage(
                                    role: .user,
                                    content: SharedSemanticExtraction.userPrompt(
                                        text: source.text,
                                        sourceTitle: source.title
                                    )
                                ),
                            ]
                        )
                        candidates = SharedSemanticExtraction.parse(
                            response,
                            source: source.reference
                        )
                    } catch {
                        candidates = []
                    }
                }
                if candidates.isEmpty {
                    candidates = SharedSemanticExtraction.heuristicCandidates(
                        in: source.text,
                        source: source.reference
                    )
                }
                let review = SharedSemanticReview(
                    sourceID: source.sourceID,
                    sourceRevision: source.revision,
                    sourceTitle: source.title,
                    source: source.reference,
                    candidates: candidates
                )
                do {
                    _ = try store.enqueueReview(review)
                } catch {
                    self.appError = "Couldn’t save extracted findings: "
                        + error.localizedDescription
                }
            }
            self.semanticProcessingLabel = nil
            self.semanticProcessingSourceID = nil
            self.metadataGenerationItemID = nil
            self.summaryGenerationItemID = nil
            self.semanticAnalysisTask = nil
            if presentationWasQueued {
                self.automaticPresentationSourceIDs.removeAll {
                    $0 == source.sourceID
                }
            }
            if semanticsWereQueued {
                self.automaticSemanticSourceIDs.removeAll {
                    $0 == source.sourceID
                }
            }
            if summaryWasQueued,
               self.semanticSources().first(where: {
                   $0.sourceID == source.sourceID
               })?.presentationRevision == source.presentationRevision {
                self.automaticSummarySourceIDs.removeAll {
                    $0 == source.sourceID
                }
            }
            if presentationWasQueued || summaryWasQueued || semanticsWereQueued {
                self.persistAutomaticProcessingQueues()
            }
            if presentationSaved || summarySaved {
                self.refreshLibrary()
            }
            self.refreshSemantics()
            self.scanForSemanticCandidates()
        }
    }

    private func semanticSources() -> [SemanticSourceContent] {
        let recordingSources = recordings.compactMap {
            recording -> SemanticSourceContent? in
            let transcript = recording.transcript
            let text = (transcript?.segments ?? []).map {
                "\(recording.speakerName(for: $0.speaker)): \($0.text)"
            }
            .joined(separator: "\n")
            let notes = recording.notes.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let combined = notes.isEmpty
                ? text
                : "Notes:\n\(notes)\n\nTranscript:\n\(text)"
            let rawTranscript = (transcript?.segments ?? [])
                .map(\.text)
                .joined(separator: "\n")
            let presentationText = notes.isEmpty
                ? rawTranscript
                : "Notes:\n\(notes)\n\nTranscript:\n\(rawTranscript)"
            let presentationRevision = ContentPresentationStore.revision(
                for: presentationText
            )
            guard !combined.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else { return nil }
            let first = transcript?.segments.first
            let speakerLabels = Array(
                Set((transcript?.segments ?? []).map {
                    recording.speakerName(for: $0.speaker)
                })
            ).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let itemID = "recording:\(recording.id)"
            return SemanticSourceContent(
                sourceID: itemID,
                revision: presentationRevision,
                title: recording.title,
                text: combined,
                presentationRevision: presentationRevision,
                presentationKind: "recording or meeting transcript",
                directory: recording.directory,
                speakerLabels: speakerLabels,
                reference: SharedSemanticSourceReference(
                    itemID: itemID,
                    title: recording.title,
                    locator: first.map {
                        "Transcript · \(TranscriptDocument.clock($0.startMs))"
                    } ?? "Transcript",
                    excerpt: first?.text ?? recording.preview,
                    startMs: first?.startMs
                )
            )
        }
        let knowledgeSources = knowledgeItems.map {
            item -> SemanticSourceContent in
            let primary = item.kind == .note ? item.content : item.extractedText
            let notes = item.additionalNotes.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let text = notes.isEmpty
                ? primary
                : "\(primary)\n\nAdditional notes:\n\(notes)"
            let presentationText = item.kind == .note
                ? [item.content, item.additionalNotes].joined(separator: "\n\n")
                : ([item.additionalNotes] + item.blocks.map(\.text))
                    .joined(separator: "\n\n")
            let presentationRevision = ContentPresentationStore.revision(
                for: presentationText
            )
            let itemID = "knowledge:\(item.id.uuidString)"
            return SemanticSourceContent(
                sourceID: itemID,
                revision: presentationRevision,
                title: item.title,
                text: text,
                presentationRevision: presentationRevision,
                presentationKind: item.kind.displayName.lowercased(),
                directory: item.directory,
                speakerLabels: [],
                reference: SharedSemanticSourceReference(
                    itemID: itemID,
                    title: item.title,
                    locator: item.blocks.first?.locator
                        ?? (item.kind == .note ? "Note" : item.kind.displayName),
                    excerpt: item.blocks.first?.text ?? item.preview,
                    page: item.blocks.first?.page
                )
            )
        }
        return recordingSources + knowledgeSources
    }

    private func restoreAutomaticProcessingQueues() {
        let defaults = UserDefaults.standard
        let currentIDs = Set(timelineItems.map(\.id))
        let storedKnownIDs = defaults.stringArray(
            forKey: Self.knownPresentationSourceIDsKey
        )
        let storedPendingIDs = defaults.stringArray(
            forKey: Self.automaticPresentationSourceIDsKey
        ) ?? []
        let storedSemanticIDs = defaults.stringArray(
            forKey: Self.automaticSemanticSourceIDsKey
        ) ?? []
        let storedSummaryIDs = defaults.stringArray(
            forKey: Self.automaticSummarySourceIDsKey
        ) ?? []
        let previouslyKnown = storedKnownIDs.map(Set.init)
        let newIDs = Self.newPresentationSourceIDs(
            current: currentIDs,
            previouslyKnown: previouslyKnown
        )

        if let previouslyKnown {
            knownPresentationSourceIDs = previouslyKnown
        } else {
            // The first launch after this behavior ships establishes a
            // baseline. Historical libraries are never silently backfilled.
            knownPresentationSourceIDs = currentIDs
        }
        automaticPresentationSourceIDs = Self.mergedSourceIDs(
            storedPendingIDs,
            Array(newIDs)
        )
        automaticSemanticSourceIDs = Self.mergedSourceIDs(
            storedSemanticIDs,
            Array(newIDs)
        )
        automaticSummarySourceIDs = Self.mergedSourceIDs(
            storedSummaryIDs,
            Array(newIDs.filter { $0.hasPrefix("recording:") })
        )
        knownPresentationSourceIDs.formUnion(currentIDs)
        persistAutomaticProcessingQueues()
    }

    private func enqueueNewSourceProcessing() {
        let currentIDs = Set(timelineItems.map(\.id))
        let newIDs = Self.newPresentationSourceIDs(
            current: currentIDs,
            previouslyKnown: knownPresentationSourceIDs
        )
        guard !newIDs.isEmpty else { return }
        automaticPresentationSourceIDs = Self.mergedSourceIDs(
            automaticPresentationSourceIDs,
            timelineItems.map(\.id).filter { newIDs.contains($0) }
        )
        automaticSemanticSourceIDs = Self.mergedSourceIDs(
            automaticSemanticSourceIDs,
            timelineItems.map(\.id).filter { newIDs.contains($0) }
        )
        automaticSummarySourceIDs = Self.mergedSourceIDs(
            automaticSummarySourceIDs,
            timelineItems.map(\.id).filter {
                newIDs.contains($0) && $0.hasPrefix("recording:")
            }
        )
        knownPresentationSourceIDs.formUnion(currentIDs)
        persistAutomaticProcessingQueues()
    }

    private func removeCompletedAutomaticPresentationRequests(
        from sources: [SemanticSourceContent]
    ) {
        let completedIDs = Set<String>(sources.compactMap { source -> String? in
            ContentPresentationStore.isCurrent(
                in: source.directory,
                revision: source.presentationRevision
            ) ? source.sourceID : nil
        })
        guard automaticPresentationSourceIDs.contains(where: {
            completedIDs.contains($0)
        }) else { return }
        automaticPresentationSourceIDs.removeAll { completedIDs.contains($0) }
        persistAutomaticProcessingQueues()
    }

    private func removeCompletedAutomaticSummaryRequests(
        from sources: [SemanticSourceContent]
    ) {
        let completedIDs = Set<String>(sources.compactMap {
            source -> String? in
            guard source.sourceID.hasPrefix("recording:") else { return nil }
            return RecordingSummaryStore.isCurrent(
                in: source.directory,
                revision: source.presentationRevision
            ) ? source.sourceID : nil
        })
        guard automaticSummarySourceIDs.contains(where: {
            completedIDs.contains($0)
        }) else { return }
        automaticSummarySourceIDs.removeAll { completedIDs.contains($0) }
        persistAutomaticProcessingQueues()
    }

    private func removeCompletedAutomaticSemanticRequests(
        from sources: [SemanticSourceContent],
        pendingKeys: Set<String>
    ) {
        let completedIDs = Set(sources.compactMap { source in
            let isComplete = semanticStore.isProcessed(
                sourceID: source.sourceID,
                revision: source.revision
            ) || pendingKeys.contains(source.sourceID + "|" + source.revision)
            return isComplete ? source.sourceID : nil
        })
        guard automaticSemanticSourceIDs.contains(where: {
            completedIDs.contains($0)
        }) else { return }
        automaticSemanticSourceIDs.removeAll { completedIDs.contains($0) }
        persistAutomaticProcessingQueues()
    }

    private func persistAutomaticProcessingQueues() {
        let defaults = UserDefaults.standard
        defaults.set(
            knownPresentationSourceIDs.sorted(),
            forKey: Self.knownPresentationSourceIDsKey
        )
        defaults.set(
            automaticPresentationSourceIDs,
            forKey: Self.automaticPresentationSourceIDsKey
        )
        defaults.set(
            automaticSemanticSourceIDs,
            forKey: Self.automaticSemanticSourceIDsKey
        )
        defaults.set(
            automaticSummarySourceIDs,
            forKey: Self.automaticSummarySourceIDsKey
        )
    }

    nonisolated static func newPresentationSourceIDs(
        current: Set<String>,
        previouslyKnown: Set<String>?
    ) -> Set<String> {
        guard let previouslyKnown else { return [] }
        return current.subtracting(previouslyKnown)
    }

    nonisolated private static func mergedSourceIDs(
        _ first: [String],
        _ second: [String]
    ) -> [String] {
        var seen = Set<String>()
        return (first + second).filter { seen.insert($0).inserted }
    }

    private static func section(
        for kind: SharedSemanticEntityKind
    ) -> Section {
        switch kind {
        case .person: .people
        case .place: .places
        case .event: .events
        case .organization: .organizations
        case .project: .projects
        case .topic: .topics
        }
    }

    nonisolated private static func stableTextSignature(
        _ value: String
    ) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
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
                self?.reloadKnowledge()
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

    private func deleteThreads(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let selectedWasDeleted = selectedThreadID.map(ids.contains) ?? false
        threads.removeAll { ids.contains($0.id) }
        if selectedWasDeleted {
            selectedThreadID = threads.first?.id
            chatDraft = ""
            chatError = nil
        }
        persistThreads()
    }

    private func moveTimelineItemsToTrash(
        recordingIDs: Set<String>,
        knowledgeIDs: Set<UUID>
    ) {
        let recordingURLs = recordings
            .filter { recordingIDs.contains($0.id) }
            .map(\.directory)
        let knowledgeURLs = knowledgeItems
            .filter { knowledgeIDs.contains($0.id) }
            .map(\.directory)
        let urls = recordingURLs + knowledgeURLs
        guard !urls.isEmpty else { return }

        NSWorkspace.shared.recycle(urls) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.appError = "Couldn’t move the selected items to Trash: \(error.localizedDescription)"
                    return
                }

                for index in self.threads.indices
                where self.threads[index].scope.recordingID.map(
                    recordingIDs.contains
                ) == true {
                    self.threads[index].scope = .all
                    self.threads[index].updatedAt = Date()
                }
                self.persistThreads()
                self.refreshLibrary()
                let selectedWasDeleted = self.selectedTimelineItemID.map { selected in
                    if selected.hasPrefix("recording:") {
                        return recordingIDs.contains(String(selected.dropFirst(10)))
                    }
                    if selected.hasPrefix("knowledge:") {
                        return UUID(uuidString: String(selected.dropFirst(10)))
                            .map(knowledgeIDs.contains) ?? false
                    }
                    return false
                } ?? false
                if selectedWasDeleted {
                    self.selectedTimelineItemID = self.timelineItems.first?.id
                    self.selectTimelineItem(self.selectedTimelineItemID)
                }
            }
        }
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

    private func flushLiveRecordingTitle(to directory: URL) {
        titleSaveTask?.cancel()
        titleSaveTask = nil
        guard !liveRecordingTitle.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else { return }
        do {
            try RecordingLibrary.saveTitle(liveRecordingTitle, to: directory)
        } catch {
            appError = "Couldn’t save recording title: \(error.localizedDescription)"
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
        case .completed(let session):
            transcriptionStatus = "Transcript ready · \(session)"
            reloadRecordings()
            scheduleSummaryAfterTranscription(recordingID: session)
        case .failed(let session):
            transcriptionStatus = "Transcription failed · \(session)"
            reloadRecordings()
        }
        onTranscriptionStateChange?(transcriptionStatus)
    }

    private func scheduleSummaryAfterTranscription(recordingID: String) {
        let sourceID = "recording:\(recordingID)"
        if summaryGenerationItemID == sourceID {
            semanticAnalysisTask?.cancel()
        }
        automaticSummarySourceIDs = Self.summaryQueueAfterTranscription(
            automaticSummarySourceIDs,
            recordingID: recordingID
        )
        persistAutomaticProcessingQueues()
        scanForSemanticCandidates()
    }

    nonisolated static func summaryQueueAfterTranscription(
        _ existing: [String],
        recordingID: String
    ) -> [String] {
        mergedSourceIDs(existing, ["recording:\(recordingID)"])
    }

    private func tickRecording() {
        guard let recordingStartedAt else { return }
        let seconds = recordingElapsedBaseSeconds
            + Int(Date().timeIntervalSince(recordingStartedAt))
        recordingElapsed = Self.clock(seconds)
        clearStaleAudioLevels()
        onRecordingStateChange?(true, recordingElapsed)
    }

    private func recordAudioLevel(
        _ level: Float,
        from source: RecordingSession.AudioSource
    ) {
        guard isRecording else { return }
        let normalized = min(max(level, 0), 1)
        switch source {
        case .microphone:
            microphoneLevelUpdatedAt = Date()
            microphoneAudioLevels = appending(
                normalized,
                to: microphoneAudioLevels
            )
        case .system:
            systemLevelUpdatedAt = Date()
            systemAudioLevels = appending(normalized, to: systemAudioLevels)
        }
    }

    private func resetAudioLevels() {
        microphoneAudioLevels = Self.emptyAudioLevels
        systemAudioLevels = Self.emptyAudioLevels
        microphoneLevelUpdatedAt = nil
        systemLevelUpdatedAt = nil
    }

    private func appending(_ level: Float, to history: [Float]) -> [Float] {
        Array((history + [level]).suffix(Self.audioLevelHistoryCount))
    }

    private func clearStaleAudioLevels() {
        let cutoff = Date().addingTimeInterval(-0.6)
        if microphoneLevelUpdatedAt.map({ $0 < cutoff }) ?? true {
            microphoneAudioLevels = Self.emptyAudioLevels
        }
        if systemLevelUpdatedAt.map({ $0 < cutoff }) ?? true {
            systemAudioLevels = Self.emptyAudioLevels
        }
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

    private static func titlePrompt(for thread: ChatThread) -> String {
        let transcript = thread.messages.suffix(12).map { message in
            let role = message.role == .user ? "USER" : "DROPSIFT"
            return "\(role): \(message.content)"
        }
        .joined(separator: "\n\n")
        return String(transcript.prefix(16_000))
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
