import SwiftUI

struct TimelineView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HSplitView {
            timelineList
                .frame(minWidth: 280, idealWidth: 300, maxWidth: 320)
                .frame(maxHeight: .infinity)
            detail
                .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .toolbar {
            ToolbarItem {
                timelineSearchField
            }
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
                        model.selectTimelineItem(item.id)
                    } label: {
                        TimelineRow(
                            item: item,
                            isSelected: model.selectedTimelineItemID == item.id
                        )
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
            }
        }
    }

    private var timelineSearchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search timeline", text: $model.timelineSearch)
                .textFieldStyle(.plain)
                .frame(width: 220)
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
    let isSelected: Bool

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
                Text(item.listDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
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
