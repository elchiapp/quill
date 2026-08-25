import DropsiftShared
import SwiftUI

struct MobileAskView: View {
    @ObservedObject var model: MobileAppModel
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            modelPicker

            Divider()

            if model.chatMessages.isEmpty {
                ContentUnavailableView {
                    Label("Ask your knowledge", systemImage: "sparkles")
                } description: {
                    Text(
                        "Search recordings, transcripts, notes, documents, and image text. Answers stay on this iPhone."
                    )
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(model.chatMessages) { message in
                                chatBubble(message)
                                    .id(message.id)
                            }
                            if model.isAnswering {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text("Searching and answering locally…")
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding()
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: model.chatMessages.count) {
                        if let last = model.chatMessages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }

            Divider()

            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    "Ask anything in Dropsift…",
                    text: $model.chatDraft,
                    axis: .vertical
                )
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .focused($composerFocused)
                .submitLabel(.send)
                .onSubmit { sendMessage() }

                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.headline)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .disabled(
                    model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.isAnswering
                )
            }
            .padding()
            .background(.bar)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Ask Dropsift")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    leaveAsk()
                } label: {
                    Label("Timeline", systemImage: "chevron.left")
                }
                .accessibilityHint("Dismisses the keyboard and opens Timeline")
            }

            ToolbarItemGroup(placement: .keyboard) {
                Button {
                    leaveAsk()
                } label: {
                    Label("Timeline", systemImage: "chevron.left")
                }
                Spacer()
                Button("Done") {
                    composerFocused = false
                }
                .fontWeight(.semibold)
            }
        }
        .onAppear { composerFocused = true }
        .onDisappear { composerFocused = false }
        .onChange(of: model.selectedTab) { _, tab in
            if tab != .ask { composerFocused = false }
        }
    }

    private func leaveAsk() {
        composerFocused = false
        model.selectedTab = .timeline
    }

    private func sendMessage() {
        composerFocused = false
        model.ask()
    }

    private var modelPicker: some View {
        Menu {
            ForEach(MobileAnswerModel.allCases) { answerModel in
                Button {
                    model.selectAnswerModel(answerModel)
                } label: {
                    if model.selectedAnswerModel == answerModel {
                        Label(answerModel.name, systemImage: "checkmark")
                    } else {
                        Text(answerModel.name)
                    }
                }
                .disabled(!model.isAnswerModelAvailable(answerModel))
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(.indigo)
                    .frame(width: 28, height: 28)
                    .background(
                        Color.indigo.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 8)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.answerModelLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(model.answerModelDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .accessibilityLabel("Answer model, \(model.answerModelLabel)")
        .accessibilityHint("Double tap to choose the answer model")
    }

    @ViewBuilder
    private func chatBubble(_ message: MobileChatMessage) -> some View {
        VStack(
            alignment: message.role == .user ? .trailing : .leading,
            spacing: 8
        ) {
            Text(message.text)
                .textSelection(.enabled)
                .padding(12)
                .background(
                    message.role == .user
                        ? Color.indigo
                        : Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 16)
                )
                .foregroundStyle(message.role == .user ? .white : .primary)

            if !message.sources.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(message.sources.enumerated()), id: \.element.id) {
                            index, source in
                            Button {
                                model.openSource(source)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("[\(index + 1)] \(source.title)")
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                    Text(source.locator)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 170, alignment: .leading)
                                .padding(9)
                                .background(
                                    .secondary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 11)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(
            maxWidth: .infinity,
            alignment: message.role == .user ? .trailing : .leading
        )
    }
}
