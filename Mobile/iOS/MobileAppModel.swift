import AVFoundation
import Combine
import DropsiftShared
import Foundation

@MainActor
final class MobileAppModel: ObservableObject {
    struct TimelineNavigationRequest: Equatable {
        let itemID: String?
        let token = UUID()
    }

    enum RecordingDestination: Equatable {
        case newRecording
        case append(recordingID: String, offsetMs: Int)
    }

    @Published var selectedTab: MobileTab = .capture
    @Published private(set) var snapshot = SharedLibrarySnapshot(
        knowledgeItems: [],
        recordings: []
    )
    @Published var selectedKinds = Set(SharedTimelineKind.allCases)
    @Published var timelineSearch = ""
    @Published var selectedTimelineItemID: String?
    @Published private(set) var timelineNavigationRequest: TimelineNavigationRequest?
    @Published private(set) var selectedSource: SharedSearchResult?
    @Published var importState: MobileImportState = .idle
    @Published var errorMessage: String?
    @Published var chatDraft = ""
    @Published private(set) var chatMessages: [MobileChatMessage] = []
    @Published private(set) var isAnswering = false
    @Published private(set) var selectedAnswerModel: MobileAnswerModel
    @Published private(set) var recordingDestination: RecordingDestination?
    @Published private(set) var semanticReviews: [SharedSemanticReview] = []
    @Published private(set) var semanticProcessingLabel: String?
    @Published private(set) var semanticProcessingSourceID: String?

    let locator = MobileLibraryLocator()
    let recorder = VoiceRecorder()
    let watchBridge = PhoneWatchBridge()

    private static let selectedAnswerModelKey = "Dropsift.selectedMobileAnswerModel"
    private var cancellables: Set<AnyCancellable> = []
    private var refreshTask: Task<Void, Never>?
    private var semanticAnalysisTask: Task<Void, Never>?
    private var requestedSemanticSourceIDs: [String] = []
    private var processingWatchInbox = false

    init() {
        selectedAnswerModel = UserDefaults.standard
            .string(forKey: Self.selectedAnswerModelKey)
            .flatMap(MobileAnswerModel.init(rawValue:))
            ?? .automatic
        recorder.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        locator.$rootURL
            .dropFirst()
            .sink { [weak self] _ in
                self?.navigateToTimelineItem(nil)
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

    var tasks: [SharedTask] {
        snapshot.tasks
    }

    var entities: [SharedSemanticEntity] {
        snapshot.entities
    }

    var resolvedAnswerModel: MobileAnswerModel {
        MobileAnswerService.resolvedModel(for: selectedAnswerModel)
    }

    var answerModelLabel: String {
        if selectedAnswerModel == .automatic {
            return "Automatic · \(resolvedAnswerModel.name)"
        }
        return resolvedAnswerModel.name
    }

    var answerModelDetail: String {
        switch resolvedAnswerModel {
        case .appleIntelligence:
            "Apple’s on-device system language model"
        case .localSearch:
            "Private retrieval only · no generative LLM"
        case .automatic:
            selectedAnswerModel.detail
        }
    }

    func isAnswerModelAvailable(_ model: MobileAnswerModel) -> Bool {
        model != .appleIntelligence
            || MobileAnswerService.isAppleIntelligenceAvailable
    }

    func selectAnswerModel(_ model: MobileAnswerModel) {
        guard isAnswerModelAvailable(model) else {
            errorMessage = MobileAnswerService.AnswerError
                .appleIntelligenceUnavailable.localizedDescription
            return
        }
        selectedAnswerModel = model
        UserDefaults.standard.set(
            model.rawValue,
            forKey: Self.selectedAnswerModelKey
        )
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
        semanticAnalysisTask?.cancel()
        semanticAnalysisTask = nil
        semanticProcessingLabel = nil
        semanticProcessingSourceID = nil
    }

    func reload() {
        let root = locator.rootURL
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) {
                SharedLibraryStore(root: root).loadSnapshot()
            }.value
            guard let self else { return }
            snapshot = loaded
            semanticReviews = SharedSemanticStore(root: root)
                .loadPendingReviews()
            scanForSemanticCandidates()
            // A recording can be briefly absent while another process writes
            // its transcript or metadata. A refresh must never turn that
            // transient state into a navigation decision.
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
            finishRecording()
        } else {
            beginRecording(.newRecording)
        }
    }

    func toggleResume(_ recording: SharedRecordingItem) {
        let destination = RecordingDestination.append(
            recordingID: recording.id,
            offsetMs: recording.durationSeconds * 1_000
        )
        if recorder.isRecording {
            guard recordingDestination == destination else {
                errorMessage =
                    "Another voice recording is already in progress. Stop it before resuming this one."
                return
            }
            finishRecording()
        } else {
            beginRecording(destination)
        }
    }

    func isResuming(_ recordingID: String) -> Bool {
        guard case .append(let activeID, _) = recordingDestination else {
            return false
        }
        return activeID == recordingID && recorder.isRecording
    }

    func canResume(_ recordingID: String) -> Bool {
        !recorder.isRecording || isResuming(recordingID)
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
                self?.reload()
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
                self?.reload()
            } catch {
                self?.errorMessage = "Couldn’t save recording notes: \(error.localizedDescription)"
            }
        }
    }

    func updateSpeakerNames(
        _ names: [String: String],
        recordingID: String
    ) {
        let root = locator.rootURL
        Task { [weak self] in
            do {
                try await Task.detached(priority: .utility) {
                    try SharedLibraryStore(root: root).updateSpeakerNames(
                        names,
                        recordingID: recordingID
                    )
                }.value
                self?.reload()
            } catch {
                self?.errorMessage = "Couldn’t save speaker names: \(error.localizedDescription)"
            }
        }
    }

    func delete(_ item: SharedTimelineItem) {
        do {
            if selectedTimelineItemID == item.id {
                selectedTimelineItemID = nil
            }
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

    func createTask() {
        let store = SharedSemanticStore(root: locator.rootURL)
        do {
            _ = try store.createTask()
            reload()
            selectedTab = .organize
        } catch {
            errorMessage = "Couldn’t create the task: \(error.localizedDescription)"
        }
    }

    func saveTask(_ task: SharedTask) {
        do {
            try SharedSemanticStore(root: locator.rootURL).saveTask(task)
            reload()
        } catch {
            errorMessage = "Couldn’t save the task: \(error.localizedDescription)"
        }
    }

    func toggleTaskCompletion(_ task: SharedTask) {
        var updated = task
        updated.isCompleted.toggle()
        saveTask(updated)
    }

    func deleteTask(_ task: SharedTask) {
        do {
            try SharedSemanticStore(root: locator.rootURL).deleteTask(task.id)
            reload()
        } catch {
            errorMessage = "Couldn’t delete the task: \(error.localizedDescription)"
        }
    }

    func createEntity(kind: SharedSemanticEntityKind) {
        let entity = SharedSemanticEntity(
            kind: kind,
            name: "New \(kind.singularName.lowercased())"
        )
        do {
            try SharedSemanticStore(root: locator.rootURL).saveEntity(entity)
            reload()
        } catch {
            errorMessage = "Couldn’t create this item: \(error.localizedDescription)"
        }
    }

    func saveEntity(_ entity: SharedSemanticEntity) {
        do {
            try SharedSemanticStore(root: locator.rootURL).saveEntity(entity)
            reload()
        } catch {
            errorMessage = "Couldn’t save this item: \(error.localizedDescription)"
        }
    }

    func deleteEntity(_ entity: SharedSemanticEntity) {
        do {
            try SharedSemanticStore(root: locator.rootURL).deleteEntity(entity.id)
            reload()
        } catch {
            errorMessage = "Couldn’t delete this item: \(error.localizedDescription)"
        }
    }

    func semanticReview(for sourceID: String) -> SharedSemanticReview? {
        semanticReviews.first { $0.sourceID == sourceID }
    }

    func requestSemanticExtraction(for sourceID: String) {
        guard semanticSources().contains(where: { $0.sourceID == sourceID })
        else {
            errorMessage = "There isn’t enough text in this item to extract tasks or details yet."
            return
        }
        if !requestedSemanticSourceIDs.contains(sourceID) {
            requestedSemanticSourceIDs.append(sourceID)
        }
        scanForSemanticCandidates()
    }

    func acceptSemanticReview(
        _ review: SharedSemanticReview,
        selectedCandidateIDs: Set<UUID>
    ) {
        do {
            try SharedSemanticStore(root: locator.rootURL).acceptReview(
                review,
                selectedCandidateIDs: selectedCandidateIDs
            )
            reload()
        } catch {
            errorMessage = "Couldn’t add these findings: \(error.localizedDescription)"
        }
    }

    func dismissSemanticReview(_ review: SharedSemanticReview) {
        do {
            try SharedSemanticStore(root: locator.rootURL).dismissReview(review)
            reload()
        } catch {
            errorMessage = "Couldn’t dismiss these findings: \(error.localizedDescription)"
        }
    }

    func openSemanticSource(_ source: SharedSemanticSourceReference) {
        if source.itemID.hasPrefix("recording:") {
            selectedSource = SharedSearchResult(
                id: source.id,
                itemID: source.itemID,
                title: source.title,
                kind: .recording,
                locator: source.locator,
                text: source.excerpt,
                score: 1,
                startMs: source.startMs
            )
        } else if source.itemID.hasPrefix("knowledge:") {
            let kind: SharedTimelineKind = snapshot.knowledgeItems.first {
                "knowledge:\($0.id.uuidString)" == source.itemID
            }.map {
                switch $0.kind {
                case .note: SharedTimelineKind.note
                case .document: SharedTimelineKind.document
                case .image: SharedTimelineKind.image
                }
            } ?? SharedTimelineKind.document
            selectedSource = SharedSearchResult(
                id: source.id,
                itemID: source.itemID,
                title: source.title,
                kind: kind,
                locator: source.locator,
                text: source.excerpt,
                score: 1,
                page: source.page
            )
        }
        navigateToTimelineItem(source.itemID)
        selectedTab = .timeline
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
                    sources: sources,
                    model: selectedAnswerModel
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
        navigateToTimelineItem(source.itemID)
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

    private func beginRecording(_ destination: RecordingDestination) {
        guard !recorder.isRecording, recordingDestination == nil else { return }
        recordingDestination = destination
        Task { [weak self] in
            guard let self else { return }
            await recorder.start()
            if !recorder.isRecording {
                recordingDestination = nil
            }
        }
    }

    private func finishRecording() {
        guard let capture = recorder.stop() else {
            recordingDestination = nil
            return
        }
        let destination = recordingDestination ?? .newRecording
        recordingDestination = nil
        switch destination {
        case .newRecording:
            importVoiceCapture(capture, origin: "iphone")
        case .append(let recordingID, let offsetMs):
            appendVoiceCapture(
                capture,
                recordingID: recordingID,
                offsetMs: offsetMs
            )
        }
    }

    private func appendVoiceCapture(
        _ capture: VoiceCapture,
        recordingID: String,
        offsetMs: Int
    ) {
        let root = locator.rootURL
        importState = .importing("resumed voice recording")
        Task { [weak self] in
            guard let self else { return }
            var didAppendAudio = false
            defer {
                try? FileManager.default.removeItem(at: capture.url)
                importState = .idle
                reload()
            }
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try SharedLibraryStore(root: root).appendVoiceRecording(
                        source: capture.url,
                        recordingID: recordingID,
                        durationSeconds: capture.durationSeconds
                    )
                }.value
                didAppendAudio = true
                importState = .transcribing("resumed recording")
                if let transcript = try await MobileTranscriber.transcribe(
                    capture.url
                ) {
                    try await Task.detached(priority: .userInitiated) {
                        try SharedLibraryStore(root: root).appendTranscript(
                            transcript,
                            offsetMs: offsetMs,
                            recordingID: recordingID
                        )
                    }.value
                }
            } catch {
                errorMessage = didAppendAudio
                    ? "The audio was appended, but on-device transcription could not finish: "
                        + error.localizedDescription
                    : "Couldn’t append the resumed audio: "
                        + error.localizedDescription
                // `.transcription-pending` remains in the recording folder,
                // so the Mac will rebuild the complete transcript later.
            }
        }
    }

    private struct SemanticSourceContent: Sendable {
        let sourceID: String
        let revision: String
        let title: String
        let text: String
        let reference: SharedSemanticSourceReference
    }

    private func scanForSemanticCandidates() {
        guard semanticAnalysisTask == nil else { return }
        let root = locator.rootURL
        let store = SharedSemanticStore(root: root)
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
                try store.resetProcessing(
                    sourceID: manuallyRequestedSource.sourceID
                )
                semanticReviews = store.loadPendingReviews()
            } catch {
                errorMessage = "Couldn’t re-extract this item: "
                    + error.localizedDescription
                scanForSemanticCandidates()
                return
            }
        }
        let pendingKeys = Set(
            store.loadPendingReviews().map {
                $0.sourceID + "|" + $0.sourceRevision
            }
        )
        let source = manuallyRequestedSource ?? sources.first(where: {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !store.isProcessed(
                    sourceID: $0.sourceID,
                    revision: $0.revision
                )
                && !pendingKeys.contains($0.sourceID + "|" + $0.revision)
        })
        guard let source else { return }

        semanticProcessingLabel = "Organizing \(source.title)…"
        semanticProcessingSourceID = source.sourceID
        semanticAnalysisTask = Task { [weak self] in
            guard let self else { return }
            let candidates = await MobileSemanticExtractionService.candidates(
                text: source.text,
                sourceTitle: source.title,
                source: source.reference
            )
            guard !Task.isCancelled else { return }
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
                errorMessage = "Couldn’t save extracted findings: "
                    + error.localizedDescription
            }
            semanticProcessingLabel = nil
            semanticProcessingSourceID = nil
            semanticAnalysisTask = nil
            semanticReviews = store.loadPendingReviews()
            reload()
        }
    }

    private func semanticSources() -> [SemanticSourceContent] {
        let recordingSources = snapshot.recordings.compactMap {
            recording -> SemanticSourceContent? in
            let transcript = recording.transcript
            let transcriptText = (transcript?.segments ?? []).map {
                "\(recording.speakerName(for: $0.speaker)): \($0.text)"
            }
            .joined(separator: "\n")
            let notes = recording.notes.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let text = notes.isEmpty
                ? transcriptText
                : "Notes:\n\(notes)\n\nTranscript:\n\(transcriptText)"
            guard !text.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else { return nil }
            let first = transcript?.segments.first
            let itemID = "recording:\(recording.id)"
            return SemanticSourceContent(
                sourceID: itemID,
                revision: (transcript?.createdAt ?? "notes-only") + "|"
                    + Self.stableTextSignature(recording.notes),
                title: recording.title,
                text: text,
                reference: SharedSemanticSourceReference(
                    itemID: itemID,
                    title: recording.title,
                    locator: first.map {
                        "Transcript · \(Self.clock($0.startMs))"
                    } ?? "Transcript",
                    excerpt: first?.text ?? recording.preview,
                    startMs: first?.startMs
                )
            )
        }
        let knowledgeSources = snapshot.knowledgeItems.map {
            item -> SemanticSourceContent in
            let primary = item.kind == .note ? item.content : item.extractedText
            let notes = item.additionalNotes.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let text = notes.isEmpty
                ? primary
                : "\(primary)\n\nAdditional notes:\n\(notes)"
            let itemID = "knowledge:\(item.id.uuidString)"
            return SemanticSourceContent(
                sourceID: itemID,
                revision: ISO8601DateFormatter().string(from: item.updatedAt),
                title: item.title,
                text: text,
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

    nonisolated private static func clock(_ milliseconds: Int) -> String {
        let total = milliseconds / 1_000
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
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
        // Keep whatever the user is currently viewing. Finishing background
        // transcription should update content, never navigate the timeline.
        reload()
    }

    private func reload(selecting id: String) {
        navigateToTimelineItem(id)
        reload()
    }

    func userNavigatedToTimelineItem(_ id: String?) {
        selectedTimelineItemID = id
    }

    private func navigateToTimelineItem(_ id: String?) {
        selectedTimelineItemID = id
        timelineNavigationRequest = TimelineNavigationRequest(itemID: id)
    }

    private static func durationSeconds(of url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? max(1, Int(seconds.rounded())) : 0
    }
}
