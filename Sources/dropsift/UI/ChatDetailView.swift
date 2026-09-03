import AppKit
import SwiftUI

struct ChatDetailView: View {
    @ObservedObject var model: AppModel
    let thread: ChatThread

    @FocusState private var isComposerFocused: Bool
    @State private var showingScopePicker = false

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            Divider()
            messages
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .leading
                )
            composer
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var chatHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                TextField("Conversation title", text: titleBinding)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .accessibilityIdentifier("conversation-title")
                if model.regeneratingThreadID == thread.id {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Generating a better title locally…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Private local AI · source-grounded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                showingScopePicker.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "scope")
                    Text(scopeLabel)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 420)
            .popover(isPresented: $showingScopePicker, arrowEdge: .top) {
                ChatScopePicker(
                    recordings: model.recordings,
                    selectedScope: thread.scope
                ) { scope in
                    model.setScope(scope, for: thread.id)
                    showingScopePicker = false
                }
            }

            Menu {
                Button(role: .destructive) {
                    model.requestDeleteThread(thread)
                } label: {
                    Label("Delete Conversation", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(20)
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: {
                model.threads.first(where: { $0.id == thread.id })?.title
                    ?? thread.title
            },
            set: { model.renameThread(thread.id, to: $0) }
        )
    }

    @ViewBuilder
    private var messages: some View {
        if thread.messages.isEmpty {
            VStack(spacing: 18) {
                Spacer()
                Image(systemName: "sparkles")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                Text("Ask your knowledge")
                    .font(.title2.weight(.semibold))
                Text("DropSift searches recordings, notes, documents, and image text with its built-in local model.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                HStack {
                    suggestion("What decisions did we make?")
                    suggestion("Summarize the key action items")
                    suggestion("What came up repeatedly?")
                }
                Spacer()
            }
            .padding(28)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(thread.messages) { message in
                            ChatBubble(
                                message: message,
                                isStreaming: (
                                    model.chatStage == .readingSources
                                        || model.chatStage == .generating
                                )
                                    && message.id == thread.messages.last?.id
                                    && message.role == .assistant,
                                streamingStatus: model.chatContextStatus,
                                onSourceSelected: model.openSource
                            )
                            .id(message.id)
                        }
                        if model.chatStage != .idle {
                            pipelineProgress
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .containerRelativeFrame(.horizontal, alignment: .leading)
                    .padding(.vertical, 24)
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .leading
                )
                .onChange(of: thread.messages.count) {
                    if let last = thread.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: thread.messages.last?.content) {
                    if let last = thread.messages.last,
                       model.chatStage == .generating {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.chatError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(alignment: .center, spacing: 10) {
                TextField(
                    "Ask a question about anything in DropSift…",
                    text: $model.chatDraft,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($isComposerFocused)
                .accessibilityIdentifier("chat-composer")
                .onSubmit {
                    if !NSEvent.modifierFlags.contains(.shift) {
                        model.sendChatMessage()
                    }
                }

                Button {
                    model.sendChatMessage()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .disabled(
                    model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.isAnswering
                )
            }
            .padding(.leading, 14)
            .padding(.vertical, 8)
            .padding(.trailing, 8)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))

            Text("Nothing is sent to an inference service. Answers run inside DropSift with \(model.selectedModel).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(.bar)
    }

    private func suggestion(_ text: String) -> some View {
        Button(text) {
            model.chatDraft = text
            model.sendChatMessage()
        }
        .buttonStyle(.bordered)
    }

    private var scopeLabel: String {
        if thread.scope.kind == .allRecordings {
            return "All knowledge"
        }
        return model.recordings.first { $0.id == thread.scope.recordingID }?.title
            ?? "Selected recording"
    }

    private var pipelineStatus: String {
        switch model.chatStage {
        case .idle:
            ""
        case .retrieving:
            "Searching \(model.timelineItems.count) timeline item\(model.timelineItems.count == 1 ? "" : "s") for relevant sources…"
        case .preparingAI:
            switch model.aiStatus {
            case .downloading(let fraction):
                "Downloading \(model.selectedModelPlan.model.name) · \(Int(fraction * 100))%…"
            case .loading:
                "Loading \(model.selectedModelPlan.model.name) into memory…"
            case .downloaded:
                "Preparing downloaded \(model.selectedModelPlan.model.name)…"
            default:
                model.chatContextStatus
                    ?? "Preparing DropSift’s built-in model…"
            }
        case .readingSources:
            model.chatContextStatus
                ?? "Reading the selected source excerpts…"
        case .generating:
            "Generating locally with \(model.selectedModel)…"
        }
    }

    private var pipelineProgress: some View {
        let steps = ["Search", "Prepare", "Read", "Answer"]
        let current = switch model.chatStage {
        case .idle: 4
        case .retrieving: 0
        case .preparingAI: 1
        case .readingSources: 2
        case .generating: 3
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 5) {
                        if index < current {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if index == current {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(.tertiary)
                        }
                        Text(step)
                            .foregroundStyle(
                                index == current ? .primary : .secondary
                            )
                    }
                    if index < steps.count - 1 {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.22))
                            .frame(width: 18, height: 1)
                    }
                }
            }
            .font(.caption.weight(.medium))
            Text(pipelineStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChatScopePicker: View {
    let recordings: [RecordingItem]
    let selectedScope: ChatScope
    let onSelect: (ChatScope) -> Void

    @State private var query = ""
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(12)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    scopeRow(
                        title: "All knowledge",
                        subtitle: "Search every recording, note, document, and image",
                        systemImage: "square.stack.3d.up",
                        isSelected: selectedScope.kind == .allRecordings
                    ) {
                        onSelect(.all)
                    }

                    if !filteredRecordings.isEmpty {
                        Text(query.isEmpty ? "RECORDINGS" : "MATCHING RECORDINGS")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 10)
                            .padding(.bottom, 3)

                        ForEach(filteredRecordings) { recording in
                            scopeRow(
                                title: recording.title,
                                subtitle: recordingSubtitle(recording),
                                systemImage: "waveform",
                                isSelected: selectedScope.recordingID == recording.id
                            ) {
                                onSelect(.recording(recording.id))
                            }
                        }
                    } else if !query.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 34)
                    } else {
                        ContentUnavailableView(
                            "No recordings yet",
                            systemImage: "waveform",
                            description: Text("New recordings will appear here automatically.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 34)
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 440, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await Task.yield()
            searchIsFocused = true
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search recordings", text: $query)
                .textFieldStyle(.plain)
                .focused($searchIsFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 9)
        )
    }

    private var filteredRecordings: [RecordingItem] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return recordings }
        return recordings.filter { recording in
            normalized(
                recording.title + " " + recording.notes + " " + recording.preview
            ).contains(needle)
        }
    }

    private func scopeRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: systemImage)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.accentColor.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 9)
            )
        }
        .buttonStyle(.plain)
    }

    private func recordingSubtitle(_ recording: RecordingItem) -> String {
        "\(recording.displayDate) · \(recording.displayDuration)"
    }

    private func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    let isStreaming: Bool
    let streamingStatus: String?
    let onSourceSelected: (ChatSource) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 48)
            }
            bubble
                .frame(
                    maxWidth: message.role == .user
                        ? ChatMessageLayoutPolicy.maximumUserBubbleWidth
                        : .infinity,
                    alignment: .leading
                )
        }
        .padding(.horizontal, ChatMessageLayoutPolicy.horizontalPadding)
        .frame(
            maxWidth: .infinity,
            alignment: message.role == .user ? .trailing : .leading
        )
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Text(message.role == .user ? "You" : "DropSift")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer(minLength: 8)
                if !message.content.isEmpty {
                    Button {
                        copyMessage()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Copy message")
                    .accessibilityLabel("Copy message")
                }
            }
            if !message.content.isEmpty {
                Text(.init(message.content))
                    .lineSpacing(4)
            } else if isStreaming {
                Text(streamingStatus ?? "Starting the local response…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !message.sources.isEmpty {
                Divider()
                    .padding(.vertical, 3)
                Text("Sources")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(message.sources) { source in
                    Button {
                        onSourceSelected(source)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Text("[\(source.number)]")
                                .font(.caption.monospaced().weight(.semibold))
                                .foregroundStyle(.tint)
                                .frame(width: 28, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(source.recordingTitle)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(source.locationLabel)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Text(source.excerpt.replacingOccurrences(of: "\n", with: " "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Image(systemName: "arrow.right.circle")
                                .foregroundStyle(.tertiary)
                        }
                        .padding(9)
                        .background(
                            Color(nsColor: .textBackgroundColor).opacity(0.7),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(source.recordingTitle) at \(source.locationLabel)")
                }
            }
        }
        .padding(14)
        .background(
            message.role == .user
                ? Color.accentColor.opacity(0.14)
                : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14)
        )
    }

    private func copyMessage() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.content, forType: .string)
    }
}

enum ChatMessageLayoutPolicy {
    static let horizontalPadding: CGFloat = 24
    static let maximumUserBubbleWidth: CGFloat = 720
}
