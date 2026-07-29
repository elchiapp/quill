import SwiftUI

struct DropsiftRootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1_050, minHeight: 680)
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

                if model.isRecording {
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
                Label("Capture", systemImage: "plus.app")
                    .tag(AppModel.Section.capture)
                Label("Timeline", systemImage: "clock.arrow.circlepath")
                    .tag(AppModel.Section.timeline)
                Label("Ask Dropsift", systemImage: "sparkles")
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
        case .capture:
            CaptureView(model: model)
        case .timeline:
            TimelineView(model: model)
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
                    Text("Ask questions across your entire knowledge timeline.")
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
                                        ? "All knowledge"
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
                    Text("Take notes while Dropsift records…")
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
