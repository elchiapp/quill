import DropsiftShared
import SwiftUI

struct MobileRootView: View {
    @ObservedObject var model: MobileAppModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            NavigationStack {
                MobileCaptureView(model: model)
            }
            .tabItem {
                Label("Capture", systemImage: "plus.app.fill")
            }
            .tag(MobileTab.capture)

            MobileTimelineView(model: model)
                .tabItem {
                    Label("Timeline", systemImage: "clock.arrow.circlepath")
                }
                .tag(MobileTab.timeline)

            NavigationStack {
                MobileOrganizeView(model: model)
            }
            .tabItem {
                Label("Organize", systemImage: "square.grid.2x2")
            }
            .tag(MobileTab.organize)

            NavigationStack {
                MobileAskView(model: model)
            }
            .tabItem {
                Label("Ask", systemImage: "sparkles")
            }
            .tag(MobileTab.ask)
        }
        .tint(.indigo)
        .overlay(alignment: .top) {
            if let label = model.importState.label
                ?? model.semanticProcessingLabel
            {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(label)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 8, y: 3)
                .padding(.top, 8)
            }
        }
        .alert(
            "Dropsift",
            isPresented: Binding(
                get: {
                    model.errorMessage != nil
                        || model.locator.errorMessage != nil
                        || model.recorder.errorMessage != nil
                },
                set: { value in
                    if !value {
                        model.errorMessage = nil
                        model.locator.errorMessage = nil
                        model.recorder.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK") {
                model.errorMessage = nil
                model.locator.errorMessage = nil
                model.recorder.errorMessage = nil
            }
        } message: {
            Text(
                model.errorMessage
                    ?? model.locator.errorMessage
                    ?? model.recorder.errorMessage
                    ?? ""
            )
        }
    }
}

private struct MobileOrganizeView: View {
    @ObservedObject var model: MobileAppModel

    var body: some View {
        List {
            Section {
                NavigationLink {
                    MobileTasksView(model: model)
                } label: {
                    OrganizeRow(
                        title: "Tasks",
                        subtitle: "\(model.tasks.filter { !$0.isCompleted }.count) open",
                        icon: "checklist",
                        color: .indigo
                    )
                }
            }

            Section("Knowledge graph") {
                ForEach(SharedSemanticEntityKind.allCases) { kind in
                    NavigationLink {
                        MobileEntitiesView(model: model, kind: kind)
                    } label: {
                        OrganizeRow(
                            title: kind.displayName,
                            subtitle: "\(model.entities.filter { $0.kind == kind }.count) saved",
                            icon: kind.systemImage,
                            color: color(for: kind)
                        )
                    }
                }
            }

            Section("About") {
                LabeledContent("Version", value: versionLabel)
            }
        }
        .navigationTitle("Organize")
    }

    private var versionLabel: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "Development"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    private func color(for kind: SharedSemanticEntityKind) -> Color {
        switch kind {
        case .person: .blue
        case .place: .green
        case .event: .red
        case .organization: .orange
        case .project: .purple
        case .topic: .teal
        }
    }
}

private struct OrganizeRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 38, height: 38)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct MobileTasksView: View {
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

    @ObservedObject var model: MobileAppModel
    @State private var sort: Sort = .priority
    @State private var showCompleted = true

    private var tasks: [SharedTask] {
        model.tasks
            .filter { showCompleted || !$0.isCompleted }
            .sorted { lhs, rhs in
                if lhs.isCompleted != rhs.isCompleted { return !lhs.isCompleted }
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
        List {
            if tasks.isEmpty {
                ContentUnavailableView(
                    "No tasks",
                    systemImage: "checklist",
                    description: Text(
                        "Create one, or accept an action item Dropsift finds while processing your knowledge."
                    )
                )
            } else {
                ForEach(tasks) { task in
                    NavigationLink {
                        MobileTaskEditor(model: model, task: task)
                    } label: {
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
                                .foregroundStyle(
                                    task.isCompleted ? .green : .secondary
                                )
                            }
                            .buttonStyle(.plain)

                            VStack(alignment: .leading, spacing: 5) {
                                Text(task.title)
                                    .font(.body.weight(.medium))
                                    .strikethrough(task.isCompleted)
                                    .foregroundStyle(
                                        task.isCompleted ? .secondary : .primary
                                    )
                                HStack(spacing: 7) {
                                    Text(task.priority.displayName)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(
                                            task.priority == .urgent
                                                ? .red
                                                : .secondary
                                        )
                                    if let due = task.dueDate {
                                        Text(
                                            due.formatted(
                                                date: .abbreviated,
                                                time: .omitted
                                            )
                                        )
                                        .font(.caption)
                                        .foregroundStyle(
                                            !task.isCompleted && due < Date()
                                                ? .red
                                                : .secondary
                                        )
                                    }
                                }
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            model.deleteTask(task)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("Tasks")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(Sort.allCases) {
                            Text($0.label).tag($0)
                        }
                    }
                    Toggle("Show completed", isOn: $showCompleted)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                Button {
                    model.createTask()
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }
}

private struct MobileTaskEditor: View {
    @ObservedObject var model: MobileAppModel
    @Environment(\.dismiss) private var dismiss
    let task: SharedTask

    @State private var title: String
    @State private var description: String
    @State private var priority: SharedTaskPriority
    @State private var hasDueDate: Bool
    @State private var dueDate: Date

    init(model: MobileAppModel, task: SharedTask) {
        self.model = model
        self.task = task
        _title = State(initialValue: task.title)
        _description = State(initialValue: task.description)
        _priority = State(initialValue: task.priority)
        _hasDueDate = State(initialValue: task.dueDate != nil)
        _dueDate = State(initialValue: task.dueDate ?? Date())
    }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $title, axis: .vertical)
                    .font(.headline)
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(4...10)
            }

            Section {
                Picker("Priority", selection: $priority) {
                    ForEach(SharedTaskPriority.allCases) {
                        Text($0.displayName).tag($0)
                    }
                }
                Toggle("Due date", isOn: $hasDueDate)
                if hasDueDate {
                    DatePicker(
                        "Due",
                        selection: $dueDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
                Button {
                    var updated = task
                    updated.isCompleted.toggle()
                    model.saveTask(updated)
                } label: {
                    Label(
                        task.isCompleted ? "Reopen task" : "Mark complete",
                        systemImage: task.isCompleted
                            ? "arrow.uturn.backward.circle"
                            : "checkmark.circle"
                    )
                }
            }

            if !task.sources.isEmpty {
                Section("Sources") {
                    ForEach(task.sources) { source in
                        Button {
                            model.openSemanticSource(source)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.title)
                                Text(source.locator)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                Button("Delete task", role: .destructive) {
                    model.deleteTask(task)
                    dismiss()
                }
            }
        }
        .navigationTitle("Task")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var updated = task
                    updated.title = title
                    updated.description = description
                    updated.priority = priority
                    updated.dueDate = hasDueDate ? dueDate : nil
                    model.saveTask(updated)
                    dismiss()
                }
                .disabled(
                    title.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                )
            }
        }
    }
}

private struct MobileEntitiesView: View {
    @ObservedObject var model: MobileAppModel
    let kind: SharedSemanticEntityKind

    private var entities: [SharedSemanticEntity] {
        model.entities
            .filter { $0.kind == kind }
            .sorted {
                ($0.startDate ?? .distantFuture)
                    < ($1.startDate ?? .distantFuture)
            }
    }

    var body: some View {
        List {
            if entities.isEmpty {
                ContentUnavailableView(
                    "No \(kind.displayName.lowercased()) yet",
                    systemImage: kind.systemImage,
                    description: Text(
                        "Dropsift will suggest them while processing recordings and files."
                    )
                )
            } else {
                ForEach(entities) { entity in
                    NavigationLink {
                        MobileEntityEditor(model: model, entity: entity)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entity.name)
                                .font(.body.weight(.medium))
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
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            model.deleteEntity(entity)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle(kind.displayName)
        .toolbar {
            Button {
                model.createEntity(kind: kind)
            } label: {
                Image(systemName: "plus")
            }
        }
    }
}

private struct MobileEntityEditor: View {
    @ObservedObject var model: MobileAppModel
    @Environment(\.dismiss) private var dismiss
    let entity: SharedSemanticEntity

    @State private var name: String
    @State private var summary: String
    @State private var hasStartDate: Bool
    @State private var startDate: Date
    @State private var hasEndDate: Bool
    @State private var endDate: Date

    init(model: MobileAppModel, entity: SharedSemanticEntity) {
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
        Form {
            Section {
                TextField(entity.kind.singularName, text: $name)
                TextField("Notes", text: $summary, axis: .vertical)
                    .lineLimit(4...10)
            }

            if entity.kind == .event {
                Section("Schedule") {
                    Toggle("Start date", isOn: $hasStartDate)
                    if hasStartDate {
                        DatePicker(
                            "Starts",
                            selection: $startDate,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                    Toggle("End date", isOn: $hasEndDate)
                    if hasEndDate {
                        DatePicker(
                            "Ends",
                            selection: $endDate,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                }
            }

            if !entity.sources.isEmpty {
                Section("Sources") {
                    ForEach(entity.sources) { source in
                        Button {
                            model.openSemanticSource(source)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.title)
                                Text(source.locator)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                Button("Delete", role: .destructive) {
                    model.deleteEntity(entity)
                    dismiss()
                }
            }
        }
        .navigationTitle(entity.kind.singularName)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
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
                    dismiss()
                }
                .disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                )
            }
        }
    }
}

struct MobileSemanticInsightsView: View {
    @ObservedObject var model: MobileAppModel
    let sourceID: String

    private var review: SharedSemanticReview? {
        model.semanticReview(for: sourceID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("Tasks & details", systemImage: "wand.and.stars")
                    .font(.headline)
                Spacer()
                if model.semanticProcessingSourceID == sourceID {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(review == nil ? "Extract" : "Extract again") {
                        model.requestSemanticExtraction(for: sourceID)
                    }
                    .font(.subheadline)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let review {
                MobileSemanticReviewContents(model: model, review: review)
                    .id(review.id)
            } else if model.semanticProcessingSourceID == sourceID {
                Text("Extracting possible to-dos, people, places, events, projects, and topics locally…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Suggestions stay with this item until you review them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(
            Color.secondary.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 14)
        )
    }
}

private struct MobileSemanticReviewContents: View {
    @ObservedObject var model: MobileAppModel
    let review: SharedSemanticReview
    @State private var selectedIDs: Set<UUID>

    init(model: MobileAppModel, review: SharedSemanticReview) {
        self.model = model
        self.review = review
        _selectedIDs = State(initialValue: Set(review.candidates.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("I found these things worth organizing. They’re all selected by default.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            candidateGroup(
                title: "Things to do",
                candidates: review.candidates.filter { $0.kind == .task }
            )

            ForEach(SharedSemanticEntityKind.allCases) { kind in
                candidateGroup(
                    title: kind.displayName,
                    candidates: review.candidates.filter {
                        $0.entity?.kind == kind
                    }
                )
            }

            HStack {
                Button("Dismiss") {
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
                Button("Add \(selectedIDs.count)") {
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
                    candidateRow(candidate)
                }
            }
        }
    }

    private func candidateRow(_ candidate: SharedSemanticCandidate) -> some View {
        Button {
            toggle(candidate.id)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selectedIDs.contains(candidate.id)
                    ? "checkmark.square.fill"
                    : "square")
                    .foregroundStyle(selectedIDs.contains(candidate.id)
                        ? Color.accentColor
                        : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.task?.title
                        ?? candidate.entity?.name
                        ?? "Suggestion")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    let detail = candidate.task?.description
                        ?? candidate.entity?.summary
                        ?? ""
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }
}
