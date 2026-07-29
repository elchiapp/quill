import SwiftUI

struct QuillRootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } content: {
            collectionColumn
                .navigationSplitViewColumnWidth(min: 270, ideal: 320, max: 420)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 980, minHeight: 650)
        .toolbar {
            ToolbarItemGroup {
                if let status = model.transcriptionStatus {
                    Label(status, systemImage: "waveform.badge.magnifyingglass")
                        .foregroundStyle(.secondary)
                }

                Button {
                    model.toggleRecording()
                } label: {
                    Label(
                        model.isRecording
                            ? "Stop \(model.recordingElapsed)"
                            : "New recording",
                        systemImage: model.isRecording ? "stop.fill" : "record.circle"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isRecording ? .red : .accentColor)
                .help(model.isRecording ? "Stop recording" : "Start a new recording")

                Button {
                    model.showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Quill settings")
            }
        }
        .sheet(isPresented: $model.showingSettings) {
            SettingsView(model: model)
        }
        .sheet(isPresented: $model.showingModelRecommendation) {
            ModelRecommendationView(model: model)
        }
        .alert(
            "Quill",
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
                Image(systemName: "pencil")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Quill")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            List(selection: $model.section) {
                Label("Recordings", systemImage: "waveform")
                    .tag(AppModel.Section.recordings)
                Label("Ask Quill", systemImage: "sparkles")
                    .tag(AppModel.Section.chats)
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
    private var collectionColumn: some View {
        switch model.section {
        case .recordings:
            RecordingsColumn(model: model)
        case .chats:
            ChatsColumn(model: model)
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            if model.isRecording {
                LiveRecordingNotesView(model: model)
                Divider()
            }
            detailContent
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch model.section {
        case .recordings:
            if let recording = model.selectedRecording {
                RecordingDetailView(model: model, recording: recording)
                    .id(recording.id + recording.title + "\(recording.segmentCount)")
            } else {
                ContentUnavailableView(
                    "No recording selected",
                    systemImage: "waveform",
                    description: Text("Start a recording or select one from the library.")
                )
            }
        case .chats:
            if let thread = model.selectedThread {
                ChatDetailView(model: model, thread: thread)
                    .id(thread.id)
            } else {
                ContentUnavailableView {
                    Label("Ask your meetings", systemImage: "sparkles")
                } description: {
                    Text("Create a private local-AI conversation across your transcripts.")
                } actions: {
                    Button("New conversation") { model.createThread() }
                        .buttonStyle(.borderedProminent)
                }
            }
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
            "Downloading \(model.selectedModelPlan.model.name) · \(Int(fraction * 100))%"
        case .loading:
            "Loading \(model.selectedModelPlan.model.name)…"
        case .ready:
            "\(model.selectedModelPlan.model.name) ready"
        case .failed:
            "Built-in AI needs attention"
        }
    }
}
private struct RecordingsColumn: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            columnHeader(
                title: "Recordings",
                count: model.recordings.count,
                action: model.openRecordingsFolder
            )

            if model.filteredRecordings.isEmpty {
                ContentUnavailableView {
                    Label("No recordings", systemImage: "waveform")
                } description: {
                    Text(
                        model.recordingSearch.isEmpty
                            ? "Your meetings will appear here."
                            : "No recordings match your search."
                    )
                }
            } else {
                List(model.filteredRecordings, selection: $model.selectedRecordingID) { recording in
                    RecordingRow(recording: recording)
                        .tag(recording.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                model.requestDeleteRecording(recording)
                            } label: {
                                Label("Move Recording to Trash", systemImage: "trash")
                            }
                        }
                }
                .listStyle(.inset)
            }
        }
        .searchable(text: $model.recordingSearch, prompt: "Search recordings")
    }

    private func columnHeader(
        title: String,
        count: Int,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
                .font(.title3.weight(.semibold))
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: action) {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .help("Open recordings in Finder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct RecordingRow: View {
    let recording: RecordingItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(recording.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: recording.isTranscribed ? "checkmark.circle.fill" : "clock")
                    .foregroundStyle(recording.isTranscribed ? Color.green : Color.secondary)
                    .font(.caption)
            }

            Text(recording.displayDate + " · " + recording.displayDuration)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(recording.preview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 5)
    }
}

private struct ChatsColumn: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Conversations")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    model.createThread()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .help("New conversation")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if model.threads.isEmpty {
                ContentUnavailableView {
                    Label("No conversations", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Ask questions across one or all transcripts.")
                } actions: {
                    Button("New conversation") { model.createThread() }
                }
            } else {
                List(model.threads) { thread in
                    Button {
                        model.selectedThreadID = thread.id
                    } label: {
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
                                        ? "All recordings"
                                        : "One recording"
                                )
                                Spacer()
                                Text(thread.updatedAt, style: .relative)
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
            }
        }
    }
}

private struct LiveRecordingNotesView: View {
    @ObservedObject var model: AppModel

    private var notes: Binding<String> {
        Binding(
            get: { model.liveNotes },
            set: { model.updateLiveNotes($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 9, height: 9)
                    .symbolEffect(.pulse, options: .repeating)
                Text("Recording \(model.recordingElapsed)")
                    .font(.headline.monospacedDigit())
                Text("Live notes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Label("Autosaved", systemImage: "icloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ZStack(alignment: .topLeading) {
                if model.liveNotes.isEmpty {
                    Text("Take notes while Quill records…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                }
                TextEditor(text: notes)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .accessibilityIdentifier("live-recording-notes")
            }
            .frame(minHeight: 74, maxHeight: 120)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.08))
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.red.opacity(0.035))
    }
}
