import DropsiftShared
import Foundation
import SwiftUI

struct DropsiftRootView: View {
    @ObservedObject var model: AppModel
    @State private var showingLiveNotesPanel = true

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
                .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: minimumWindowWidth, minHeight: 680)
        .toolbar {
            ToolbarItemGroup {
                if let status = model.transcriptionStatus {
                    Label(status, systemImage: "waveform.badge.magnifyingglass")
                        .foregroundStyle(.secondary)
                }

                if let state = model.ingestionState {
                    HStack(spacing: 7) {
                        ProgressView(value: state.progress)
                            .frame(width: 80)
                        Text(state.currentName)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                }

                if let label = model.semanticProcessingLabel {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text(label)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                }

                if isShowingRecordingUI {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showingLiveNotesPanel.toggle()
                        }
                    } label: {
                        Image(
                            systemName: showingLiveNotesPanel
                                ? "rectangle.righthalf.inset.filled"
                                : "note.text"
                        )
                    }
                    .help(
                        showingLiveNotesPanel
                            ? "Collapse live notes"
                            : "Show live notes"
                    )

                    Button {
                        model.stopRecording()
                    } label: {
                        Label("Stop \(model.recordingElapsed)", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }

                Button {
                    model.showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Dropsift settings")
            }
        }
        .sheet(isPresented: $model.showingSettings) {
            SettingsView(model: model)
        }
        .sheet(isPresented: $model.showingModelRecommendation) {
            ModelRecommendationView(model: model)
        }
        .alert(
            "Dropsift",
            isPresented: Binding(
                get: { model.appError != nil },
                set: { if !$0 { model.appError = nil } }
            )
        ) {
            Button("OK") { model.appError = nil }
        } message: {
            Text(model.appError ?? "")
        }
        .confirmationDialog(
            model.deletionRequest?.confirmationTitle ?? "Delete?",
            isPresented: deletionConfirmationPresented,
            titleVisibility: .visible,
            presenting: model.deletionRequest
        ) { request in
            Button(request.actionTitle, role: .destructive) {
                model.confirmDeletion(request)
            }
            Button("Cancel", role: .cancel) {
                model.cancelDeletion()
            }
        } message: { request in
            Text(request.message)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Dropsift")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            List(selection: $model.section) {
                Section {
                    Label("Capture", systemImage: "plus.app")
                        .tag(AppModel.Section.capture)
                    Label("Timeline", systemImage: "clock.arrow.circlepath")
                        .tag(AppModel.Section.timeline)
                    Label("Ask Dropsift", systemImage: "sparkles")
                        .tag(AppModel.Section.chats)
                }

                Section("Organize") {
                    Label("Tasks", systemImage: "checklist")
                        .tag(AppModel.Section.tasks)
                    Label("People", systemImage: "person.2")
                        .tag(AppModel.Section.people)
                    Label("Places", systemImage: "mappin.and.ellipse")
                        .tag(AppModel.Section.places)
                    Label("Events", systemImage: "calendar")
                        .tag(AppModel.Section.events)
                    Label("Organizations", systemImage: "building.2")
                        .tag(AppModel.Section.organizations)
                    Label("Projects", systemImage: "folder")
                        .tag(AppModel.Section.projects)
                    Label("Topics", systemImage: "tag")
                        .tag(AppModel.Section.topics)
                }
            }
            .listStyle(.sidebar)

            VStack(alignment: .leading, spacing: 8) {
                Label(model.storageLabel, systemImage: "icloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    model.showingSettings = true
                } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(aiStatusColor)
                            .frame(width: 7, height: 7)
                        Text(aiStatusLabel)
                            .lineLimit(1)
                        Spacer()
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if isShowingRecordingUI, showingLiveNotesPanel {
            HSplitView {
                detailContent
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)

                LiveRecordingNotesView(model: model) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingLiveNotesPanel = false
                    }
                }
                .frame(minWidth: 330, idealWidth: 370, maxWidth: 420)
                .layoutPriority(0)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            .onChange(of: model.isRecording) { _, recording in
                if recording {
                    showingLiveNotesPanel = true
                }
            }
        } else {
            detailContent
                .onChange(of: model.isRecording) { _, recording in
                    if recording {
                        showingLiveNotesPanel = true
                    }
                }
        }
    }

    private var isShowingRecordingUI: Bool {
        model.isRecording
            || ProcessInfo.processInfo.environment[
                "DROPSIFT_PREVIEW_RECORDING_PANEL"
            ] == "1"
    }

    private var minimumWindowWidth: CGFloat {
        1_400
    }

    @ViewBuilder
    private var detailContent: some View {
        switch model.section {
        case .capture:
            CaptureView(model: model)
        case .timeline:
            TimelineView(model: model)
        case .tasks:
            TasksView(model: model)
        case .people:
            SemanticEntitiesView(model: model, kind: .person)
        case .places:
            SemanticEntitiesView(model: model, kind: .place)
        case .events:
            SemanticEntitiesView(model: model, kind: .event)
        case .organizations:
            SemanticEntitiesView(model: model, kind: .organization)
        case .projects:
            SemanticEntitiesView(model: model, kind: .project)
        case .topics:
            SemanticEntitiesView(model: model, kind: .topic)
        case .chats:
            chatWorkspace
        }
    }

    private var chatWorkspace: some View {
        HSplitView {
            ChatsColumn(model: model)
                .frame(minWidth: 270, idealWidth: 310, maxWidth: 340)
            Group {
                if let thread = model.selectedThread {
                    ChatDetailView(model: model, thread: thread)
                        .id(thread.id)
                } else {
                    ContentUnavailableView {
                        Label("Ask your knowledge", systemImage: "sparkles")
                    } description: {
                        Text("Create a private local-AI conversation across everything in Dropsift.")
                    } actions: {
                        Button("New conversation") { model.createThread() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var deletionConfirmationPresented: Binding<Bool> {
        Binding(
            get: { model.deletionRequest != nil },
            set: { if !$0 { model.cancelDeletion() } }
        )
    }

    private var aiStatusColor: Color {
        switch model.aiStatus {
        case .notDownloaded, .downloaded: .secondary
        case .downloading, .loading: .orange
        case .ready: .green
        case .failed: .red
        }
    }

    private var aiStatusLabel: String {
        switch model.aiStatus {
        case .notDownloaded:
            "\(model.selectedModelPlan.model.name) · download on first use"
        case .downloaded:
            "\(model.selectedModelPlan.model.name) · ready to load"
        case .downloading(let fraction):
            model.aiDownloadIsStalled
                ? "Download stalled · open Settings to retry"
                : "Downloading \(model.selectedModelPlan.model.name) · \(Self.percent(fraction))"
        case .loading:
            "Loading \(model.selectedModelPlan.model.name)…"
        case .ready:
            "\(model.selectedModelPlan.model.name) ready"
        case .failed:
            "Built-in AI needs attention"
        }
    }

    private static func percent(_ fraction: Double) -> String {
        let percentage = max(0, min(100, fraction * 100))
        return percentage < 10
            ? String(format: "%.1f%%", percentage)
            : String(format: "%.0f%%", percentage)
    }
}
private struct ChatsColumn: View {
    @ObservedObject var model: AppModel
    @State private var isSelecting = false
    @State private var selection = Set<UUID>()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Conversations")
                    .font(.title3.weight(.semibold))
                Spacer()
                if isSelecting {
                    Button(selectionContainsAll ? "Clear" : "All") {
                        toggleSelectAll()
                    }
                    .buttonStyle(.plain)
                    Button("Done") { endSelecting() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        isSelecting = true
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Select multiple conversations")
                    Button {
                        model.createThread()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .buttonStyle(.plain)
                    .help("New conversation")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if model.threads.isEmpty {
                ContentUnavailableView {
                    Label("No conversations", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Ask questions across your entire knowledge timeline.")
                } actions: {
                    Button("New conversation") { model.createThread() }
                }
            } else {
                List(model.threads) { thread in
                    Button {
                        if isSelecting {
                            toggleSelection(thread.id)
                        } else {
                            model.selectedThreadID = thread.id
                        }
                    } label: {
                        HStack(spacing: 9) {
                            if isSelecting {
                                Image(
                                    systemName: selection.contains(thread.id)
                                        ? "checkmark.circle.fill"
                                        : "circle"
                                )
                                .font(.title3)
                                .foregroundStyle(
                                    selection.contains(thread.id)
                                        ? Color.accentColor
                                        : Color.secondary
                                )
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(thread.title)
                                    .font(.body.weight(.medium))
                                    .lineLimit(2)
                                HStack {
                                    Image(systemName: thread.scope.kind == .allRecordings
                                        ? "rectangle.stack"
                                        : "waveform")
                                    Text(
                                        thread.scope.kind == .allRecordings
                                            ? "All knowledge"
                                            : "One recording"
                                    )
                                    Spacer()
                                    Text(thread.updatedAt, style: .relative)
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            model.selectedThreadID == thread.id
                                ? Color.accentColor.opacity(0.18)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(
                        model.selectedThreadID == thread.id ? .isSelected : []
                    )
                    .listRowInsets(EdgeInsets(top: 2, leading: 5, bottom: 2, trailing: 5))
                    .listRowBackground(Color.clear)
                    .contextMenu {
                        Button(role: .destructive) {
                            model.requestDeleteThread(thread)
                        } label: {
                            Label("Delete Conversation", systemImage: "trash")
                        }
                    }
                }
                .listStyle(.inset)
                if isSelecting {
                    Divider()
                    HStack {
                        Text("\(selection.count) selected")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            selection.forEach(model.regenerateThreadTitle)
                            endSelecting()
                        } label: {
                            Image(systemName: "sparkles")
                        }
                        .disabled(selection.isEmpty)
                        .help("Regenerate selected conversation titles")
                        Button(role: .destructive) {
                            model.requestDeleteThreads(selection)
                            endSelecting()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(selection.isEmpty)
                        .help("Delete selected conversations")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.bar)
                }
            }
        }
        .onChange(of: model.threads.map(\.id)) { _, visibleIDs in
            selection.formIntersection(Set(visibleIDs))
        }
    }

    private var selectionContainsAll: Bool {
        let visible = Set(model.threads.map(\.id))
        return !visible.isEmpty && visible.isSubset(of: selection)
    }

    private func toggleSelection(_ id: UUID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func toggleSelectAll() {
        let visible = Set(model.threads.map(\.id))
        if visible.isSubset(of: selection) {
            selection.subtract(visible)
        } else {
            selection.formUnion(visible)
        }
    }

    private func endSelecting() {
        isSelecting = false
        selection.removeAll()
    }
}

private struct LiveRecordingNotesView: View {
    @ObservedObject var model: AppModel
    let onCollapse: () -> Void

    private var notes: Binding<String> {
        Binding(
            get: { model.liveNotes },
            set: { model.updateLiveNotes($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Circle()
                        .fill(.red)
                        .frame(width: 9, height: 9)
                        .symbolEffect(.pulse, options: .repeating)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live notes")
                            .font(.headline)
                        Text("Recording \(model.recordingElapsed)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(action: onCollapse) {
                        Label("Hide", systemImage: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .contentShape(Rectangle())
                    .help("Collapse live notes")
                }

                HStack(spacing: 8) {
                    LiveAudioIndicator(
                        label: "Mic",
                        systemImage: "mic.fill",
                        samples: model.microphoneAudioLevels,
                        tint: .red
                    )
                    LiveAudioIndicator(
                        label: "System",
                        systemImage: "macbook",
                        samples: model.systemAudioLevels,
                        tint: .orange
                    )
                    Spacer()
                    Label("Autosaved", systemImage: "icloud")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            MarkdownNoteEditor(
                text: notes,
                placeholder: "Take notes while Dropsift records…",
                accessibilityIdentifier: "live-recording-notes"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
