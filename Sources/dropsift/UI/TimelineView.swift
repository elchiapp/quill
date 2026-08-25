import AppKit
import SwiftUI

struct TimelineView: View {
    @ObservedObject var model: AppModel
    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var selectionAnchor: String?

    var body: some View {
        HSplitView {
            timelineList
                .frame(minWidth: 260, idealWidth: 360, maxWidth: 640)
                .frame(maxHeight: .infinity)
            detail
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: model.filteredTimelineItems.map(\.id)) { _, visibleIDs in
            selection.formIntersection(Set(visibleIDs))
        }
    }

    private var timelineList: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Timeline")
                        .font(.title2.weight(.semibold))
                    Text("\(model.filteredTimelineItems.count) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelecting {
                    Button(selectionContainsAllVisible ? "Clear" : "All") {
                        toggleSelectAll()
                    }
                    .buttonStyle(.plain)
                    Button("Done") {
                        endSelecting()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    filterMenu
                    Button {
                        isSelecting = true
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .help("Select multiple items")
                    Button {
                        model.section = .capture
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.bordered)
                    .help("Add something")
                }
            }
            .padding(14)

            timelineSearchField
                .padding(.horizontal, 12)
                .padding(.bottom, 12)

            Divider()

            if model.filteredTimelineItems.isEmpty {
                ContentUnavailableView {
                    Label("Nothing here", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text(
                        model.timelineItems.isEmpty
                            ? "Add your first note, document, image, or recording."
                            : emptyTimelineDescription
                    )
                } actions: {
                    if model.timelineItems.isEmpty {
                        Button("Add something") { model.section = .capture }
                    } else if hasTimelineSearch {
                        Button("Clear search") {
                            model.timelineSearch = ""
                        }
                    } else {
                        Button("Show all types") {
                            model.timelineFilters = Set(TimelineItemKind.allCases)
                        }
                    }
                }
            } else {
                List(model.filteredTimelineItems) { item in
                    Button {
                        handleClick(item.id)
                    } label: {
                        HStack(spacing: 8) {
                            if isSelecting {
                                Image(
                                    systemName: selection.contains(item.id)
                                        ? "checkmark.circle.fill"
                                        : "circle"
                                )
                                .font(.title3)
                                .foregroundStyle(
                                    selection.contains(item.id)
                                        ? Color.accentColor
                                        : Color.secondary
                                )
                            }
                            TimelineRow(
                                item: item,
                                status: rowStatus(for: item),
                                isSelected: isSelecting
                                    ? selection.contains(item.id)
                                    : model.selectedTimelineItemID == item.id
                            )
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(
                        model.selectedTimelineItemID == item.id ? .isSelected : []
                    )
                    .listRowInsets(
                        EdgeInsets(top: 2, leading: 5, bottom: 2, trailing: 5)
                    )
                    .listRowBackground(Color.clear)
                        .contextMenu {
                            switch item {
                            case .recording(let recording):
                                Button {
                                    model.resumeRecording(recording)
                                } label: {
                                    Label("Resume Recording", systemImage: "record.circle")
                                }
                                .disabled(
                                    model.isRecording || model.isPreparingRecording
                                )
                                Divider()
                                Button(role: .destructive) {
                                    model.requestDeleteRecording(recording)
                                } label: {
                                    Label("Move to Trash", systemImage: "trash")
                                }
                            case .knowledge(let knowledge):
                                Button(role: .destructive) {
                                    model.requestDeleteKnowledgeItem(knowledge)
                                } label: {
                                    Label("Move to Trash", systemImage: "trash")
                                }
                            }
                        }
                }
                .listStyle(.inset)

                if isSelecting {
                    Divider()
                    batchActionBar
                }
            }
        }
    }

    private var batchActionBar: some View {
        HStack(spacing: 10) {
            Text("\(selection.count) selected")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button {
                    selectedItems.forEach(model.regeneratePresentation)
                    endSelecting()
                } label: {
                    Label("Generate Titles & Descriptions", systemImage: "sparkles")
                }
                Button {
                    selectedItems.forEach(model.regenerateSummary)
                    endSelecting()
                } label: {
                    Label("Generate Summaries", systemImage: "text.page")
                }
                Button {
                    selectedItems.forEach {
                        model.requestSemanticExtraction(for: $0.id)
                    }
                    endSelecting()
                } label: {
                    Label("Extract Tasks & Details", systemImage: "list.bullet.clipboard")
                }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            .disabled(selection.isEmpty)

            Button(role: .destructive) {
                model.requestDeleteTimelineItems(selection)
                endSelecting()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(selection.isEmpty || selectionContainsActiveRecording)
            .help(
                selectionContainsActiveRecording
                    ? "Stop the active recording before moving it to Trash"
                    : "Move selected items to Trash"
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var selectedItems: [TimelineItem] {
        model.filteredTimelineItems.filter { selection.contains($0.id) }
    }

    private var selectionContainsAllVisible: Bool {
        let visible = Set(model.filteredTimelineItems.map(\.id))
        return !visible.isEmpty && visible.isSubset(of: selection)
    }

    private var selectionContainsActiveRecording: Bool {
        guard let activeID = model.recordingSessionID else { return false }
        return selection.contains("recording:\(activeID)")
    }

    private func toggleSelection(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
        selectionAnchor = id
    }

    private func toggleSelectAll() {
        let visible = Set(model.filteredTimelineItems.map(\.id))
        if visible.isSubset(of: selection) {
            selection.subtract(visible)
        } else {
            selection.formUnion(visible)
        }
    }

    private func endSelecting() {
        isSelecting = false
        selection.removeAll()
        selectionAnchor = model.selectedTimelineItemID
    }

    private func handleClick(_ id: String) {
        let modifiers = NSEvent.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.shift) {
            if !isSelecting {
                isSelecting = true
                if let focused = model.selectedTimelineItemID {
                    selection.insert(focused)
                }
            }
            let orderedIDs = model.filteredTimelineItems.map(\.id)
            let anchor = selectionAnchor ?? model.selectedTimelineItemID
            selection.formUnion(
                DesktopMultiSelection.range(
                    from: anchor,
                    through: id,
                    in: orderedIDs
                )
            )
            selectionAnchor = anchor ?? id
            return
        }
        if modifiers.contains(.command) {
            if !isSelecting {
                isSelecting = true
                if let focused = model.selectedTimelineItemID {
                    selection.insert(focused)
                }
            }
            toggleSelection(id)
            return
        }
        if isSelecting {
            toggleSelection(id)
        } else {
            model.selectTimelineItem(id)
            selectionAnchor = id
        }
    }

    private var timelineSearchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search timeline", text: $model.timelineSearch)
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity)
                .onExitCommand {
                    model.timelineSearch = ""
                }

            if hasTimelineSearch {
                Button {
                    model.timelineSearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.primary.opacity(0.09))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search timeline")
    }

    private var hasTimelineSearch: Bool {
        !model.timelineSearch
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private var emptyTimelineDescription: String {
        if hasTimelineSearch {
            return "No items match “\(model.timelineSearch)”."
        }
        return "No timeline items match the selected types."
    }

    private var filterMenu: some View {
        Menu {
            ForEach(TimelineItemKind.allCases) { kind in
                Button {
                    model.toggleTimelineFilter(kind)
                } label: {
                    if model.timelineFilters.contains(kind) {
                        Label(kind.displayName, systemImage: "checkmark")
                    } else {
                        Label(kind.displayName, systemImage: kind.systemImage)
                    }
                }
            }
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func rowStatus(for item: TimelineItem) -> String? {
        guard case .recording(let recording) = item else { return nil }
        if model.recordingSessionID == recording.id, model.isRecording {
            return "Recording"
        }
        if model.transcriptionProcessingID == recording.id {
            return "Processing"
        }
        return nil
    }

    @ViewBuilder
    private var detail: some View {
        if let item = model.selectedTimelineItem {
            switch item {
            case .recording(let recording):
                RecordingDetailView(model: model, recording: recording)
                    .id(recording.id + recording.title + "\(recording.segmentCount)")
            case .knowledge(let knowledge):
                KnowledgeDetailView(model: model, item: knowledge)
                    .id(knowledge.id)
            }
        } else {
            ContentUnavailableView {
                Label("Select an item", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("Choose something from your timeline to preview it.")
            }
        }
    }
}

private struct TimelineRow: View {
    let item: TimelineItem
    let status: String?
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: item.kind.systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    if let status {
                        Text(status)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(status == "Recording" ? .red : .orange)
                    }
                    Text(item.date, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(item.listDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
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
