import DropsiftShared
import SwiftUI

struct RecordingDetailView: View {
    @ObservedObject var model: AppModel
    let recording: RecordingItem

    @State private var title: String
    @State private var notes: String
    @State private var speakerNames: [String: String]
    @State private var showingNotesPanel = true
    @State private var showingSpeakerEditor = false
    @State private var showingSummary = true
    @State private var splitSegment: TranscriptDocument.Segment?

    init(model: AppModel, recording: RecordingItem) {
        self.model = model
        self.recording = recording
        _title = State(initialValue: recording.title)
        _notes = State(initialValue: recording.notes)
        _speakerNames = State(initialValue: recording.speakerNames)
    }

    var body: some View {
        Group {
            if RecordingDetailLayoutPolicy.showsSavedNotes(
                requested: showingNotesPanel,
                isAnyRecordingActive: model.isRecording
                    || ProcessInfo.processInfo.environment[
                        "DROPSIFT_PREVIEW_RECORDING_PANEL"
                    ] == "1"
            ) {
                HSplitView {
                    recordingContent
                        .frame(
                            minWidth: 460,
                            maxWidth: .infinity,
                            maxHeight: .infinity
                        )

                    savedNotes
                        .frame(
                            minWidth: 340,
                            idealWidth: 380,
                            maxWidth: 420,
                            maxHeight: .infinity
                        )
                }
            } else {
                recordingContent
            }
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
        .sheet(isPresented: $showingSpeakerEditor) {
            SpeakerNamesEditor(
                speakerIDs: speakerIDs,
                names: speakerNames
            ) { names in
                speakerNames = names
                model.updateSpeakerNames(names, recordingID: recording.id)
            }
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
                "Everything from \(TranscriptDocument.clock(segment.startMs)) onward becomes a separate timeline item. Dropsift splits and rebases the transcript and audio tracks; the untouched source audio remains in this item’s folder for recovery."
            )
        }
    }

    private var isActiveRecording: Bool {
        model.isRecording && model.recordingSessionID == recording.id
    }

    private var recordingContent: some View {
        VStack(spacing: 0) {
            header
            summaryPanel
            ItemSemanticInsightsView(
                model: model,
                sourceID: "recording:\(recording.id)"
            )
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            Divider()
            transcript
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Meeting title", text: $title)
                .textFieldStyle(.plain)
                .font(.title.weight(.semibold))
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

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        model.createThread(scope: .recording(recording.id))
                    } label: {
                        Label("Ask about this recording", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)

                    regenerationMenu

                    Menu {
                        Button("Open microphone track") { model.openAudio(recording.micURL) }
                            .disabled(recording.micURL == nil)
                        Button("Open system-audio track") { model.openAudio(recording.systemURL) }
                            .disabled(recording.systemURL == nil)
                        Divider()
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([recording.directory])
                        }
                        Divider()
                        Button(role: .destructive) {
                            model.requestDeleteRecording(recording)
                        } label: {
                            Label("Move Recording to Trash", systemImage: "trash")
                        }
                    } label: {
                        Label("Audio & files", systemImage: "waveform")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                HStack(spacing: 8) {
                    if !speakerIDs.isEmpty {
                        Button {
                            showingSpeakerEditor = true
                        } label: {
                            Label("Name speakers", systemImage: "person.2")
                        }
                        .buttonStyle(.bordered)
                        .help("Assign names to transcript speakers")
                    }

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
                        .controlSize(.small)
                        .tint(.red)
                        .help("Stop recording")
                    } else if model.isPreparingRecording {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Preparing recorder…")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    } else if model.splittingRecordingID == recording.id {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Splitting recording…")
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

                    Spacer()

                    if !model.isRecording {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showingNotesPanel.toggle()
                            }
                        } label: {
                            Label(
                                showingNotesPanel ? "Hide notes" : "Show notes",
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
        }
        .padding(24)
    }

    private var regenerationMenu: some View {
        let sourceID = "recording:\(recording.id)"
        let transcriptIsProcessing = model.transcriptionProcessingID
            == recording.id
        return Menu {
            Button {
                model.regenerateTranscript(for: recording)
            } label: {
                Label(
                    "Regenerate transcript",
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }
            .disabled(
                transcriptIsProcessing
                    || model.splittingRecordingID == recording.id
                    || (recording.micURL == nil && recording.systemURL == nil)
            )

            Divider()

            Button {
                model.regeneratePresentation(for: .recording(recording))
            } label: {
                Label("Regenerate title & description", systemImage: "sparkles")
            }
            .disabled(
                transcriptIsProcessing
                    || model.metadataGenerationItemID == sourceID
            )

            Button {
                model.regenerateSummary(for: recording)
            } label: {
                Label(
                    recording.summary == nil
                        ? "Generate summary"
                        : "Regenerate summary",
                    systemImage: "text.page.badge.magnifyingglass"
                )
            }
            .disabled(
                transcriptIsProcessing
                    || recording.transcript == nil
                    || model.summaryGenerationItemID == sourceID
            )
        } label: {
            Label(
                transcriptIsProcessing ? "Regenerating…" : "Regenerate",
                systemImage: "arrow.clockwise"
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Regenerate this recording’s transcript, title, or summary")
    }

    @ViewBuilder
    private var summaryPanel: some View {
        let sourceID = "recording:\(recording.id)"
        if model.summaryGenerationItemID == sourceID {
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Building meeting summary…")
                        .font(.headline)
                    Text("Analyzing participants, topics, decisions, and action items locally.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        } else if let summary = recording.summary {
            DisclosureGroup(isExpanded: $showingSummary) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(summary.overview)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(alignment: .top, spacing: 24) {
                        SummaryListSection(
                            title: "Participants (\(summary.participantCount))",
                            values: summary.participants,
                            emptyText: "No names identified"
                        )
                        SummaryListSection(
                            title: "Topics",
                            values: summary.topics,
                            emptyText: "No topics identified"
                        )
                    }

                    HStack(alignment: .top, spacing: 24) {
                        SummaryListSection(
                            title: "Decisions",
                            values: summary.decisions,
                            emptyText: "No explicit decisions"
                        )
                        SummaryListSection(
                            title: "Action items",
                            values: summary.actionItems,
                            emptyText: "No explicit action items"
                        )
                    }
                }
                .padding(.top, 12)
            } label: {
                HStack {
                    Label("Meeting summary", systemImage: "text.page")
                        .font(.headline)
                    Spacer()
                    Text("Local AI · \(summary.model)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }

    private var savedNotes: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Notes about this recording", systemImage: "note.text")
                    .font(.headline)
                Spacer()
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
                                    speakerName: SharedSpeakerNameStore.displayName(
                                        for: segment.speaker,
                                        names: speakerNames
                                    ),
                                    onRename: { showingSpeakerEditor = true },
                                    isHighlighted: jumpSegment(in: document)?.id == segment.id,
                                    canSplit: segment.id != document.segments.first?.id
                                        && model.splittingRecordingID == nil
                                        && !model.isRecording,
                                    onSplit: { splitSegment = segment }
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
                        ?? "Dropsift will transcribe this recording locally. The first run downloads the speech model."
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

enum RecordingDetailLayoutPolicy {
    static func showsSavedNotes(
        requested: Bool,
        isAnyRecordingActive: Bool
    ) -> Bool {
        requested && !isAnyRecordingActive
    }
}

private struct SummaryListSection: View {
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
    let speakerName: String
    let onRename: () -> Void
    let isHighlighted: Bool
    let canSplit: Bool
    let onSplit: () -> Void

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

            Text(segment.text)
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
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
