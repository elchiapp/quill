import DropsiftShared
import SwiftUI

struct MobileAskView: View {
    @ObservedObject var model: MobileAppModel
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
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
                .onSubmit { model.ask() }

                Button {
                    model.ask()
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
        .navigationTitle("Ask Dropsift")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { composerFocused = true }
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
