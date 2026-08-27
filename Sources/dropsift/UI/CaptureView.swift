import SwiftUI

struct CaptureView: View {
    @ObservedObject var model: AppModel
    @State private var isDropTargeted = false

    private let columns = [
        GridItem(.adaptive(minimum: 210, maximum: 260), spacing: 16)
    ]

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer(minLength: 28)

                VStack(spacing: 8) {
                    Text("Add something to DropSift")
                        .font(.largeTitle.weight(.semibold))
                    Text("Capture it now or bring in something you already have.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: columns, spacing: 16) {
                    captureButton(
                        title: "Add note",
                        subtitle: "Write in Markdown",
                        systemImage: "note.text.badge.plus",
                        tint: .yellow
                    ) {
                        model.createNote()
                    }
                    captureButton(
                        title: "Add doc",
                        subtitle: "PDF, Word, text, Markdown",
                        systemImage: "doc.badge.plus",
                        tint: .blue
                    ) {
                        model.chooseDocuments()
                    }
                    captureButton(
                        title: "Add image",
                        subtitle: "OCR runs locally",
                        systemImage: "photo.badge.plus",
                        tint: .purple
                    ) {
                        model.chooseImages()
                    }
                    captureButton(
                        title: "Add recording",
                        subtitle: "Import and transcribe audio",
                        systemImage: "waveform.badge.plus",
                        tint: .orange
                    ) {
                        model.chooseAudioRecordings()
                    }
                    captureButton(
                        title: model.isRecording ? "Stop recording" : "Record",
                        subtitle: model.isRecording
                            ? model.recordingElapsed
                            : "Microphone + system audio",
                        systemImage: model.isRecording ? "stop.fill" : "record.circle",
                        tint: .red
                    ) {
                        model.toggleRecording()
                    }
                }
                .frame(maxWidth: 820)

                if let state = model.ingestionState {
                    VStack(spacing: 7) {
                        ProgressView(value: state.progress)
                            .frame(maxWidth: 420)
                        Text("Adding \(state.currentName) · \(state.completed + 1) of \(state.total)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label(
                        isDropTargeted ? "Drop to add to the timeline" : "You can also drop files anywhere here",
                        systemImage: "arrow.down.doc"
                    )
                    .font(.callout)
                    .foregroundStyle(
                        isDropTargeted ? Color.accentColor : Color.secondary
                    )
                }

                Spacer(minLength: 28)
            }
            .padding(34)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [9]))
                    .padding(18)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.ingestDroppedFiles(urls)
            return !urls.isEmpty
        } isTargeted: {
            isDropTargeted = $0
        }
    }

    private func captureButton(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 54, height: 54)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
            .padding(20)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 18)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.primary.opacity(0.07))
            )
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }
}
