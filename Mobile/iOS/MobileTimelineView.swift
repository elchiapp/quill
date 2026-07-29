import AVFoundation
import DropsiftShared
import PDFKit
import SwiftUI
import UIKit

struct MobileTimelineView: View {
    @ObservedObject var model: MobileAppModel
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.filteredTimeline.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing here", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("Capture something or adjust the active filters.")
                    }
                } else {
                    List(model.filteredTimeline) { item in
                        NavigationLink(value: item.id) {
                            MobileTimelineRow(item: item)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Timeline")
            .searchable(text: $model.timelineSearch, prompt: "Search timeline")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    filterMenu
                }
            }
            .navigationDestination(for: String.self) { id in
                if let item = model.timeline.first(where: { $0.id == id }) {
                    MobileItemDetail(model: model, item: item)
                        .id(item.id)
                        .onAppear { model.selectedTimelineItemID = item.id }
                } else {
                    ContentUnavailableView(
                        "Item unavailable",
                        systemImage: "questionmark.folder"
                    )
                }
            }
        }
        .onChange(of: model.selectedTimelineItemID) { _, id in
            guard model.selectedTab == .timeline, let id else { return }
            if path.last != id {
                path = [id]
            }
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
                Text(item.preview)
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
            Text("This removes the item from the shared Dropsift library.")
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

                preview

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
                        title: title,
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
    @State private var player: AVPlayer?
    @State private var isPlaying = false

    init(model: MobileAppModel, recording: SharedRecordingItem) {
        self.model = model
        self.recording = recording
        _notes = State(initialValue: recording.notes)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(recording.title)
                            .font(.title2.bold())
                        Text(
                            "\(recording.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(recording.durationSeconds)s"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if let url = recording.audioURL {
                        Button {
                            if isPlaying {
                                player?.pause()
                                isPlaying = false
                            } else {
                                let player = player ?? AVPlayer(url: url)
                                self.player = player
                                player.play()
                                isPlaying = true
                            }
                        } label: {
                            Label(
                                isPlaying ? "Pause" : "Play recording",
                                systemImage: isPlaying ? "pause.fill" : "play.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Transcript")
                            .font(.headline)
                        if let segments = recording.transcript?.segments,
                           !segments.isEmpty {
                            ForEach(segments) { segment in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(
                                        "\(SharedLibraryStore.clock(segment.startMs)) · \(segment.speaker == "me" ? "You" : segment.speaker)"
                                    )
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
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
        .onDisappear {
            player?.pause()
            isPlaying = false
        }
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
