import DropsiftShared
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct MobileCaptureView: View {
    @ObservedObject var model: MobileAppModel
    @State private var showingNote = false
    @State private var showingDocuments = false
    @State private var showingAudio = false
    @State private var showingLibraryPicker = false
    @State private var selectedPhoto: PhotosPickerItem?

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if !model.locator.isConnectedToSharedFolder {
                    connectBanner
                }

                VStack(spacing: 6) {
                    Text("Capture anything")
                        .font(.largeTitle.bold())
                    Text("It lands in the same private DropSift timeline.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)

                LazyVGrid(columns: columns, spacing: 14) {
                    captureButton(
                        title: "Add note",
                        subtitle: "Write in Markdown",
                        icon: "note.text.badge.plus",
                        color: .yellow
                    ) {
                        showingNote = true
                    }

                    captureButton(
                        title: "Add doc",
                        subtitle: "PDF, text, files",
                        icon: "doc.badge.plus",
                        color: .blue
                    ) {
                        showingDocuments = true
                    }

                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        captureLabel(
                            title: "Add image",
                            subtitle: "OCR runs locally",
                            icon: "photo.badge.plus",
                            color: .purple
                        )
                    }
                    .buttonStyle(.plain)

                    captureButton(
                        title: "Add recording",
                        subtitle: "Import and transcribe",
                        icon: "waveform.badge.plus",
                        color: .orange
                    ) {
                        showingAudio = true
                    }

                    Button {
                        model.toggleRecording()
                    } label: {
                        captureLabel(
                            title: model.recorder.isRecording
                                ? "Stop \(model.recorder.elapsedLabel)"
                                : "Record",
                            subtitle: model.recorder.isRecording
                                ? recordingSubtitle
                                : "Voice message",
                            icon: model.recorder.isRecording
                                ? "stop.circle.fill"
                                : "record.circle",
                            color: .red
                        )
                    }
                    .buttonStyle(.plain)
                    .sensoryFeedback(.impact, trigger: model.recorder.isRecording)
                }

                VStack(spacing: 5) {
                    Label(model.locator.status, systemImage: "icloud")
                    Text(model.watchBridge.status)
                    if model.watchBridge.pendingCount > 0 {
                        Text(
                            "\(model.watchBridge.pendingCount) Watch message"
                                + (model.watchBridge.pendingCount == 1 ? "" : "s")
                                + " waiting to import"
                        )
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            }
            .padding(18)
        }
        .navigationTitle("DropSift")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingNote) {
            NewNoteSheet(model: model)
        }
        .fileImporter(
            isPresented: $showingDocuments,
            allowedContentTypes: documentTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                for url in urls {
                    model.importKnowledgeFile(url, kind: .document)
                }
            }
        }
        .fileImporter(
            isPresented: $showingAudio,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                for url in urls {
                    model.importAudioFile(url)
                }
            }
        }
        .fileImporter(
            isPresented: $showingLibraryPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.connectLibrary(url)
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    model.errorMessage = "Couldn’t load that image."
                    return
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString).jpg")
                do {
                    try data.write(to: url, options: .atomic)
                    model.importKnowledgeFile(url, kind: .image)
                } catch {
                    model.errorMessage = "Couldn’t prepare that image."
                }
                selectedPhoto = nil
            }
        }
    }

    private var recordingSubtitle: String {
        if case .append = model.recordingDestination {
            return "Tap to append"
        }
        return "Tap to save"
    }

    private var connectBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Connect your shared iCloud library", systemImage: "icloud.and.arrow.up")
                .font(.headline)
            Text(
                "Choose the DropSift folder in iCloud Drive once. iPhone, Watch, and Mac will then use the same files."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Button("Choose iCloud folder") {
                showingLibraryPicker = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))
    }

    private func captureButton(
        title: String,
        subtitle: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            captureLabel(
                title: title,
                subtitle: subtitle,
                icon: icon,
                color: color
            )
        }
        .buttonStyle(.plain)
    }

    nonisolated private func captureLabel(
        title: String,
        subtitle: String,
        icon: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 48, height: 48)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            Spacer(minLength: 2)
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 145, alignment: .leading)
        .padding(15)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    private var documentTypes: [UTType] {
        [
            .pdf,
            .plainText,
            .rtf,
            .html,
            .commaSeparatedText,
            .json,
            UTType(filenameExtension: "md"),
            UTType(filenameExtension: "doc"),
            UTType(filenameExtension: "docx"),
        ]
        .compactMap { $0 }
    }
}

private struct NewNoteSheet: View {
    @ObservedObject var model: MobileAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var content = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                    .font(.headline)
                TextEditor(text: $content)
                    .frame(minHeight: 280)
                    .font(.body.monospaced())
            }
            .navigationTitle("New note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.createNote(
                            title: title.isEmpty ? "Untitled note" : title,
                            content: content
                        )
                        dismiss()
                    }
                }
            }
        }
    }
}
