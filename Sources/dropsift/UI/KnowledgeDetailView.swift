import AppKit
import PDFKit
import SwiftUI

struct KnowledgeDetailView: View {
    @ObservedObject var model: AppModel
    let item: KnowledgeItem

    @State private var title: String
    @State private var content: String
    @State private var notes: String

    init(model: AppModel, item: KnowledgeItem) {
        self.model = model
        self.item = item
        _title = State(initialValue: item.title)
        _content = State(initialValue: item.content)
        _notes = State(initialValue: item.additionalNotes)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ItemSemanticInsightsView(
                model: model,
                sourceID: "knowledge:\(item.id.uuidString)"
            )
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            Divider()
            if item.kind == .note {
                MarkdownNoteEditor(text: $content)
                    .onChange(of: content) {
                        model.updateKnowledgeContent(content, itemID: item.id)
                    }
            } else {
                importedItemTabs
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: item.title) { oldTitle, newTitle in
            if title == oldTitle {
                title = newTitle
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 11) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.title.weight(.semibold))
                .onSubmit {
                    model.renameKnowledgeItem(item.id, to: title)
                }

            if model.metadataGenerationItemID
                == "knowledge:\(item.id.uuidString)" {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Generating title and description locally…")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else if !item.generatedDescription.isEmpty {
                Text(item.generatedDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 12) {
                Label(item.kind.displayName, systemImage: item.kind.systemImage)
                Label(item.createdAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                if item.kind != .note {
                    Label(
                        "\(item.blocks.count) extracted section\(item.blocks.count == 1 ? "" : "s")",
                        systemImage: "text.viewfinder"
                    )
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    model.createThread()
                } label: {
                    Label("Ask Dropsift", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    model.regeneratePresentation(for: .knowledge(item))
                } label: {
                    Label("Regenerate title", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .disabled(
                    model.metadataGenerationItemID
                        == "knowledge:\(item.id.uuidString)"
                )
                .help("Generate a new title and brief description using the local model")

                if let assetURL = item.assetURL {
                    Button {
                        NSWorkspace.shared.open(assetURL)
                    } label: {
                        Label("Open original", systemImage: "arrow.up.right.square")
                    }
                }

                Menu {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([item.directory])
                    }
                    Divider()
                    Button(role: .destructive) {
                        model.requestDeleteKnowledgeItem(item)
                    } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if let error = item.extractionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(24)
    }

    private var importedItemTabs: some View {
        TabView {
            preview
                .tabItem { Label("Preview", systemImage: item.kind.systemImage) }

            extractedText
                .tabItem { Label("Extracted text", systemImage: "text.viewfinder") }

            notesEditor
                .tabItem { Label("Notes", systemImage: "note.text") }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var preview: some View {
        if item.isPDF, let url = item.assetURL {
            PDFPreview(
                url: url,
                targetPage: model.knowledgeJump?.itemID == item.id
                    ? model.knowledgeJump?.page
                    : nil
            )
        } else if item.kind == .image,
                  let url = item.assetURL,
                  let image = NSImage(contentsOf: url) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 1_200, maxHeight: 1_000)
                    .padding(24)
            }
        } else {
            extractedText
        }
    }

    private var extractedText: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if item.blocks.isEmpty {
                    ContentUnavailableView(
                        "No text extracted",
                        systemImage: "text.viewfinder",
                        description: Text(
                            item.kind == .image
                                ? "The image remains available, but local OCR found no readable text."
                                : "The original document remains available."
                        )
                    )
                } else {
                    ForEach(item.blocks) { block in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(block.locator)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tint)
                            Text(block.text)
                                .textSelection(.enabled)
                                .lineSpacing(4)
                        }
                        Divider()
                    }
                }
            }
            .frame(maxWidth: 880, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Notes about this \(item.kind.displayName.lowercased())")
                    .font(.headline)
                Spacer()
                Label("Autosaved", systemImage: "icloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            MarkdownNoteEditor(
                text: $notes,
                placeholder: "Add notes about this \(item.kind.displayName.lowercased())…",
                accessibilityIdentifier: "knowledge-notes-editor"
            )
                .onChange(of: notes) {
                    model.updateKnowledgeNotes(notes, itemID: item.id)
                }
        }
        .padding(24)
    }
}

private struct PDFPreview: NSViewRepresentable {
    let url: URL
    let targetPage: Int?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.document = PDFDocument(url: url)
        goToTargetPage(in: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
        goToTargetPage(in: view)
    }

    private func goToTargetPage(in view: PDFView) {
        guard let targetPage,
              targetPage > 0,
              let page = view.document?.page(at: targetPage - 1)
        else { return }
        view.go(to: page)
    }
}
