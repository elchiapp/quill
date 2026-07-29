import SwiftUI

struct RecordingDetailView: View {
    @ObservedObject var model: AppModel
    let recording: RecordingItem

    @State private var title: String
    @State private var notes: String

    init(model: AppModel, recording: RecordingItem) {
        self.model = model
        self.recording = recording
        _title = State(initialValue: recording.title)
        _notes = State(initialValue: recording.notes)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            savedNotes
            Divider()
            transcript
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Meeting title", text: $title)
                .textFieldStyle(.plain)
                .font(.title.weight(.semibold))
                .onSubmit {
                    model.renameSelectedRecording(to: title)
                }

            HStack(spacing: 12) {
                Label(recording.displayDate, systemImage: "calendar")
                Label(recording.displayDuration, systemImage: "clock")
                if recording.isTranscribed {
                    Label("\(recording.segmentCount) segments", systemImage: "text.alignleft")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    model.createThread(scope: .recording(recording.id))
                } label: {
                    Label("Ask about this recording", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)

                Menu {
                    Button("Open microphone track") { model.openAudio(recording.micURL) }
                        .disabled(recording.micURL == nil)
                    Button("Open system-audio track") { model.openAudio(recording.systemURL) }
                        .disabled(recording.systemURL == nil)
                    Divider()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([recording.directory])
                    }
                    Divider()
                    Button(role: .destructive) {
                        model.requestDeleteRecording(recording)
                    } label: {
                        Label("Move Recording to Trash", systemImage: "trash")
                    }
                } label: {
                    Label("Audio & files", systemImage: "waveform")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(24)
    }

    private var savedNotes: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Notes about this recording", systemImage: "note.text")
                    .font(.headline)
                Spacer()
                Label("Autosaved", systemImage: "icloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextEditor(text: $notes)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    Color(nsColor: .textBackgroundColor).opacity(0.8),
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .onChange(of: notes) {
                    model.updateRecordingNotes(notes, recordingID: recording.id)
                }
            .frame(minHeight: 44, maxHeight: 130)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    @ViewBuilder
    private var transcript: some View {
        if let document = recording.transcript {
            if document.segments.isEmpty {
                ContentUnavailableView {
                    Label("No speech detected", systemImage: "waveform.slash")
                } description: {
                    Text("The recording was transcribed successfully, but it contained no recognizable speech.")
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(document.segments) { segment in
                                TranscriptSegmentRow(
                                    segment: segment,
                                    isHighlighted: jumpSegment(in: document)?.id == segment.id
                                )
                                .id(segment.id)
                                Divider()
                                    .padding(.leading, 92)
                            }

                            HStack {
                                Spacer()
                                Text(transcriptionFooter(document))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Spacer()
                            }
                            .padding(24)
                        }
                        .padding(.horizontal, 24)
                    }
                    .onAppear { scrollToSource(in: document, proxy: proxy) }
                    .onChange(of: model.transcriptJump) {
                        scrollToSource(in: document, proxy: proxy)
                    }
                }
            }
        } else {
            ContentUnavailableView {
                Label("Transcription pending", systemImage: "waveform.badge.magnifyingglass")
            } description: {
                Text(
                    model.transcriptionStatus
                        ?? "Dropsift will transcribe this recording locally. The first run downloads the speech model."
                )
            }
        }
    }

    private func jumpSegment(
        in document: TranscriptDocument
    ) -> TranscriptDocument.Segment? {
        guard let jump = model.transcriptJump, jump.recordingID == recording.id else {
            return nil
        }
        return document.segments.min {
            abs($0.startMs - jump.startMs) < abs($1.startMs - jump.startMs)
        }
    }

    private func scrollToSource(
        in document: TranscriptDocument,
        proxy: ScrollViewProxy
    ) {
        guard let segment = jumpSegment(in: document) else { return }
        Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(segment.id, anchor: .center)
            }
        }
    }

    private func transcriptionFooter(_ document: TranscriptDocument) -> String {
        var value = "Transcribed locally with \(document.engine) · \(document.model)"
        if let code = document.languageCode {
            let name = Locale.current.localizedString(forLanguageCode: code) ?? code
            value += " · \(name.capitalized) detected"
        }
        if let diarization = document.diarization {
            value += " · \(diarization.speakerCount) remote speaker"
            if diarization.speakerCount != 1 { value += "s" }
        }
        return value
    }
}

private struct TranscriptSegmentRow: View {
    let segment: TranscriptDocument.Segment
    let isHighlighted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(TranscriptDocument.clock(segment.startMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(speakerLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(speakerColor)
            }
            .frame(width: 72, alignment: .leading)

            Text(segment.text)
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 15)
        .padding(.horizontal, 8)
        .background(
            isHighlighted ? Color.accentColor.opacity(0.13) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .animation(.easeInOut(duration: 0.2), value: isHighlighted)
    }

    private var speakerLabel: String {
        if segment.speaker == "me" { return "YOU" }
        if segment.speaker == "them" { return "THEM" }
        if segment.speaker.hasPrefix("speaker_"),
           let number = segment.speaker.split(separator: "_").last {
            return "SPEAKER \(number)"
        }
        return segment.speaker.uppercased()
    }

    private var speakerColor: Color {
        if segment.speaker == "me" { return .indigo }
        let palette: [Color] = [.orange, .teal, .pink, .purple, .green, .blue]
        let value = segment.speaker.unicodeScalars.reduce(0) {
            $0 + Int($1.value)
        }
        return palette[value % palette.count]
    }
}
