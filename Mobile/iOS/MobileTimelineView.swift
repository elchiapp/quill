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
                        Text(
                            "\(recording.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(recording.durationSeconds)s"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

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
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    if let playbackError = playback.errorMessage {
                        Text(playbackError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

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
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let item = try await Self.makePlayerItem(for: recording)
                try Task.checkCancellation()
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
                install(item, signature: signature)
            } catch is CancellationError {
                isPreparing = false
            } catch {
                isPreparing = false
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
        for recording: SharedRecordingItem
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

        let composition = AVMutableComposition()
        var insertedAudio = false
        for track in tracks {
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
        }
        guard insertedAudio else {
            throw PlaybackError.noPlayableTrack
        }
        return AVPlayerItem(asset: composition)
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

        var errorDescription: String? {
            switch self {
            case .noAudio:
                "This recording has no audio files."
            case .noPlayableTrack:
                "Its audio files are not available on this iPhone yet."
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
