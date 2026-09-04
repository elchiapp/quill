import DropsiftShared
import AppKit
import SwiftUI

enum RecordingDetailSection: String, CaseIterable, Identifiable {
    case summary
    case transcript
    case insights

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcript: "Transcript"
        case .summary: "Summary"
        case .insights: "Insights"
        }
    }

    var systemImage: String {
        switch self {
        case .transcript: "text.alignleft"
        case .summary: "text.page"
        case .insights: "wand.and.stars"
        }
    }
}

struct RecordingDetailView: View {
    @ObservedObject var model: AppModel
    let recording: RecordingItem

    @State private var title: String
    @State private var notes: String
    @State private var speakerNames: [String: String]
    @State private var showingNotesPanel = true
    @State private var showingSpeakerEditor = false
    @State private var selectedSection = RecordingDetailSection.transcript
    @State private var splitSegment: TranscriptDocument.Segment?
    @State private var correctionDraft: TerminologyCorrectionDraft?
    @State private var copyConfirmation: String?

    init(model: AppModel, recording: RecordingItem) {
        self.model = model
        self.recording = recording
        _title = State(initialValue: recording.title)
        _notes = State(initialValue: recording.notes)
        _speakerNames = State(initialValue: recording.speakerNames)
        _selectedSection = State(
            initialValue: recording.summary == nil ? .transcript : .summary
        )
        _showingNotesPanel = State(
            initialValue: ItemDetailLayoutPolicy.notesStartExpanded(
                recording.notes
            )
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let overlaysNotes = ItemDetailLayoutPolicy.overlaysSavedNotes(
                width: geometry.size.width
            )
            recordingContent
                .inspector(
                    isPresented: inspectorNotesPresented(
                        overlaysNotes: overlaysNotes
                    )
                ) {
                    savedNotes
                        .inspectorColumnWidth(
                            min: 340,
                            ideal: 380,
                            max: 460
                        )
                }
                .overlay(alignment: .trailing) {
                    if overlaysNotes, savedNotesPresented.wrappedValue {
                        savedNotes
                            .frame(
                                width: min(
                                    420,
                                    max(340, geometry.size.width * 0.78)
                                )
                            )
                            .background(
                                Color(nsColor: .controlBackgroundColor)
                            )
                            .shadow(color: .black.opacity(0.18), radius: 18)
                            .transition(
                                .move(edge: .trailing).combined(with: .opacity)
                            )
                            .zIndex(2)
                    }
                }
                .animation(
                    .easeInOut(duration: 0.2),
                    value: savedNotesPresented.wrappedValue
                )
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: recording.title) { oldTitle, newTitle in
            if title == oldTitle {
                title = newTitle
            }
        }
        .onChange(of: recording.notes) { oldNotes, newNotes in
            if notes == oldNotes || isActiveRecording {
                notes = newNotes
            }
        }
        .onChange(of: recording.speakerNames) { oldNames, newNames in
            if speakerNames == oldNames {
                speakerNames = newNames
            }
        }
        .onChange(of: recording.summary?.sourceRevision) { oldRevision, newRevision in
            if oldRevision == nil, newRevision != nil {
                selectedSection = .summary
            } else if newRevision == nil, selectedSection == .summary {
                selectedSection = .transcript
            }
        }
        .sheet(isPresented: $showingSpeakerEditor) {
            SpeakerNamesEditor(
                speakerIDs: speakerIDs,
                names: speakerNames
            ) { names in
                speakerNames = names
                model.updateSpeakerNames(names, recordingID: recording.id)
            }
        }
        .sheet(item: $correctionDraft) { draft in
            TerminologyCorrectionEditor(
                draft: draft,
                onSave: { source, replacement in
                    model.updateTranscriptCorrection(
                        source: source,
                        replacement: replacement,
                        recordingID: recording.id
                    )
                },
                onDelete: draft.replacement.isEmpty ? nil : {
                    model.updateTranscriptCorrection(
                        source: draft.source,
                        replacement: draft.source,
                        recordingID: recording.id
                    )
                }
            )
        }
        .confirmationDialog(
            "Split this recording here?",
            isPresented: Binding(
                get: { splitSegment != nil },
                set: { if !$0 { splitSegment = nil } }
            ),
            titleVisibility: .visible,
            presenting: splitSegment
        ) { segment in
            Button("Split into a new item") {
                model.splitRecording(recording, before: segment)
                splitSegment = nil
            }
            Button("Cancel", role: .cancel) {
                splitSegment = nil
            }
        } message: { segment in
            Text(
                "Everything from \(TranscriptDocument.clock(segment.startMs)) onward becomes a separate timeline item. DropSift splits and rebases the transcript and audio tracks; the untouched source audio remains in this item’s folder for recovery."
            )
        }
    }

    private var isActiveRecording: Bool {
        model.isRecording && model.recordingSessionID == recording.id
    }

    private var savedNotesPresented: Binding<Bool> {
        Binding(
            get: {
                ItemDetailLayoutPolicy.showsSavedNotes(
                    requested: showingNotesPanel,
                    isAnyRecordingActive: model.isRecording
                        || ProcessInfo.processInfo.environment[
                            "DROPSIFT_PREVIEW_RECORDING_PANEL"
                        ] == "1"
                )
            },
            set: { showingNotesPanel = $0 }
        )
    }

    private func inspectorNotesPresented(
        overlaysNotes: Bool
    ) -> Binding<Bool> {
        Binding(
            get: {
                !overlaysNotes && savedNotesPresented.wrappedValue
            },
            set: { presented in
                guard !overlaysNotes else { return }
                showingNotesPanel = presented
            }
        )
    }

    private var recordingContent: some View {
        VStack(spacing: 0) {
            header
            Divider()
            sectionPicker
            Divider()
            selectedSectionContent
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Meeting title", text: $title)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .onSubmit {
                    model.renameSelectedRecording(to: title)
                }

            if model.metadataGenerationItemID == "recording:\(recording.id)" {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Generating title and description locally…")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else if !recording.generatedDescription.isEmpty {
                Text(recording.generatedDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 12) {
                Label(recording.displayDate, systemImage: "calendar")
                Label(recording.displayDuration, systemImage: "clock")
                if recording.isTranscribed {
                    Label("\(recording.segmentCount) segments", systemImage: "text.alignleft")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    model.createThread(scope: .recording(recording.id))
                } label: {
                    Label("Ask about this recording", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)

                recordingControl
                actionsMenu

                if let copyConfirmation {
                    Label("\(copyConfirmation) copied", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }

                Spacer()

                if !model.isRecording {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showingNotesPanel.toggle()
                        }
                    } label: {
                        Label(
                            showingNotesPanel ? "Hide notes" : "Notes",
                            systemImage: showingNotesPanel
                                ? "rectangle.righthalf.inset.filled"
                                : "note.text"
                        )
                    }
                    .buttonStyle(.borderless)
                    .help(
                        showingNotesPanel
                            ? "Collapse recording notes"
                            : "Show recording notes"
                    )
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var recordingControl: some View {
        if isActiveRecording {
            Button {
                model.stopRecording()
            } label: {
                Label(
                    "Stop \(model.recordingElapsed)",
                    systemImage: "stop.circle.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .help("Stop recording")
        } else if model.isPreparingRecording {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing…")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else if model.splittingRecordingID == recording.id {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Splitting…")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
            Button {
                model.resumeRecording(recording)
            } label: {
                Label("Resume", systemImage: "record.circle")
            }
            .buttonStyle(.bordered)
            .disabled(model.isRecording)
            .help("Continue recording into this item")
        }
    }

    private var actionsMenu: some View {
        Menu {
            Menu {
                regenerationActions
            } label: {
                Label("Regenerate", systemImage: "arrow.clockwise")
            }

            if !speakerIDs.isEmpty {
                Button {
                    showingSpeakerEditor = true
                } label: {
                    Label("Name speakers", systemImage: "person.2")
                }
            }

            Menu {
                Button {
                    correctionDraft = TerminologyCorrectionDraft(
                        source: "",
                        replacement: ""
                    )
                } label: {
                    Label("New correction…", systemImage: "plus")
                }

                if !recording.corrections.isEmpty {
                    Divider()
                    ForEach(
                        recording.corrections.keys.sorted {
                            $0.localizedStandardCompare($1) == .orderedAscending
                        },
                        id: \.self
                    ) { source in
                        Button("\(source) → \(recording.corrections[source] ?? "")") {
                            correctionDraft = TerminologyCorrectionDraft(
                                source: source,
                                replacement: recording.corrections[source] ?? ""
                            )
                        }
                    }
                }
            } label: {
                Label(
                    recording.corrections.isEmpty
                        ? "Terminology corrections"
                        : "Terminology corrections (\(recording.corrections.count))",
                    systemImage: "character.cursor.ibeam"
                )
            }

            Menu {
                copyActions
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            Divider()

            Button("Open microphone track") {
                model.openAudio(recording.micURL)
            }
            .disabled(recording.micURL == nil)
            Button("Open system-audio track") {
                model.openAudio(recording.systemURL)
            }
            .disabled(recording.systemURL == nil)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([
                    recording.directory
                ])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }

            Divider()

            Button(role: .destructive) {
                model.requestDeleteRecording(recording)
            } label: {
                Label("Move Recording to Trash", systemImage: "trash")
            }
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Recording actions")
    }

    @ViewBuilder
    private var copyActions: some View {
        copyAction("Everything", value: copyEverythingContent)
        Divider()
        copyAction("Title & description", value: titleAndDescriptionContent)
        copyAction("Summary", value: summaryCopyContent)
        copyAction("Transcript", value: recording.copyableTranscript)
        copyAction("Notes", value: notes)
        copyAction("Insights", value: insightsCopyContent)
    }

    private func copyAction(_ label: String, value: String) -> some View {
        Button {
            copyText(value, label: label)
        } label: {
            Label(label, systemImage: "doc.on.doc")
        }
        .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func copyText(_ value: String, label: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) {
            copyConfirmation = label
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeInOut(duration: 0.15)) {
                copyConfirmation = nil
            }
        }
    }

    private var titleAndDescriptionContent: String {
        SharedClipboardContent.titleAndDescription(
            title: title,
            description: recording.generatedDescription
        )
    }

    private var summaryCopyContent: String {
        guard let summary = recording.summary else { return "" }
        return SharedClipboardContent.summary(
            title: title,
            summary: summary,
            includesParticipants: true
        )
    }

    private var insightsCopyContent: String {
        SharedClipboardContent.semanticReview(
            model.semanticReview(for: "recording:\(recording.id)")
        )
    }

    private var copyEverythingContent: String {
        SharedClipboardContent.everything([
            titleAndDescriptionContent,
            summaryCopyContent,
            recording.copyableTranscript,
            notes,
            insightsCopyContent,
        ])
    }

    @ViewBuilder
    private var regenerationActions: some View {
        let sourceID = "recording:\(recording.id)"
        let transcriptIsProcessing = model.transcriptionProcessingID
            == recording.id
        Button {
            model.regenerateTranscript(for: recording)
        } label: {
            Label(
                "Transcript",
                systemImage: "arrow.triangle.2.circlepath"
            )
        }
        .disabled(
            transcriptIsProcessing
                || model.splittingRecordingID == recording.id
                || (recording.micURL == nil && recording.systemURL == nil)
        )

        Button {
            model.regeneratePresentation(for: .recording(recording))
        } label: {
            Label("Title & description", systemImage: "sparkles")
        }
        .disabled(
            transcriptIsProcessing
                || model.metadataGenerationItemID == sourceID
        )

        Button {
            model.regenerateSummary(for: recording)
        } label: {
            Label(
                "Summary",
                systemImage: "text.page.badge.magnifyingglass"
            )
        }
        .disabled(
            transcriptIsProcessing
                || recording.transcript == nil
                || model.summaryGenerationItemID == sourceID
        )
    }

    private var sectionPicker: some View {
        HStack(spacing: 6) {
            ForEach(RecordingDetailSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: section.systemImage)
                        Text(section.title)
                        if section == .insights, insightCount > 0 {
                            Text("\(insightCount)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.14), in: Capsule())
                        }
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(
                        selectedSection == section ? Color.accentColor : Color.secondary
                    )
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(
                        selectedSection == section
                            ? Color.accentColor.opacity(0.11)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!sectionIsAvailable(section))
                .opacity(sectionIsAvailable(section) ? 1 : 0.42)
            }
            Spacer()
            Button {
                copySelectedSection()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selectedSectionCopyContent.isEmpty)
            .help("Copy \(selectedSection.title.lowercased())")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    @ViewBuilder
    private var selectedSectionContent: some View {
        switch selectedSection {
        case .transcript:
            transcript
        case .summary:
            summaryContent
        case .insights:
            insightsContent
        }
    }

    private var insightCount: Int {
        model.semanticReview(for: "recording:\(recording.id)")?
            .candidates.count ?? 0
    }

    private func sectionIsAvailable(_ section: RecordingDetailSection) -> Bool {
        section != .summary || recording.summary != nil
    }

    private var selectedSectionCopyContent: String {
        switch selectedSection {
        case .summary: summaryCopyContent
        case .transcript: recording.copyableTranscript
        case .insights: insightsCopyContent
        }
    }

    private func copySelectedSection() {
        copyText(selectedSectionCopyContent, label: selectedSection.title)
    }

    private var insightsContent: some View {
        ScrollView {
            ItemSemanticInsightsView(
                model: model,
                sourceID: "recording:\(recording.id)"
            )
            .padding(24)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var summaryContent: some View {
        let sourceID = "recording:\(recording.id)"
        if model.summaryGenerationItemID == sourceID {
            VStack(spacing: 12) {
                ProgressView()
                Text("Building meeting summary…")
                    .font(.headline)
                Text("Analyzing participants, topics, decisions, and action items locally.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let summary = recording.summary {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Label("Meeting summary", systemImage: "text.page")
                            .font(.headline)
                        Spacer()
                        Text("Local AI · \(summary.model)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(summary.overview)
                        .font(.body)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 28) {
                            participantsSection(summary)
                            topicsSection(summary)
                        }
                        VStack(alignment: .leading, spacing: 20) {
                            participantsSection(summary)
                            topicsSection(summary)
                        }
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 28) {
                            decisionsSection(summary)
                            actionItemsSection(summary)
                        }
                        VStack(alignment: .leading, spacing: 20) {
                            decisionsSection(summary)
                            actionItemsSection(summary)
                        }
                    }
                }
                .padding(26)
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
            }
        } else {
            ContentUnavailableView {
                Label("No summary yet", systemImage: "text.page")
            } description: {
                Text("Generate a concise overview, participants, decisions, and action items locally.")
            } actions: {
                Button("Generate summary") {
                    model.regenerateSummary(for: recording)
                }
                .buttonStyle(.borderedProminent)
                .disabled(recording.transcript == nil)
            }
        }
    }

    private func participantsSection(
        _ summary: RecordingSummary
    ) -> some View {
        SummaryListSection(
            title: "Participants (\(summary.participantCount))",
            values: summary.participants,
            emptyText: "No names identified"
        )
    }

    private func topicsSection(_ summary: RecordingSummary) -> some View {
        SummaryListSection(
            title: "Topics",
            values: summary.topics,
            emptyText: "No topics identified"
        )
    }

    private func decisionsSection(_ summary: RecordingSummary) -> some View {
        SummaryListSection(
            title: "Decisions",
            values: summary.decisions,
            emptyText: "No explicit decisions"
        )
    }

    private func actionItemsSection(_ summary: RecordingSummary) -> some View {
        SummaryListSection(
            title: "Action items",
            values: summary.actionItems,
            emptyText: "No explicit action items"
        )
    }

    private var savedNotes: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Notes about this recording", systemImage: "note.text")
                    .font(.headline)
                Spacer()
                Button {
                    copyText(notes, label: "Notes")
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .disabled(notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Copy all recording notes")
                Label("Autosaved", systemImage: "icloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingNotesPanel = false
                    }
                } label: {
                    Label("Hide", systemImage: "chevron.right")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .contentShape(Rectangle())
                .help("Collapse recording notes")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            MarkdownNoteEditor(
                text: $notes,
                placeholder: "Add notes about this recording…",
                accessibilityIdentifier: "recording-notes-editor"
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: notes) {
                    model.updateRecordingNotes(notes, recordingID: recording.id)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var transcript: some View {
        if let document = recording.transcript {
            if document.segments.isEmpty {
                ContentUnavailableView {
                    Label("No speech detected", systemImage: "waveform.slash")
                } description: {
                    Text("The recording was transcribed successfully, but it contained no recognizable speech.")
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(document.segments) { segment in
                                TranscriptSegmentRow(
                                    segment: segment,
                                    displayText: recording.corrected(segment.text),
                                    speakerName: recording.corrected(
                                        SharedSpeakerNameStore.displayName(
                                            for: segment.speaker,
                                            names: speakerNames
                                        )
                                    ),
                                    onRename: { showingSpeakerEditor = true },
                                    isHighlighted: jumpSegment(in: document)?.id == segment.id,
                                    canSplit: segment.id != document.segments.first?.id
                                        && model.splittingRecordingID == nil
                                        && !model.isRecording,
                                    onSplit: { splitSegment = segment },
                                    onCorrect: { selectedText in
                                        let source = selectedText.trimmingCharacters(
                                            in: .whitespacesAndNewlines
                                        )
                                        let existing = recording.corrections.first {
                                            $0.key.localizedCaseInsensitiveCompare(source)
                                                == .orderedSame
                                        }?.value ?? ""
                                        correctionDraft = TerminologyCorrectionDraft(
                                            source: source,
                                            replacement: existing
                                        )
                                    }
                                )
                                .id(segment.id)
                                Divider()
                                    .padding(.leading, 92)
                            }

                            HStack {
                                Spacer()
                                Text(transcriptionFooter(document))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Spacer()
                            }
                            .padding(24)
                        }
                        .padding(.horizontal, 24)
                    }
                    .onAppear { scrollToSource(in: document, proxy: proxy) }
                    .onChange(of: model.transcriptJump) {
                        scrollToSource(in: document, proxy: proxy)
                    }
                }
            }
        } else {
            ContentUnavailableView {
                Label("Transcription pending", systemImage: "waveform.badge.magnifyingglass")
            } description: {
                Text(
                    model.transcriptionStatus
                        ?? "DropSift will transcribe this recording locally. The first run downloads the speech model."
                )
            }
        }
    }

    private func jumpSegment(
        in document: TranscriptDocument
    ) -> TranscriptDocument.Segment? {
        guard let jump = model.transcriptJump, jump.recordingID == recording.id else {
            return nil
        }
        return document.segments.min {
            abs($0.startMs - jump.startMs) < abs($1.startMs - jump.startMs)
        }
    }

    private func scrollToSource(
        in document: TranscriptDocument,
        proxy: ScrollViewProxy
    ) {
        guard let segment = jumpSegment(in: document) else { return }
        Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(segment.id, anchor: .center)
            }
        }
    }

    private func transcriptionFooter(_ document: TranscriptDocument) -> String {
        var value = "Transcribed locally with \(document.engine) · \(document.model)"
        if let code = document.languageCode {
            let name = Locale.current.localizedString(forLanguageCode: code) ?? code
            value += " · \(name.capitalized) detected"
        }
        if let diarization = document.diarization {
            value += " · \(diarization.speakerCount) remote speaker"
            if diarization.speakerCount != 1 { value += "s" }
        }
        return value
    }

    private var speakerIDs: [String] {
        let ids = Set(recording.transcript?.segments.map(\.speaker) ?? [])
        return ids.sorted { lhs, rhs in
            if lhs == "me" { return true }
            if rhs == "me" { return false }
            if lhs == "them" { return true }
            if rhs == "them" { return false }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }
}

enum ItemDetailLayoutPolicy {
    static func notesStartExpanded(_ notes: String) -> Bool {
        !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func overlaysSavedNotes(width: CGFloat) -> Bool {
        // The decision is made before an inspector takes its own 340–460 pt.
        // Overlay at medium widths too, otherwise the remaining item content
        // becomes narrower than its usable minimum after the split.
        width < 1_100
    }

    static func showsSavedNotes(
        requested: Bool,
        isAnyRecordingActive: Bool
    ) -> Bool {
        requested && !isAnyRecordingActive
    }
}

struct SummaryListSection: View {
    let title: String
    let values: [String]
    let emptyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if values.isEmpty {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(value)
                            .textSelection(.enabled)
                    }
                    .font(.callout)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TranscriptSegmentRow: View {
    let segment: TranscriptDocument.Segment
    let displayText: String
    let speakerName: String
    let onRename: () -> Void
    let isHighlighted: Bool
    let canSplit: Bool
    let onSplit: () -> Void
    let onCorrect: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(TranscriptDocument.clock(segment.startMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(action: onRename) {
                    Text(speakerName.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(speakerColor)
                        .lineLimit(2)
                }
                .buttonStyle(.plain)
                .help("Name this speaker")
            }
            .frame(width: 72, alignment: .leading)

            CorrectableTranscriptText(
                text: displayText,
                onCorrect: onCorrect
            )
                .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button {
                    onCorrect("")
                } label: {
                    Label("Correct terminology…", systemImage: "character.cursor.ibeam")
                }

                Divider()

                Button {
                    onSplit()
                } label: {
                    Label(
                        "Split into new item from here",
                        systemImage: "scissors"
                    )
                }
                .disabled(!canSplit)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Transcript actions")
        }
        .padding(.vertical, 15)
        .padding(.horizontal, 8)
        .background(
            isHighlighted ? Color.accentColor.opacity(0.13) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .animation(.easeInOut(duration: 0.2), value: isHighlighted)
    }

    private var speakerColor: Color {
        if segment.speaker == "me" { return .indigo }
        let palette: [Color] = [.orange, .teal, .pink, .purple, .green, .blue]
        let value = segment.speaker.unicodeScalars.reduce(0) {
            $0 + Int($1.value)
        }
        return palette[value % palette.count]
    }
}

private struct TerminologyCorrectionDraft: Identifiable {
    let id = UUID()
    let source: String
    let replacement: String
}

private struct TerminologyCorrectionEditor: View {
    let draft: TerminologyCorrectionDraft
    let onSave: (String, String) -> Void
    let onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var source: String
    @State private var replacement: String

    init(
        draft: TerminologyCorrectionDraft,
        onSave: @escaping (String, String) -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.draft = draft
        self.onSave = onSave
        self.onDelete = onDelete
        _source = State(initialValue: draft.source)
        _replacement = State(initialValue: draft.replacement)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Correct terminology")
                    .font(.title2.weight(.semibold))
                Text(
                    "DropSift will use this correction for every whole-word occurrence in this recording, including search, summaries, extracted details, and AI answers."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("Transcript says")
                    TextField("For example, Cuback", text: $source)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Use instead")
                    TextField("For example, QVAC", text: $replacement)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                if let onDelete {
                    Button("Remove correction", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply throughout recording") {
                    onSave(source, replacement)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private struct CorrectableTranscriptText: NSViewRepresentable {
    let text: String
    let onCorrect: (String) -> Void

    func makeNSView(context: Context) -> CorrectionTextView {
        let textView = CorrectionTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        return textView
    }

    func updateNSView(_ textView: CorrectionTextView, context: Context) {
        textView.correctionHandler = onCorrect
        guard textView.string != text else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        textView.textStorage?.setAttributedString(
            NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.preferredFont(forTextStyle: .body),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraph,
                ]
            )
        )
        textView.invalidateIntrinsicContentSize()
    }
}

private final class CorrectionTextView: NSTextView {
    var correctionHandler: ((String) -> Void)?

    override var intrinsicContentSize: NSSize {
        guard let textContainer, let layoutManager else {
            return super.intrinsicContentSize
        }
        layoutManager.ensureLayout(for: textContainer)
        let height = ceil(layoutManager.usedRect(for: textContainer).height)
            + textContainerInset.height * 2
        return NSSize(width: NSView.noIntrinsicMetric, height: max(height, 20))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            textContainer?.containerSize = NSSize(
                width: max(newSize.width, 1),
                height: .greatestFiniteMagnitude
            )
            invalidateIntrinsicContentSize()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let selectedTerm, !selectedTerm.isEmpty else { return menu }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let preview = selectedTerm.count > 32
            ? String(selectedTerm.prefix(29)) + "…"
            : selectedTerm
        let item = NSMenuItem(
            title: "Correct “\(preview)” throughout recording…",
            action: #selector(correctSelectedTerm),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func correctSelectedTerm() {
        guard let selectedTerm else { return }
        correctionHandler?(selectedTerm)
    }

    private var selectedTerm: String? {
        let range = selectedRange()
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        return (string as NSString).substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct SpeakerNamesEditor: View {
    let speakerIDs: [String]
    let onSave: ([String: String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var names: [String: String]

    init(
        speakerIDs: [String],
        names: [String: String],
        onSave: @escaping ([String: String]) -> Void
    ) {
        self.speakerIDs = speakerIDs
        self.onSave = onSave
        _names = State(initialValue: names)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Name speakers")
                    .font(.title2.weight(.semibold))
                Text("Names replace speaker labels everywhere in this recording, including search and AI answers.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                ForEach(speakerIDs, id: \.self) { speakerID in
                    HStack(spacing: 14) {
                        Text(defaultName(for: speakerID))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .leading)
                        TextField(
                            "Enter a name",
                            text: Binding(
                                get: { names[speakerID] ?? "" },
                                set: { names[speakerID] = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }

            HStack {
                Button("Clear names") {
                    names = [:]
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(SharedSpeakerNameStore.sanitized(names))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func defaultName(for speakerID: String) -> String {
        SharedSpeakerNameStore.displayName(for: speakerID, names: [:])
    }
}
