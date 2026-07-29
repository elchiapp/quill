import SwiftUI

struct ChatDetailView: View {
    @ObservedObject var model: AppModel
    let thread: ChatThread

    @FocusState private var isComposerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            Divider()
            messages
            composer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: thread.id) {
            // Let the navigation split view install the new detail hierarchy
            // before asking AppKit to make the composer first responder.
            await Task.yield()
            isComposerFocused = true
        }
    }

    private var chatHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(thread.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text("Private local AI · transcript-grounded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                Button {
                    model.setScope(.all, for: thread.id)
                } label: {
                    if thread.scope.kind == .allRecordings {
                        Label("All recordings", systemImage: "checkmark")
                    } else {
                        Text("All recordings")
                    }
                }

                if !model.recordings.isEmpty {
                    Divider()
                    ForEach(model.recordings) { recording in
                        Button {
                            model.setScope(.recording(recording.id), for: thread.id)
                        } label: {
                            if thread.scope.recordingID == recording.id {
                                Label(recording.title, systemImage: "checkmark")
                            } else {
                                Text(recording.title)
                            }
                        }
                    }
                }

                Divider()
                Button(role: .destructive) {
                    model.requestDeleteThread(thread)
                } label: {
                    Label("Delete Conversation", systemImage: "trash")
                }
            } label: {
                Label(scopeLabel, systemImage: "scope")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(20)
    }

    @ViewBuilder
    private var messages: some View {
        if thread.messages.isEmpty {
            VStack(spacing: 18) {
                Spacer()
                Image(systemName: "sparkles")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                Text("Ask your recordings")
                    .font(.title2.weight(.semibold))
                Text("Dropsift retrieves relevant transcript passages and answers with its built-in local model.")
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
                    LazyVStack(spacing: 18) {
                        ForEach(thread.messages) { message in
                            ChatBubble(
                                message: message,
                                onSourceSelected: model.openSource
                            )
                                .id(message.id)
                        }
                        if model.chatStage != .idle {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(pipelineStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 24)
                        }
                    }
                    .padding(.vertical, 24)
                }
                .onChange(of: thread.messages.count) {
                    if let last = thread.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
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
                    "Ask a question about your transcripts…",
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

            Text("Nothing is sent to an inference service. Answers run inside Dropsift with \(model.selectedModel).")
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
            return "All recordings"
        }
        return model.recordings.first { $0.id == thread.scope.recordingID }?.title
            ?? "Selected recording"
    }

    private var pipelineStatus: String {
        switch model.chatStage {
        case .idle:
            ""
        case .retrieving:
            "Searching \(model.recordings.count) transcript\(model.recordings.count == 1 ? "" : "s") for relevant sources…"
        case .preparingAI:
            switch model.aiStatus {
            case .downloading(let fraction):
                "Downloading \(model.selectedModelPlan.model.name) · \(Int(fraction * 100))%…"
            case .loading:
                "Loading \(model.selectedModelPlan.model.name) into memory…"
            case .downloaded:
                "Preparing downloaded \(model.selectedModelPlan.model.name)…"
            default:
                "Preparing Dropsift’s built-in model…"
            }
        case .generating:
            "Generating locally with \(model.selectedModel)…"
        }
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    let onSourceSelected: (ChatSource) -> Void

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 100) }

            VStack(alignment: .leading, spacing: 7) {
                Text(message.role == .user ? "You" : "Dropsift")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(.init(message.content))
                    .textSelection(.enabled)
                    .lineSpacing(4)

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
                                        Text(TranscriptDocument.clock(source.startMs))
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
                        .help("Open this transcript at \(TranscriptDocument.clock(source.startMs))")
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
            .frame(maxWidth: 720, alignment: .leading)

            if message.role == .assistant { Spacer(minLength: 80) }
        }
        .padding(.horizontal, 24)
    }
}
