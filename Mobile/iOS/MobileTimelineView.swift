import AVFoundation
import DropsiftShared
import PDFKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MobileTimelineView: View {
    @ObservedObject var model: MobileAppModel
    @Environment(\.editMode) private var editMode
    @State private var path: [String] = []
    @State private var selection = Set<String>()
    @State private var confirmingBatchDelete = false
    @State private var showingLibraryPicker = false

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if shouldShowSyncBanner {
                    syncBanner
                    Divider()
                }

                Group {
                    if model.librarySyncState.isSyncing,
                       model.timeline.isEmpty {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text(
                                model.locator.isConnectedToSharedFolder
                                    ? "Syncing iCloud Drive…"
                                    : "Loading your local library…"
                            )
                            .font(.headline)
                            Text("Your timeline will appear here as items become available.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if model.filteredTimeline.isEmpty {
                        emptyTimeline
                    } else {
                        timelineList
                    }
                }
            }
            .navigationTitle("Timeline")
            .searchable(text: $model.timelineSearch, prompt: "Search timeline")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !isEditing {
                        filterMenu
                    }
                    EditButton()
                }
                ToolbarItem(placement: .topBarLeading) {
                    syncIndicator
                }
                if isEditing {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button(selectionContainsAllVisible ? "Clear" : "Select All") {
                            toggleSelectAll()
                        }
                        Spacer()
                        Menu {
                            Button {
                                selection.forEach {
                                    model.requestSemanticExtraction(for: $0)
                                }
                                finishEditing()
                            } label: {
                                Label(
                                    "Extract Tasks & Details",
                                    systemImage: "list.bullet.clipboard"
                                )
                            }
                        } label: {
                            Label("Actions", systemImage: "ellipsis.circle")
                        }
                        .disabled(selection.isEmpty)
                        Button(role: .destructive) {
                            confirmingBatchDelete = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(
                            selection.isEmpty || selectionContainsActiveRecording
                        )
                        .accessibilityLabel("Delete selected items")
                    }
                }
            }
            .navigationDestination(for: String.self) { id in
                if let item = model.timeline.first(where: { $0.id == id }) {
                    MobileItemDetail(model: model, item: item)
                        .id(item.id)
                } else {
                    ContentUnavailableView(
                        "Item unavailable",
                        systemImage: "questionmark.folder"
                    )
                }
            }
        }
        .onChange(of: path) { _, newPath in
            model.userNavigatedToTimelineItem(newPath.last)
        }
        .onChange(of: model.timelineNavigationRequest) { _, request in
            synchronizePath(with: request?.itemID)
        }
        .onAppear {
            synchronizePath(with: model.selectedTimelineItemID)
        }
        .onChange(of: model.filteredTimeline.map(\.id)) { _, visibleIDs in
            selection.formIntersection(Set(visibleIDs))
        }
        .onChange(of: editMode?.wrappedValue) { _, mode in
            if mode != .active {
                selection.removeAll()
            }
        }
        .confirmationDialog(
            "Delete \(selection.count) items?",
            isPresented: $confirmingBatchDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Items", role: .destructive) {
                model.deleteTimelineItems(selection)
                finishEditing()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected items and their files will be permanently deleted.")
        }
        .fileImporter(
            isPresented: $showingLibraryPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.connectLibrary(url)
            }
        }
    }

    @ViewBuilder
    private var timelineList: some View {
        if isEditing {
            List(selection: $selection) {
                ForEach(model.filteredTimeline) { item in
                    MobileTimelineRow(item: item)
                        .tag(item.id)
                }
            }
            .listStyle(.plain)
            .refreshable {
                await model.reloadAndWait()
            }
        } else {
            List {
                ForEach(model.filteredTimeline) { item in
                    Button {
                        path = [item.id]
                    } label: {
                        MobileTimelineRow(item: item)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens item details")
                }
            }
            .listStyle(.plain)
            .refreshable {
                await model.reloadAndWait()
            }
        }
    }

    private var shouldShowSyncBanner: Bool {
        switch model.librarySyncState {
        case .disconnected, .failed:
            true
        case .syncing:
            !model.timeline.isEmpty
        case .synced, .local:
            false
        }
    }

    private var syncIndicator: some View {
        Group {
            if model.librarySyncState.isSyncing {
                ProgressView()
            } else {
                Image(systemName: model.librarySyncState.systemImage)
                    .foregroundStyle(syncIndicatorColor)
            }
        }
        .accessibilityLabel(model.librarySyncState.accessibilityLabel)
    }

    private var syncIndicatorColor: Color {
        switch model.librarySyncState {
        case .synced: .green
        case .disconnected, .failed: .orange
        case .syncing, .local: .secondary
        }
    }

    @ViewBuilder
    private var syncBanner: some View {
        switch model.librarySyncState {
        case .disconnected:
            HStack(spacing: 10) {
                Image(systemName: "icloud.slash")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not connected to iCloud")
                        .font(.subheadline.weight(.semibold))
                    Text("Choose your DropSift folder to load the shared timeline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Connect") { showingLibraryPicker = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(12)
            .background(.orange.opacity(0.08))
        case .syncing(let shared):
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(shared ? "Syncing iCloud Drive…" : "Loading local library…")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }
            .padding(12)
            .background(.blue.opacity(0.08))
        case .failed(let message):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Couldn’t sync the library")
                        .font(.subheadline.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Retry") { model.reload() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(12)
            .background(.orange.opacity(0.08))
        case .synced, .local:
            EmptyView()
        }
    }

    private var emptyTimeline: some View {
        ContentUnavailableView {
            Label(emptyTimelineTitle, systemImage: emptyTimelineIcon)
        } description: {
            Text(emptyTimelineDescription)
        } actions: {
            if !model.locator.isConnectedToSharedFolder {
                Button("Connect iCloud folder") {
                    showingLibraryPicker = true
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Check again") { model.reload() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var emptyTimelineTitle: String {
        if !model.locator.isConnectedToSharedFolder {
            return "Connect your shared library"
        }
        if !model.timeline.isEmpty {
            return "No matching items"
        }
        return "No synced items yet"
    }

    private var emptyTimelineIcon: String {
        model.locator.isConnectedToSharedFolder
            ? "checkmark.icloud"
            : "icloud.slash"
    }

    private var emptyTimelineDescription: String {
        if !model.locator.isConnectedToSharedFolder {
            return "Choose the DropSift folder in iCloud Drive to see the same timeline as your Mac."
        }
        if !model.timeline.isEmpty {
            return "No timeline items match the current search and filters."
        }
        return "iCloud Drive is connected and up to date, but this folder does not contain any DropSift items yet."
    }

    private var isEditing: Bool {
        editMode?.wrappedValue == .active
    }

    private var selectionContainsAllVisible: Bool {
        let visible = Set(model.filteredTimeline.map(\.id))
        return !visible.isEmpty && visible.isSubset(of: selection)
    }

    private var selectionContainsActiveRecording: Bool {
        guard case .append(let recordingID, _) = model.recordingDestination
        else { return false }
        return selection.contains("recording:\(recordingID)")
    }

    private func toggleSelectAll() {
        let visible = Set(model.filteredTimeline.map(\.id))
        if visible.isSubset(of: selection) {
            selection.subtract(visible)
        } else {
            selection.formUnion(visible)
        }
    }

    private func finishEditing() {
        selection.removeAll()
        editMode?.wrappedValue = .inactive
    }

    private func synchronizePath(with id: String?) {
        let expectedPath = id.map { [$0] } ?? []
        if path != expectedPath {
            path = expectedPath
        }
    }

    private var filterMenu: some View {
        Menu {
            ForEach(SharedTimelineKind.allCases) { kind in
                Button {
                    if model.selectedKinds.contains(kind) {
                        model.selectedKinds.remove(kind)
                    } else {
                        model.selectedKinds.insert(kind)
                    }
                } label: {
                    Label(
                        kind.displayName,
                        systemImage: model.selectedKinds.contains(kind)
                            ? "checkmark"
                            : icon(for: kind)
                    )
                }
            }
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    private func icon(for kind: SharedTimelineKind) -> String {
        switch kind {
        case .recording: "waveform"
        case .note: "note.text"
        case .document: "doc.text"
        case .image: "photo"
        }
    }
}

private struct MobileTimelineRow: View {
    let item: SharedTimelineItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 40, height: 40)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(item.date, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(item.kind.rawValue.capitalized)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color)
                Text(item.listDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 5)
    }

    private var icon: String {
        switch item.kind {
        case .recording: "waveform"
        case .note: "note.text"
        case .document: "doc.text"
        case .image: "photo"
        }
    }

    private var color: Color {
        switch item.kind {
        case .recording: .red
        case .note: .yellow
        case .document: .blue
        case .image: .purple
        }
    }
}

private struct MobileItemDetail: View {
    @ObservedObject var model: MobileAppModel
    let item: SharedTimelineItem
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    var body: some View {
        Group {
            switch item {
            case .knowledge(let knowledge):
                MobileKnowledgeDetail(model: model, item: knowledge)
            case .recording(let recording):
                MobileRecordingDetail(model: model, recording: recording)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            "Delete this item?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                model.delete(item)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the item from the shared DropSift library.")
        }
    }
}

private struct MobileKnowledgeDetail: View {
    @ObservedObject var model: MobileAppModel
    let item: SharedKnowledgeItem
    @State private var title: String
    @State private var content: String
    @State private var notes: String

    init(model: MobileAppModel, item: SharedKnowledgeItem) {
        self.model = model
        self.item = item
        _title = State(initialValue: item.title)
        _content = State(initialValue: item.content)
        _notes = State(initialValue: item.additionalNotes)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TextField("Title", text: $title)
                    .font(.title2.bold())

                if !item.generatedDescription.isEmpty {
                    Text(item.generatedDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                summaryCard

                preview

                MobileSemanticInsightsView(
                    model: model,
                    sourceID: "knowledge:\(item.id.uuidString)"
                )

                if item.kind == .note {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Note")
                            .font(.headline)
                        TextEditor(text: $content)
                            .frame(minHeight: 300)
                            .font(.body.monospaced())
                            .padding(8)
                            .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    }
                } else {
                    DisclosureGroup("Extracted text") {
                        Text(item.extractedText.isEmpty ? "No text extracted." : item.extractedText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("Additional notes")
                            .font(.headline)
                        TextEditor(text: $notes)
                            .frame(minHeight: 150)
                            .padding(8)
                            .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    }
                }

                Button("Save changes") {
                    model.updateKnowledge(
                        id: item.id,
                        title: title == item.title ? nil : title,
                        content: item.kind == .note ? content : nil,
                        notes: item.kind == .note ? nil : notes
                    )
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding()
        }
        .navigationTitle(item.kind.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: item.title) { oldTitle, newTitle in
            if title == oldTitle {
                title = newTitle
            }
        }
    }

    @ViewBuilder
    private var summaryCard: some View {
        if let summary = item.summary {
            VStack(alignment: .leading, spacing: 12) {
                Label("Summary", systemImage: "text.page")
                    .font(.headline)
                Text(summary.overview)
                MobileSummarySection(title: "Topics", values: summary.topics)
                MobileSummarySection(
                    title: "Conclusions & decisions",
                    values: summary.decisions
                )
                MobileSummarySection(
                    title: "Action items",
                    values: summary.actionItems
                )
                Text("Generated locally on Mac with \(summary.model)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(
                .secondary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 14)
            )
        }
    }

    @ViewBuilder
    private var preview: some View {
        if item.kind == .image,
           let url = item.assetURL,
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        } else if item.assetURL?.pathExtension.lowercased() == "pdf",
                  let url = item.assetURL {
            MobilePDFView(
                url: url,
                targetPage: model.selectedSource?.itemID == "knowledge:\(item.id.uuidString)"
                    ? model.selectedSource?.page
                    : nil
            )
                .frame(height: 420)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        } else if item.kind == .document {
            Text(item.preview)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

private struct MobileRecordingDetail: View {
    @ObservedObject var model: MobileAppModel
    let recording: SharedRecordingItem
    @State private var notes: String
    @State private var speakerNames: [String: String]
    @State private var showingSpeakerEditor = false
    @StateObject private var playback = MobileRecordingPlayer()

    init(model: MobileAppModel, recording: SharedRecordingItem) {
        self.model = model
        self.recording = recording
        _notes = State(initialValue: recording.notes)
        _speakerNames = State(initialValue: recording.speakerNames)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(recording.title)
                            .font(.title2.bold())
                        if !recording.generatedDescription.isEmpty {
                            Text(recording.generatedDescription)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text(
                            "\(recording.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(recording.durationSeconds)s"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    playbackControls

                    if let playbackError = playback.errorMessage {
                        Text(playbackError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    summaryCard

                    MobileSemanticInsightsView(
                        model: model,
                        sourceID: "recording:\(recording.id)"
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Transcript")
                                .font(.headline)
                            Spacer()
                            if !speakerIDs.isEmpty {
                                Button {
                                    showingSpeakerEditor = true
                                } label: {
                                    Label("Name speakers", systemImage: "person.2")
                                }
                                .font(.subheadline)
                            }
                        }
                        if let segments = recording.transcript?.segments,
                           !segments.isEmpty {
                            ForEach(segments) { segment in
                                VStack(alignment: .leading, spacing: 3) {
                                    Button {
                                        showingSpeakerEditor = true
                                    } label: {
                                        Text(
                                            "\(SharedLibraryStore.clock(segment.startMs)) · \(speakerName(for: segment.speaker))"
                                        )
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    Text(segment.text)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(
                                    isSelectedSource(segment.startMs)
                                        ? Color.indigo.opacity(0.12)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 10)
                                )
                                .id(segment.startMs)
                            }
                        } else {
                            Text("Waiting for on-device or Mac transcription.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("Additional notes")
                            .font(.headline)
                        TextEditor(text: $notes)
                            .frame(minHeight: 150)
                            .padding(8)
                            .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                        Button("Save notes") {
                            model.updateRecordingNotes(notes, recordingID: recording.id)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
            }
            .onAppear {
                scrollToSelectedSource(with: proxy)
            }
            .onChange(of: model.selectedSource?.id) {
                scrollToSelectedSource(with: proxy)
            }
        }
        .navigationTitle("Recording")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: recording.speakerNames) { oldNames, newNames in
            if speakerNames == oldNames {
                speakerNames = newNames
            }
        }
        .sheet(isPresented: $showingSpeakerEditor) {
            MobileSpeakerNamesEditor(
                speakerIDs: speakerIDs,
                names: speakerNames
            ) { names in
                speakerNames = names
                model.updateSpeakerNames(names, recordingID: recording.id)
            }
        }
        .onDisappear {
            playback.stop()
        }
    }

    private var playbackControls: some View {
        HStack {
            Button {
                playback.toggle(recording)
            } label: {
                Label(
                    playback.isPlaying ? "Pause" : "Play recording",
                    systemImage: playback.isPlaying
                        ? "pause.fill"
                        : "play.fill"
                )
            }
            .buttonStyle(.borderedProminent)

            Button {
                playback.stop()
                model.toggleResume(recording)
            } label: {
                Label(
                    model.isResuming(recording.id)
                        ? "Stop \(model.recorder.elapsedLabel)"
                        : "Resume",
                    systemImage: model.isResuming(recording.id)
                        ? "stop.fill"
                        : "record.circle"
                )
            }
            .buttonStyle(.bordered)
            .tint(model.isResuming(recording.id) ? .red : .accentColor)
            .disabled(!model.canResume(recording.id))

            if playback.isPreparing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(playback.preparationLabel ?? "Preparing audio…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var summaryCard: some View {
        if let summary = recording.summary {
            VStack(alignment: .leading, spacing: 12) {
                Label("Meeting summary", systemImage: "text.page")
                    .font(.headline)
                Text(summary.overview)
                MobileSummarySection(
                    title: "Participants (\(summary.participantCount))",
                    values: summary.participants
                )
                MobileSummarySection(title: "Topics", values: summary.topics)
                MobileSummarySection(
                    title: "Decisions",
                    values: summary.decisions
                )
                MobileSummarySection(
                    title: "Action items",
                    values: summary.actionItems
                )
                Text("Generated locally on Mac with \(summary.model)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(
                .secondary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 14)
            )
        }
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

    private func speakerName(for speakerID: String) -> String {
        SharedSpeakerNameStore.displayName(for: speakerID, names: speakerNames)
    }

    private func isSelectedSource(_ startMs: Int) -> Bool {
        model.selectedSource?.itemID == "recording:\(recording.id)"
            && model.selectedSource?.startMs == startMs
    }

    private func scrollToSelectedSource(with proxy: ScrollViewProxy) {
        guard model.selectedSource?.itemID == "recording:\(recording.id)",
              let startMs = model.selectedSource?.startMs
        else { return }
        withAnimation {
            proxy.scrollTo(startMs, anchor: .center)
        }
    }
}

private struct MobileSummarySection: View {
    let title: String
    let values: [String]

    var body: some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Text("• \(value)")
                        .font(.subheadline)
                }
            }
        }
    }
}

private struct MobileSpeakerNamesEditor: View {
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
        NavigationStack {
            Form {
                Section {
                    ForEach(speakerIDs, id: \.self) { speakerID in
                        TextField(
                            SharedSpeakerNameStore.displayName(
                                for: speakerID,
                                names: [:]
                            ),
                            text: Binding(
                                get: { names[speakerID] ?? "" },
                                set: { names[speakerID] = $0 }
                            )
                        )
                    }
                } footer: {
                    Text("Names are saved with this recording and used in transcripts, search, and AI answers.")
                }

                Section {
                    Button("Clear all names", role: .destructive) {
                        names = [:]
                    }
                }
            }
            .navigationTitle("Name speakers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(SharedSpeakerNameStore.sanitized(names))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

@MainActor
private final class MobileRecordingPlayer: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isPreparing = false
    @Published private(set) var preparationLabel: String?
    @Published private(set) var errorMessage: String?

    private var player: AVPlayer?
    private var preparationTask: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var loadedSignature: String?

    func toggle(_ recording: SharedRecordingItem) {
        if isPlaying {
            player?.pause()
            isPlaying = false
            return
        }

        let signature = Self.signature(for: recording)
        if let player, loadedSignature == signature {
            errorMessage = nil
            player.play()
            isPlaying = true
            return
        }

        stop()
        isPreparing = true
        preparationLabel = "Checking audio…"
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let item = try await Self.makePlayerItem(
                    for: recording
                ) { [weak self] label in
                    self?.preparationLabel = label
                }
                try Task.checkCancellation()
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
                install(item, signature: signature)
            } catch is CancellationError {
                isPreparing = false
                preparationLabel = nil
            } catch {
                isPreparing = false
                preparationLabel = nil
                errorMessage =
                    "Couldn’t play this recording: \(error.localizedDescription)"
                try? AVAudioSession.sharedInstance().setActive(
                    false,
                    options: .notifyOthersOnDeactivation
                )
            }
        }
    }

    func stop() {
        preparationTask?.cancel()
        preparationTask = nil
        player?.pause()
        player = nil
        loadedSignature = nil
        isPlaying = false
        isPreparing = false
        preparationLabel = nil
        removeObservers()
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func install(_ item: AVPlayerItem, signature: String) {
        let player = AVPlayer(playerItem: item)
        self.player = player
        loadedSignature = signature
        isPreparing = false
        preparationLabel = nil
        errorMessage = nil

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.player?.seek(to: .zero)
                self?.isPlaying = false
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let failure = notification.userInfo?[
                AVPlayerItemFailedToPlayToEndTimeErrorKey
            ] as? Error
            Task { @MainActor in
                self?.isPlaying = false
                self?.errorMessage =
                    "Playback stopped: \(failure?.localizedDescription ?? "unknown audio error")"
            }
        }

        player.play()
        isPlaying = true
    }

    private func removeObservers() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
        }
        endObserver = nil
        failureObserver = nil
    }

    private static func makePlayerItem(
        for recording: SharedRecordingItem,
        onProgress: @escaping @MainActor (String) -> Void
    ) async throws -> AVPlayerItem {
        let tracks: [SharedRecordingAudioTrack]
        if !recording.audioTracks.isEmpty {
            tracks = recording.audioTracks
        } else if let audioURL = recording.audioURL {
            tracks = [
                SharedRecordingAudioTrack(
                    url: audioURL,
                    speaker: "me",
                    offsetMs: 0
                ),
            ]
        } else {
            throw PlaybackError.noAudio
        }

        // Start every cloud-backed track together. The validation/insertion
        // loop below can stay deterministic while mic and system audio
        // download in parallel.
        let fileManager = FileManager.default
        for track in tracks {
            let values = try? track.url.resourceValues(forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey,
            ])
            if values?.isUbiquitousItem == true,
               values?.ubiquitousItemDownloadingStatus != .current {
                try? fileManager.startDownloadingUbiquitousItem(at: track.url)
            }
        }

        let composition = AVMutableComposition()
        var insertedAudio = false
        var lastFailure: Error?
        for (index, track) in tracks.enumerated() {
            do {
                try await ensureAudioIsLocal(
                    track.url,
                    trackNumber: index + 1,
                    trackCount: tracks.count,
                    onProgress: onProgress
                )
                onProgress("Preparing track \(index + 1) of \(tracks.count)…")
                let asset = AVURLAsset(url: track.url)
                let duration = try await asset.load(.duration)
                guard duration.isValid, duration > .zero,
                      let sourceTrack = try await asset.loadTracks(
                          withMediaType: .audio
                      ).first,
                      let destinationTrack = composition.addMutableTrack(
                          withMediaType: .audio,
                          preferredTrackID: kCMPersistentTrackID_Invalid
                      )
                else { continue }
                try destinationTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: sourceTrack,
                    at: CMTime(
                        value: Int64(max(track.offsetMs, 0)),
                        timescale: 1_000
                    )
                )
                insertedAudio = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastFailure = error
            }
        }
        guard insertedAudio else {
            throw lastFailure ?? PlaybackError.noPlayableTrack
        }
        return AVPlayerItem(asset: composition)
    }

    private static func ensureAudioIsLocal(
        _ url: URL,
        trackNumber: Int,
        trackCount: Int,
        onProgress: @escaping @MainActor (String) -> Void
    ) async throws {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        var values = try? url.resourceValues(forKeys: keys)
        guard values?.isUbiquitousItem == true,
              values?.ubiquitousItemDownloadingStatus != .current
        else {
            guard (try? url.checkResourceIsReachable()) == true else {
                throw PlaybackError.audioUnavailable
            }
            return
        }

        do {
            try fileManager.startDownloadingUbiquitousItem(at: url)
        } catch {
            throw PlaybackError.downloadFailed(error.localizedDescription)
        }

        let deadline = ContinuousClock.now + .seconds(180)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            values = try? url.resourceValues(forKeys: keys)
            if values?.ubiquitousItemDownloadingStatus == .current,
               (try? url.checkResourceIsReachable()) == true {
                return
            }
            let track = trackCount > 1
                ? " track \(trackNumber) of \(trackCount)"
                : ""
            onProgress("Downloading\(track) from iCloud…")
            try await Task.sleep(for: .milliseconds(500))
        }
        throw PlaybackError.downloadTimedOut
    }

    private static func signature(for recording: SharedRecordingItem) -> String {
        recording.audioTracks
            .map { "\($0.url.path)|\($0.offsetMs)" }
            .joined(separator: ";")
            + "|\(recording.durationSeconds)"
    }

    private enum PlaybackError: LocalizedError {
        case noAudio
        case noPlayableTrack
        case audioUnavailable
        case downloadFailed(String)
        case downloadTimedOut

        var errorDescription: String? {
            switch self {
            case .noAudio:
                "This recording has no audio files."
            case .noPlayableTrack:
                "Its audio files are not available on this iPhone yet."
            case .audioUnavailable:
                "The audio file is not available on this iPhone."
            case .downloadFailed(let message):
                "Couldn’t download its audio from iCloud: \(message)"
            case .downloadTimedOut:
                "Downloading its audio from iCloud timed out. Try Play again."
            }
        }
    }
}

private struct MobilePDFView: UIViewRepresentable {
    let url: URL
    let targetPage: Int?

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        goToTargetPage(in: view)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.documentURL != url {
            uiView.document = PDFDocument(url: url)
        }
        goToTargetPage(in: uiView)
    }

    private func goToTargetPage(in view: PDFView) {
        guard let targetPage,
              targetPage > 0,
              let page = view.document?.page(at: targetPage - 1)
        else { return }
        view.go(to: page)
    }
}
