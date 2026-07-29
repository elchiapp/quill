import SwiftUI

struct TimelineView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HSplitView {
            timelineList
                .frame(minWidth: 290, idealWidth: 330, maxWidth: 350)
            detail
                .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
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
                filterMenu
                Button {
                    model.section = .capture
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .help("Add something")
            }
            .padding(14)

            Divider()

            if model.filteredTimelineItems.isEmpty {
                ContentUnavailableView {
                    Label("Nothing here", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text(
                        model.timelineItems.isEmpty
                            ? "Add your first note, document, image, or recording."
                            : "No timeline items match these filters."
                    )
                } actions: {
                    if model.timelineItems.isEmpty {
                        Button("Add something") { model.section = .capture }
                    } else {
                        Button("Show all types") {
                            model.timelineFilters = Set(TimelineItemKind.allCases)
                        }
                    }
                }
            } else {
                List(
                    model.filteredTimelineItems,
                    selection: timelineSelection
                ) { item in
                    TimelineRow(item: item)
                        .tag(item.id)
                        .contextMenu {
                            switch item {
                            case .recording(let recording):
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
            }
        }
        .searchable(text: $model.timelineSearch, prompt: "Search timeline")
    }

    private var timelineSelection: Binding<String?> {
        Binding(
            get: { model.selectedTimelineItemID },
            set: { model.selectTimelineItem($0) }
        )
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

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: item.kind.systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Text(item.date, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(item.kind.singularName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color)
                Text(item.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
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
