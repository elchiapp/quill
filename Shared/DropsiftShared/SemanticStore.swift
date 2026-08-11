import Foundation

public struct SharedSemanticStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var semanticsRoot: URL {
        root.appendingPathComponent("Semantics", isDirectory: true)
    }

    public var tasksRoot: URL {
        semanticsRoot.appendingPathComponent("Tasks", isDirectory: true)
    }

    public var entitiesRoot: URL {
        semanticsRoot.appendingPathComponent("Entities", isDirectory: true)
    }

    public var reviewsRoot: URL {
        semanticsRoot.appendingPathComponent("Pending Reviews", isDirectory: true)
    }

    public var processedRoot: URL {
        semanticsRoot.appendingPathComponent("Processed", isDirectory: true)
    }

    public func prepare() throws {
        for directory in [
            semanticsRoot,
            tasksRoot,
            entitiesRoot,
            reviewsRoot,
            processedRoot,
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    public func loadTasks() -> [SharedTask] {
        load(SharedTask.self, from: tasksRoot)
            .sorted(by: Self.taskSort)
    }

    public func loadEntities(
        kind: SharedSemanticEntityKind? = nil
    ) -> [SharedSemanticEntity] {
        load(SharedSemanticEntity.self, from: entitiesRoot)
            .filter { kind == nil || $0.kind == kind }
            .sorted {
                if $0.kind != $1.kind {
                    return $0.kind.rawValue < $1.kind.rawValue
                }
                let firstDate = $0.startDate ?? .distantFuture
                let secondDate = $1.startDate ?? .distantFuture
                if firstDate != secondDate { return firstDate < secondDate }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    public func loadPendingReviews() -> [SharedSemanticReview] {
        load(SharedSemanticReview.self, from: reviewsRoot)
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func createTask(
        title: String = "New task",
        description: String = "",
        dueDate: Date? = nil,
        priority: SharedTaskPriority = .medium,
        sources: [SharedSemanticSourceReference] = []
    ) throws -> SharedTask {
        let task = SharedTask(
            title: Self.nonempty(title, fallback: "New task"),
            description: description,
            dueDate: dueDate,
            priority: priority,
            sources: sources
        )
        try write(task, to: tasksRoot)
        return task
    }

    public func saveTask(_ task: SharedTask) throws {
        var updated = task
        updated.title = Self.nonempty(updated.title, fallback: "Untitled task")
        updated.updatedAt = Date()
        if updated.isCompleted, updated.completedAt == nil {
            updated.completedAt = Date()
        } else if !updated.isCompleted {
            updated.completedAt = nil
        }
        try write(updated, to: tasksRoot)
    }

    public func deleteTask(_ id: UUID) throws {
        try remove(id, from: tasksRoot)
    }

    public func saveEntity(_ entity: SharedSemanticEntity) throws {
        var updated = entity
        updated.name = Self.nonempty(
            updated.name,
            fallback: updated.kind.singularName
        )
        updated.updatedAt = Date()
        try write(updated, to: entitiesRoot)
    }

    public func deleteEntity(_ id: UUID) throws {
        try remove(id, from: entitiesRoot)
    }

    @discardableResult
    public func enqueueReview(_ review: SharedSemanticReview) throws -> Bool {
        try prepare()
        guard !isProcessed(
            sourceID: review.sourceID,
            revision: review.sourceRevision
        ) else { return false }
        let alreadyPending = loadPendingReviews().contains {
            $0.sourceID == review.sourceID
                && $0.sourceRevision == review.sourceRevision
        }
        guard !alreadyPending else { return false }
        if review.candidates.isEmpty {
            try markProcessed(
                sourceID: review.sourceID,
                revision: review.sourceRevision
            )
            return false
        }
        try write(review, to: reviewsRoot)
        return true
    }

    public func acceptReview(
        _ review: SharedSemanticReview,
        selectedCandidateIDs: Set<UUID>
    ) throws {
        try prepare()
        var tasks = loadTasks()
        var entities = loadEntities()
        for candidate in review.candidates where selectedCandidateIDs.contains(candidate.id) {
            switch candidate.kind {
            case .task:
                guard let draft = candidate.task else { continue }
                let normalized = Self.normalized(draft.title)
                let isDuplicate = tasks.contains {
                    Self.normalized($0.title) == normalized
                        && $0.sources.contains(where: {
                            $0.itemID == review.source.itemID
                        })
                }
                guard !isDuplicate else { continue }
                let task = SharedTask(
                    title: Self.nonempty(draft.title, fallback: "Untitled task"),
                    description: draft.description,
                    dueDate: draft.dueDate,
                    priority: draft.priority,
                    sources: [Self.source(review.source, evidence: candidate.evidence)]
                )
                try write(task, to: tasksRoot)
                tasks.append(task)
            case .entity:
                guard let draft = candidate.entity else { continue }
                let normalized = Self.normalized(draft.name)
                if let index = entities.firstIndex(where: {
                    $0.kind == draft.kind && Self.normalized($0.name) == normalized
                }) {
                    var existing = entities[index]
                    let source = Self.source(review.source, evidence: candidate.evidence)
                    if !existing.sources.contains(where: { $0.id == source.id }) {
                        existing.sources.append(source)
                    }
                    if existing.summary.isEmpty
                        || draft.summary.count > existing.summary.count
                    {
                        existing.summary = draft.summary
                    }
                    existing.startDate = existing.startDate ?? draft.startDate
                    existing.endDate = existing.endDate ?? draft.endDate
                    existing.updatedAt = Date()
                    try write(existing, to: entitiesRoot)
                    entities[index] = existing
                } else {
                    let entity = SharedSemanticEntity(
                        kind: draft.kind,
                        name: Self.nonempty(
                            draft.name,
                            fallback: draft.kind.singularName
                        ),
                        summary: draft.summary,
                        startDate: draft.startDate,
                        endDate: draft.endDate,
                        sources: [
                            Self.source(review.source, evidence: candidate.evidence),
                        ]
                    )
                    try write(entity, to: entitiesRoot)
                    entities.append(entity)
                }
            }
        }
        try finish(review)
    }

    public func dismissReview(_ review: SharedSemanticReview) throws {
        try prepare()
        try finish(review)
    }

    /// Removes extraction bookkeeping for one library item so the user can
    /// explicitly analyze it again, even after accepting or dismissing an
    /// earlier set of suggestions.
    public func resetProcessing(sourceID: String) throws {
        try prepare()
        for review in loadPendingReviews() where review.sourceID == sourceID {
            try remove(review.id, from: reviewsRoot)
        }
        let processed = load(
            SharedSemanticProcessedRecord.self,
            from: processedRoot
        )
        for record in processed where record.sourceID == sourceID {
            try remove(record.id, from: processedRoot)
        }
    }

    public func isProcessed(sourceID: String, revision: String) -> Bool {
        load(SharedSemanticProcessedRecord.self, from: processedRoot).contains {
            $0.sourceID == sourceID && $0.sourceRevision == revision
        }
    }

    private func finish(_ review: SharedSemanticReview) throws {
        try markProcessed(
            sourceID: review.sourceID,
            revision: review.sourceRevision
        )
        try? remove(review.id, from: reviewsRoot)
    }

    private func markProcessed(sourceID: String, revision: String) throws {
        let record = SharedSemanticProcessedRecord(
            sourceID: sourceID,
            sourceRevision: revision
        )
        try write(record, to: processedRoot)
    }

    private func load<Value: Decodable>(
        _ type: Value.Type,
        from directory: URL
    ) -> [Value] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.compactMap { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url)
            else { return nil }
            return try? Self.makeDecoder().decode(type, from: data)
        }
    }

    private func write<Value: Encodable & Identifiable>(
        _ value: Value,
        to directory: URL
    ) throws where Value.ID == UUID {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(
            value.id.uuidString + ".json"
        )
        try Self.makeEncoder().encode(value).write(to: url, options: .atomic)
    }

    private func remove(_ id: UUID, from directory: URL) throws {
        let url = directory.appendingPathComponent(id.uuidString + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func taskSort(_ lhs: SharedTask, _ rhs: SharedTask) -> Bool {
        if lhs.isCompleted != rhs.isCompleted { return !lhs.isCompleted }
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        let leftDate = lhs.dueDate ?? .distantFuture
        let rightDate = rhs.dueDate ?? .distantFuture
        if leftDate != rightDate { return leftDate < rightDate }
        return lhs.updatedAt > rhs.updatedAt
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonempty(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func source(
        _ source: SharedSemanticSourceReference,
        evidence: String
    ) -> SharedSemanticSourceReference {
        let excerpt = evidence
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SharedSemanticSourceReference(
            itemID: source.itemID,
            title: source.title,
            locator: source.locator,
            excerpt: excerpt.isEmpty ? source.excerpt : excerpt,
            startMs: source.startMs,
            page: source.page
        )
    }
}
