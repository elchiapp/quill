import DropsiftShared
import SwiftUI

struct TasksView: View {
    enum Sort: String, CaseIterable, Identifiable {
        case priority
        case dueDate
        case newest
        case title

        var id: String { rawValue }

        var label: String {
            switch self {
            case .priority: "Priority"
            case .dueDate: "Due date"
            case .newest: "Newest"
            case .title: "Title"
            }
        }
    }

    @ObservedObject var model: AppModel
    @State private var sort: Sort = .priority
    @State private var showCompleted = true
    @State private var isSelecting = false
    @State private var selection = Set<UUID>()
    @State private var confirmingBatchDelete = false

    private var visibleTasks: [SharedTask] {
        model.tasks
            .filter { showCompleted || !$0.isCompleted }
            .sorted { lhs, rhs in
                if lhs.isCompleted != rhs.isCompleted {
                    return !lhs.isCompleted
                }
                switch sort {
                case .priority:
                    if lhs.priority != rhs.priority {
                        return lhs.priority > rhs.priority
                    }
                    return (lhs.dueDate ?? .distantFuture)
                        < (rhs.dueDate ?? .distantFuture)
                case .dueDate:
                    return (lhs.dueDate ?? .distantFuture)
                        < (rhs.dueDate ?? .distantFuture)
                case .newest:
                    return lhs.createdAt > rhs.createdAt
                case .title:
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                        == .orderedAscending
                }
            }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tasks")
                            .font(.title2.bold())
                        Text("\(model.tasks.filter { !$0.isCompleted }.count) open")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isSelecting {
                        Button(selectionContainsAllVisible ? "Clear" : "All") {
                            toggleSelectAll()
                        }
                        .buttonStyle(.plain)
                        Button("Done") { endSelecting() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Menu {
                            Picker("Sort", selection: $sort) {
                                ForEach(Sort.allCases) {
                                    Text($0.label).tag($0)
                                }
                            }
                            Toggle("Show completed", isOn: $showCompleted)
                        } label: {
                            Label("Sort", systemImage: "arrow.up.arrow.down")
                        }
                        .menuStyle(.borderlessButton)

                        Button {
                            isSelecting = true
                        } label: {
                            Image(systemName: "checkmark.circle")
                        }
                        .buttonStyle(.bordered)
                        .help("Select multiple tasks")

                        Button {
                            model.createTask()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.bordered)
                        .help("New task")
                    }
                }
                .padding(16)

                Divider()

                if visibleTasks.isEmpty {
                    ContentUnavailableView {
                        Label("No tasks", systemImage: "checklist")
                    } description: {
                        Text(
                            showCompleted
                                ? "Create one, or let Dropsift find action items while it processes your knowledge."
                                : "There are no open tasks."
                        )
                    } actions: {
                        Button("New task") { model.createTask() }
                    }
                } else {
                    if isSelecting {
                        List {
                            ForEach(visibleTasks) { task in
                                Button {
                                    toggleSelection(task.id)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(
                                            systemName: selection.contains(task.id)
                                                ? "checkmark.circle.fill"
                                                : "circle"
                                        )
                                        .font(.title3)
                                        .foregroundStyle(
                                            selection.contains(task.id)
                                                ? Color.accentColor
                                                : Color.secondary
                                        )
                                        TaskRow(model: model, task: task)
                                            .allowsHitTesting(false)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .listStyle(.inset)
                    } else {
                        List(selection: $model.selectedTaskID) {
                            ForEach(visibleTasks) { task in
                                TaskRow(model: model, task: task)
                                    .tag(task.id)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            model.deleteTask(task)
                                        } label: {
                                            Label("Delete Task", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        .listStyle(.inset)
                    }
                    if isSelecting {
                        Divider()
                        taskBatchActionBar
                    }
                }
            }
            .frame(minWidth: 330, idealWidth: 380, maxWidth: 460)

            Group {
                if let task = model.tasks.first(
                    where: { $0.id == model.selectedTaskID }
                ) {
                    TaskEditor(model: model, task: task)
                        .id(task.id)
                } else {
                    ContentUnavailableView {
                        Label("Select a task", systemImage: "checkmark.circle")
                    }
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: visibleTasks.map(\.id)) { _, visibleIDs in
            selection.formIntersection(Set(visibleIDs))
        }
        .confirmationDialog(
            "Delete \(selection.count) tasks?",
            isPresented: $confirmingBatchDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Tasks", role: .destructive) {
                model.deleteTasks(selection)
                endSelecting()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected tasks will be permanently deleted.")
        }
    }

    private var taskBatchActionBar: some View {
        HStack(spacing: 10) {
            Text("\(selection.count) selected")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button {
                    model.setTaskCompletion(selection, completed: true)
                    endSelecting()
                } label: {
                    Label("Mark Complete", systemImage: "checkmark.circle")
                }
                Button {
                    model.setTaskCompletion(selection, completed: false)
                    endSelecting()
                } label: {
                    Label("Reopen", systemImage: "arrow.uturn.backward.circle")
                }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            .disabled(selection.isEmpty)
            Button(role: .destructive) {
                confirmingBatchDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .disabled(selection.isEmpty)
            .help("Delete selected tasks")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var selectionContainsAllVisible: Bool {
        let visible = Set(visibleTasks.map(\.id))
        return !visible.isEmpty && visible.isSubset(of: selection)
    }

    private func toggleSelection(_ id: UUID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func toggleSelectAll() {
        let visible = Set(visibleTasks.map(\.id))
        if visible.isSubset(of: selection) {
            selection.subtract(visible)
        } else {
            selection.formUnion(visible)
        }
    }

    private func endSelecting() {
        isSelecting = false
        selection.removeAll()
    }
}

private struct TaskRow: View {
    @ObservedObject var model: AppModel
    let task: SharedTask

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Button {
                model.toggleTaskCompletion(task)
            } label: {
                Image(
                    systemName: task.isCompleted
                        ? "checkmark.circle.fill"
                        : "circle"
                )
                .font(.title3)
                .foregroundStyle(task.isCompleted ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help(task.isCompleted ? "Mark open" : "Mark complete")

            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .font(.body.weight(.medium))
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    PriorityBadge(priority: task.priority)
                    if let dueDate = task.dueDate {
                        Label(
                            dueDate.formatted(date: .abbreviated, time: .omitted),
                            systemImage: "calendar"
                        )
                        .foregroundStyle(
                            !task.isCompleted && dueDate < Date()
                                ? .red
                                : .secondary
                        )
                    }
                }
                .font(.caption)
            }
            Spacer()
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

private struct TaskEditor: View {
    @ObservedObject var model: AppModel
    let task: SharedTask

    @State private var title: String
    @State private var description: String
    @State private var priority: SharedTaskPriority
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var confirmingDelete = false

    init(model: AppModel, task: SharedTask) {
        self.model = model
        self.task = task
        _title = State(initialValue: task.title)
        _description = State(initialValue: task.description)
        _priority = State(initialValue: task.priority)
        _hasDueDate = State(initialValue: task.dueDate != nil)
        _dueDate = State(initialValue: task.dueDate ?? Date())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Task")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("Task title", text: $title)
                            .font(.largeTitle.bold())
                            .textFieldStyle(.plain)
                    }
                    Spacer()
                    Button {
                        var updated = task
                        updated.isCompleted.toggle()
                        model.saveTask(updated)
                    } label: {
                        Label(
                            task.isCompleted ? "Reopen" : "Complete",
                            systemImage: task.isCompleted
                                ? "arrow.uturn.backward.circle"
                                : "checkmark.circle.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(task.isCompleted ? .secondary : .green)
                }

                HStack(spacing: 24) {
                    Picker("Priority", selection: $priority) {
                        ForEach(SharedTaskPriority.allCases) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .frame(maxWidth: 220)

                    Toggle("Due date", isOn: $hasDueDate)
                        .toggleStyle(.checkbox)

                    if hasDueDate {
                        DatePicker(
                            "",
                            selection: $dueDate,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .labelsHidden()
                    }
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Description")
                        .font(.headline)
                    TextEditor(text: $description)
                        .font(.body)
                        .frame(minHeight: 180)
                        .padding(8)
                        .background(
                            Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                }

                if !task.sources.isEmpty {
                    SemanticSourcesView(
                        sources: task.sources,
                        open: model.openSemanticSource
                    )
                }

                HStack {
                    Button("Delete", role: .destructive) {
                        confirmingDelete = true
                    }
                    Spacer()
                    Button("Save") {
                        var updated = task
                        updated.title = title
                        updated.description = description
                        updated.priority = priority
                        updated.dueDate = hasDueDate ? dueDate : nil
                        model.saveTask(updated)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        title.trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                    )
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .confirmationDialog(
            "Delete this task?",
            isPresented: $confirmingDelete
        ) {
            Button("Delete Task", role: .destructive) {
                model.deleteTask(task)
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct SemanticEntitiesView: View {
    @ObservedObject var model: AppModel
    let kind: SharedSemanticEntityKind
    @State private var isSelecting = false
    @State private var selection = Set<UUID>()
    @State private var confirmingBatchDelete = false

    private var entities: [SharedSemanticEntity] {
        model.entities(of: kind)
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.displayName)
                            .font(.title2.bold())
                        Text("\(entities.count) saved")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isSelecting {
                        Button(selectionContainsAll ? "Clear" : "All") {
                            toggleSelectAll()
                        }
                        .buttonStyle(.plain)
                        Button("Done") { endSelecting() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            isSelecting = true
                        } label: {
                            Image(systemName: "checkmark.circle")
                        }
                        .buttonStyle(.bordered)
                        .help("Select multiple \(kind.displayName.lowercased())")
                        Button {
                            model.createEntity(kind: kind)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(16)

                Divider()

                if entities.isEmpty {
                    ContentUnavailableView {
                        Label(
                            "No \(kind.displayName.lowercased()) yet",
                            systemImage: kind.systemImage
                        )
                    } description: {
                        Text(
                            "Dropsift will suggest meaningful \(kind.displayName.lowercased()) as it processes your recordings and files."
                        )
                    } actions: {
                        Button("Add \(kind.singularName.lowercased())") {
                            model.createEntity(kind: kind)
                        }
                    }
                } else {
                    if isSelecting {
                        List {
                            ForEach(entities) { entity in
                                Button {
                                    toggleSelection(entity.id)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(
                                            systemName: selection.contains(entity.id)
                                                ? "checkmark.circle.fill"
                                                : "circle"
                                        )
                                        .font(.title3)
                                        .foregroundStyle(
                                            selection.contains(entity.id)
                                                ? Color.accentColor
                                                : Color.secondary
                                        )
                                        entityRow(entity)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .listStyle(.inset)
                    } else {
                        List(selection: $model.selectedEntityID) {
                            ForEach(entities) { entity in
                                entityRow(entity)
                                    .tag(entity.id)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            model.deleteEntity(entity)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        .listStyle(.inset)
                    }
                    if isSelecting {
                        Divider()
                        HStack {
                            Text("\(selection.count) selected")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(role: .destructive) {
                                confirmingBatchDelete = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .disabled(selection.isEmpty)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(.bar)
                    }
                }
            }
            .frame(minWidth: 310, idealWidth: 360, maxWidth: 430)

            Group {
                if let entity = entities.first(
                    where: { $0.id == model.selectedEntityID }
                ) {
                    SemanticEntityEditor(model: model, entity: entity)
                        .id(entity.id)
                } else {
                    ContentUnavailableView {
                        Label(
                            "Select a \(kind.singularName.lowercased())",
                            systemImage: kind.systemImage
                        )
                    }
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if !entities.contains(where: { $0.id == model.selectedEntityID }) {
                model.selectedEntityID = entities.first?.id
            }
        }
        .onChange(of: entities.map(\.id)) { _, visibleIDs in
            selection.formIntersection(Set(visibleIDs))
        }
        .confirmationDialog(
            "Delete \(selection.count) \(kind.displayName.lowercased())?",
            isPresented: $confirmingBatchDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Selected", role: .destructive) {
                model.deleteEntities(selection)
                endSelecting()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected items will be permanently deleted.")
        }
    }

    private func entityRow(_ entity: SharedSemanticEntity) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entity.name)
                .font(.body.weight(.medium))
                .lineLimit(2)
            if let start = entity.startDate {
                Text(
                    start.formatted(
                        date: .abbreviated,
                        time: .shortened
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if !entity.summary.isEmpty {
                Text(entity.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectionContainsAll: Bool {
        let visible = Set(entities.map(\.id))
        return !visible.isEmpty && visible.isSubset(of: selection)
    }

    private func toggleSelection(_ id: UUID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func toggleSelectAll() {
        let visible = Set(entities.map(\.id))
        if visible.isSubset(of: selection) {
            selection.subtract(visible)
        } else {
            selection.formUnion(visible)
        }
    }

    private func endSelecting() {
        isSelecting = false
        selection.removeAll()
    }
}

private struct SemanticEntityEditor: View {
    @ObservedObject var model: AppModel
    let entity: SharedSemanticEntity

    @State private var name: String
    @State private var summary: String
    @State private var hasStartDate: Bool
    @State private var startDate: Date
    @State private var hasEndDate: Bool
    @State private var endDate: Date
    @State private var confirmingDelete = false

    init(model: AppModel, entity: SharedSemanticEntity) {
        self.model = model
        self.entity = entity
        _name = State(initialValue: entity.name)
        _summary = State(initialValue: entity.summary)
        _hasStartDate = State(initialValue: entity.startDate != nil)
        _startDate = State(initialValue: entity.startDate ?? Date())
        _hasEndDate = State(initialValue: entity.endDate != nil)
        _endDate = State(initialValue: entity.endDate ?? entity.startDate ?? Date())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Label(
                    entity.kind.singularName,
                    systemImage: entity.kind.systemImage
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                TextField(entity.kind.singularName, text: $name)
                    .font(.largeTitle.bold())
                    .textFieldStyle(.plain)

                if entity.kind == .event {
                    HStack(spacing: 20) {
                        Toggle("Starts", isOn: $hasStartDate)
                            .toggleStyle(.checkbox)
                        if hasStartDate {
                            DatePicker(
                                "",
                                selection: $startDate,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                            .labelsHidden()
                        }
                        Toggle("Ends", isOn: $hasEndDate)
                            .toggleStyle(.checkbox)
                        if hasEndDate {
                            DatePicker(
                                "",
                                selection: $endDate,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                            .labelsHidden()
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Notes")
                        .font(.headline)
                    TextEditor(text: $summary)
                        .frame(minHeight: 180)
                        .padding(8)
                        .background(
                            Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                }

                if !entity.sources.isEmpty {
                    SemanticSourcesView(
                        sources: entity.sources,
                        open: model.openSemanticSource
                    )
                }

                HStack {
                    Button("Delete", role: .destructive) {
                        confirmingDelete = true
                    }
                    Spacer()
                    Button("Save") {
                        var updated = entity
                        updated.name = name
                        updated.summary = summary
                        updated.startDate = entity.kind == .event && hasStartDate
                            ? startDate
                            : nil
                        updated.endDate = entity.kind == .event && hasEndDate
                            ? endDate
                            : nil
                        model.saveEntity(updated)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                    )
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .confirmationDialog(
            "Delete this \(entity.kind.singularName.lowercased())?",
            isPresented: $confirmingDelete
        ) {
            Button("Delete", role: .destructive) {
                model.deleteEntity(entity)
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct SemanticSourcesView: View {
    let sources: [SharedSemanticSourceReference]
    let open: (SharedSemanticSourceReference) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Sources")
                .font(.headline)
            ForEach(sources) { source in
                Button {
                    open(source)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.title)
                                .font(.body.weight(.medium))
                            Text(source.locator)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !source.excerpt.isEmpty {
                                Text(source.excerpt)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                    }
                    .padding(11)
                    .background(
                        Color.accentColor.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct PriorityBadge: View {
    let priority: SharedTaskPriority

    var body: some View {
        Text(priority.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var color: Color {
        switch priority {
        case .low: .secondary
        case .medium: .blue
        case .high: .orange
        case .urgent: .red
        }
    }
}

struct ItemSemanticInsightsView: View {
    @ObservedObject var model: AppModel
    let sourceID: String

    private var review: SharedSemanticReview? {
        model.semanticReview(for: sourceID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("Tasks & details", systemImage: "wand.and.stars")
                    .font(.headline)

                if let review {
                    Text("\(review.candidates.count) suggestion\(review.candidates.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if model.semanticProcessingSourceID == sourceID {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Extracting locally…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Button(review == nil ? "Extract tasks & details" : "Extract again") {
                        model.requestSemanticExtraction(for: sourceID)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let review {
                Divider()
                SemanticReviewContents(model: model, review: review)
                    .id(review.id)
            } else if model.semanticProcessingSourceID != sourceID {
                Text("Pull out possible to-dos, people, places, events, projects, and topics. Suggestions stay with this item until you review them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.7),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }
}

private struct SemanticReviewContents: View {
    @ObservedObject var model: AppModel
    let review: SharedSemanticReview
    @State private var selectedIDs: Set<UUID>

    init(model: AppModel, review: SharedSemanticReview) {
        self.model = model
        self.review = review
        _selectedIDs = State(initialValue: Set(review.candidates.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("I found these things worth organizing. Everything is selected by default; uncheck anything you don’t want to add.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    candidateGroup(
                        title: "Things to do",
                        candidates: review.candidates.filter {
                            $0.kind == .task
                        }
                    )

                    ForEach(SharedSemanticEntityKind.allCases) { kind in
                        candidateGroup(
                            title: kind.displayName,
                            candidates: review.candidates.filter {
                                $0.entity?.kind == kind
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)

            HStack {
                Button("Dismiss suggestions") {
                    model.dismissSemanticReview(review)
                }
                Spacer()
                Button(
                    selectedIDs.count == review.candidates.count
                        ? "Deselect all"
                        : "Select all"
                ) {
                    selectedIDs = selectedIDs.count == review.candidates.count
                        ? []
                        : Set(review.candidates.map(\.id))
                }
                Button("Add \(selectedIDs.count) selected") {
                    model.acceptSemanticReview(
                        review,
                        selectedCandidateIDs: selectedIDs
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIDs.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func candidateGroup(
        title: String,
        candidates: [SharedSemanticCandidate]
    ) -> some View {
        if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(candidates) { candidate in
                    ReviewCandidateRow(
                        candidate: candidate,
                        isSelected: selectedIDs.contains(candidate.id)
                    ) {
                        toggle(candidate.id)
                    }
                }
            }
        }
    }

    private func toggle(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }
}

private struct ReviewCandidateRow: View {
    let candidate: SharedSemanticCandidate
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 12) {
                Image(
                    systemName: isSelected
                        ? "checkmark.square.fill"
                        : "square"
                )
                .font(.title3)
                .foregroundStyle(
                    isSelected ? Color.accentColor : Color.secondary
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    if !candidate.evidence.isEmpty {
                        Text("“\(candidate.evidence)”")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        candidate.task?.title
            ?? candidate.entity?.name
            ?? "Suggestion"
    }

    private var detail: String {
        if let task = candidate.task {
            var pieces = [task.priority.displayName + " priority"]
            if let dueDate = task.dueDate {
                pieces.append(
                    "Due " + dueDate.formatted(
                        date: .abbreviated,
                        time: .shortened
                    )
                )
            }
            if !task.description.isEmpty {
                pieces.append(task.description)
            }
            return pieces.joined(separator: " · ")
        }
        return candidate.entity?.summary ?? ""
    }
}
