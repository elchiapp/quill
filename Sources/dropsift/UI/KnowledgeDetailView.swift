import AppKit
import PDFKit
import SwiftUI

enum KnowledgeDetailSection: String, CaseIterable, Identifiable {
    case summary
    case note
    case preview
    case extractedText
    case insights

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary: "Summary"
        case .note: "Note"
        case .preview: "Preview"
        case .extractedText: "Extracted text"
        case .insights: "Insights"
        }
    }

    var systemImage: String {
        switch self {
        case .summary: "text.page"
        case .note: "note.text"
        case .preview: "doc.richtext"
        case .extractedText: "text.viewfinder"
        case .insights: "wand.and.stars"
        }
    }

    static func sections(for kind: KnowledgeItemKind) -> [Self] {
        switch kind {
        case .note:
            [.summary, .note, .insights]
        case .document, .image:
            [.summary, .preview, .extractedText, .insights]
        }
    }

    static func initial(for item: KnowledgeItem) -> Self {
        if item.summary != nil { return .summary }
        return item.kind == .note ? .note : .preview
    }
}

struct KnowledgeDetailView: View {
    @ObservedObject var model: AppModel
    let item: KnowledgeItem

    @State private var title: String
    @State private var content: String
    @State private var notes: String
    @State private var selectedSection: KnowledgeDetailSection
    @State private var showingNotesPanel: Bool

    init(model: AppModel, item: KnowledgeItem) {
        self.model = model
        self.item = item
        _title = State(initialValue: item.title)
        _content = State(initialValue: item.content)
        _notes = State(initialValue: item.additionalNotes)
        _selectedSection = State(
            initialValue: KnowledgeDetailSection.initial(for: item)
        )
        _showingNotesPanel = State(
            initialValue: item.kind != .note
                && ItemDetailLayoutPolicy.notesStartExpanded(
                    item.additionalNotes
                )
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let overlaysNotes = ItemDetailLayoutPolicy.overlaysSavedNotes(
                width: geometry.size.width
            )
            detailContent
                .inspector(
                    isPresented: inspectorNotesPresented(
                        overlaysNotes: overlaysNotes
                    )
                ) {
                    additionalNotesEditor
                        .inspectorColumnWidth(
                            min: 340,
                            ideal: 380,
                            max: 460
                        )
                }
                .overlay(alignment: .trailing) {
                    if item.kind != .note,
                       overlaysNotes,
                       savedNotesPresented.wrappedValue {
                        additionalNotesEditor
                            .frame(
                                width: min(
                                    420,
                                    max(340, geometry.size.width * 0.78)
                                )
                            )
                            .background(
                                Color(nsColor: .controlBackgroundColor)
                            )
                            .shadow(color: .black.opacity(0.18), radius: 18)
                            .transition(
                                .move(edge: .trailing).combined(with: .opacity)
                            )
                            .zIndex(2)
                    }
                }
                .animation(
                    .easeInOut(duration: 0.2),
                    value: savedNotesPresented.wrappedValue
                )
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: item.title) { oldTitle, newTitle in
            if title == oldTitle { title = newTitle }
        }
        .onChange(of: item.content) { oldContent, newContent in
            if content == oldContent { content = newContent }
        }
        .onChange(of: item.additionalNotes) { oldNotes, newNotes in
            if notes == oldNotes { notes = newNotes }
        }
        .onChange(of: item.summary?.sourceRevision) { oldRevision, newRevision in
            if oldRevision == nil, newRevision != nil {
                selectedSection = .summary
            } else if newRevision == nil, selectedSection == .summary {
                selectedSection = item.kind == .note ? .note : .preview
            }
        }
    }

    private var detailContent: some View {
        VStack(spacing: 0) {
            header
            Divider()
            sectionPicker
            Divider()
            selectedSectionContent
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
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
            } else if model.summaryGenerationItemID
                == "knowledge:\(item.id.uuidString)" {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Generating summary locally…")
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
                Label(
                    item.createdAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    ),
                    systemImage: "calendar"
                )
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
                    Label("Ask DropSift", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)

                if let assetURL = item.assetURL {
                    Button {
                        NSWorkspace.shared.open(assetURL)
                    } label: {
                        Label("Open original", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.bordered)
                }

                actionsMenu

                Spacer()

                if item.kind != .note {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showingNotesPanel.toggle()
                        }
                    } label: {
                        Label(
                            showingNotesPanel ? "Hide notes" : "Notes",
                            systemImage: showingNotesPanel
                                ? "rectangle.righthalf.inset.filled"
                                : "note.text"
                        )
                    }
                    .buttonStyle(.borderless)
                    .help(
                        showingNotesPanel
                            ? "Collapse item notes"
                            : "Show item notes"
                    )
                }
            }

            if let error = item.extractionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var actionsMenu: some View {
        Menu {
            Button {
                model.regeneratePresentation(for: .knowledge(item))
            } label: {
                Label("Regenerate title & description", systemImage: "sparkles")
            }
            .disabled(
                model.metadataGenerationItemID
                    == "knowledge:\(item.id.uuidString)"
            )

            Button {
                model.regenerateSummary(for: .knowledge(item))
            } label: {
                Label(
                    item.summary == nil ? "Generate summary" : "Regenerate summary",
                    systemImage: "text.page.badge.magnifyingglass"
                )
            }
            .disabled(
                model.summaryGenerationItemID
                    == "knowledge:\(item.id.uuidString)"
            )

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([
                    item.directory
                ])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }

            Divider()

            Button(role: .destructive) {
                model.requestDeleteKnowledgeItem(item)
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Item actions")
    }

    private var sectionPicker: some View {
        HStack(spacing: 6) {
            ForEach(KnowledgeDetailSection.sections(for: item.kind)) { section in
                Button {
                    selectedSection = section
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: section.systemImage)
                        Text(section.title)
                        if section == .insights, insightCount > 0 {
                            Text("\(insightCount)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Color.secondary.opacity(0.14),
                                    in: Capsule()
                                )
                        }
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(
                        selectedSection == section
                            ? Color.accentColor
                            : Color.secondary
                    )
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(
                        selectedSection == section
                            ? Color.accentColor.opacity(0.11)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!sectionIsAvailable(section))
                .opacity(sectionIsAvailable(section) ? 1 : 0.42)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    @ViewBuilder
    private var selectedSectionContent: some View {
        switch selectedSection {
        case .summary:
            summaryContent
        case .note:
            MarkdownNoteEditor(text: $content)
                .onChange(of: content) {
                    model.updateKnowledgeContent(content, itemID: item.id)
                }
        case .preview:
            preview
        case .extractedText:
            extractedText
        case .insights:
            insightsContent
        }
    }

    private func sectionIsAvailable(_ section: KnowledgeDetailSection) -> Bool {
        section != .summary || item.summary != nil
    }

    @ViewBuilder
    private var summaryContent: some View {
        let sourceID = "knowledge:\(item.id.uuidString)"
        if model.summaryGenerationItemID == sourceID {
            VStack(spacing: 12) {
                ProgressView()
                Text("Building item summary…")
                    .font(.headline)
                Text("Describing what this \(item.kind.displayName.lowercased()) is about locally.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let summary = item.summary {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Label("Item summary", systemImage: "text.page")
                            .font(.headline)
                        Spacer()
                        Text("Local AI · \(summary.model)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(summary.overview)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    SummaryListSection(
                        title: "Topics",
                        values: summary.topics,
                        emptyText: "No topics identified"
                    )
                    SummaryListSection(
                        title: "Conclusions & decisions",
                        values: summary.decisions,
                        emptyText: "No explicit conclusions or decisions"
                    )
                    SummaryListSection(
                        title: "Action items",
                        values: summary.actionItems,
                        emptyText: "No explicit action items"
                    )
                }
                .padding(26)
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
            }
        } else {
            ContentUnavailableView {
                Label("No summary yet", systemImage: "text.page")
            } description: {
                Text("Generate a local summary from this item's content and notes.")
            }
        }
    }

    private var insightCount: Int {
        model.semanticReview(for: "knowledge:\(item.id.uuidString)")?
            .candidates.count ?? 0
    }

    private var insightsContent: some View {
        ScrollView {
            ItemSemanticInsightsView(
                model: model,
                sourceID: "knowledge:\(item.id.uuidString)"
            )
            .padding(24)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
        }
    }

    private var savedNotesPresented: Binding<Bool> {
        Binding(
            get: {
                item.kind != .note
                    && ItemDetailLayoutPolicy.showsSavedNotes(
                        requested: showingNotesPanel,
                        isAnyRecordingActive: model.isRecording
                    )
            },
            set: { showingNotesPanel = $0 }
        )
    }

    private func inspectorNotesPresented(
        overlaysNotes: Bool
    ) -> Binding<Bool> {
        Binding(
            get: {
                item.kind != .note
                    && !overlaysNotes
                    && savedNotesPresented.wrappedValue
            },
            set: { presented in
                guard item.kind != .note, !overlaysNotes else { return }
                showingNotesPanel = presented
            }
        )
    }

    private var additionalNotesEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(
                    "Notes about this \(item.kind.displayName.lowercased())",
                    systemImage: "note.text"
                )
                .font(.headline)
                Spacer()
                Label("Autosaved", systemImage: "icloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingNotesPanel = false
                    }
                } label: {
                    Label("Hide", systemImage: "chevron.right")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Collapse item notes")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            MarkdownNoteEditor(
                text: $notes,
                placeholder: "Add notes about this \(item.kind.displayName.lowercased())…",
                accessibilityIdentifier: "knowledge-notes-editor"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: notes) {
                model.updateKnowledgeNotes(notes, itemID: item.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
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
