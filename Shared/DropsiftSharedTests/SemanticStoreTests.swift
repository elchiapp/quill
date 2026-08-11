import Foundation
import Testing
@testable import DropsiftShared

@Test
func semanticStoreRoundTripsAndSortsTasks() throws {
    let root = try temporarySemanticRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SharedSemanticStore(root: root)

    let low = try store.createTask(
        title: "Read background material",
        priority: .low
    )
    var urgent = try store.createTask(
        title: "Send the signed proposal",
        description: "The client is waiting.",
        dueDate: Date().addingTimeInterval(3_600),
        priority: .urgent
    )

    #expect(store.loadTasks().map(\.id) == [urgent.id, low.id])

    urgent.isCompleted = true
    try store.saveTask(urgent)
    let loaded = store.loadTasks()
    #expect(loaded.last?.id == urgent.id)
    #expect(loaded.last?.completedAt != nil)

    try store.deleteTask(low.id)
    #expect(store.loadTasks().map(\.id) == [urgent.id])
}

@Test
func semanticReviewCreatesTasksAndMergesEntities() throws {
    let root = try temporarySemanticRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SharedSemanticStore(root: root)
    let source = SharedSemanticSourceReference(
        itemID: "recording:meeting-1",
        title: "Planning call",
        locator: "Transcript · 2:10",
        excerpt: "Marco should send the proposal to Alice."
    )
    let task = SharedSemanticCandidate(
        task: SharedTaskDraft(
            title: "Send the proposal",
            description: "Send it to Alice.",
            priority: .high
        ),
        evidence: "Marco should send the proposal to Alice."
    )
    let person = SharedSemanticCandidate(
        entity: SharedEntityDraft(
            kind: .person,
            name: "Alice",
            summary: "Proposal recipient"
        ),
        evidence: "send the proposal to Alice"
    )
    let review = SharedSemanticReview(
        sourceID: source.itemID,
        sourceRevision: "revision-1",
        sourceTitle: source.title,
        source: source,
        candidates: [task, person]
    )

    #expect(try store.enqueueReview(review))
    try store.acceptReview(
        review,
        selectedCandidateIDs: [task.id, person.id]
    )

    #expect(store.loadTasks().first?.title == "Send the proposal")
    #expect(store.loadEntities().first?.name == "Alice")
    #expect(store.loadPendingReviews().isEmpty)
    #expect(store.isProcessed(sourceID: source.itemID, revision: "revision-1"))

    let secondSource = SharedSemanticSourceReference(
        itemID: "knowledge:note-2",
        title: "Follow-up note",
        locator: "Note",
        excerpt: "Alice owns customer success."
    )
    let updatedPerson = SharedSemanticCandidate(
        entity: SharedEntityDraft(
            kind: .person,
            name: "alice",
            summary: "Alice owns customer success for the account."
        ),
        evidence: secondSource.excerpt
    )
    let secondReview = SharedSemanticReview(
        sourceID: secondSource.itemID,
        sourceRevision: "revision-2",
        sourceTitle: secondSource.title,
        source: secondSource,
        candidates: [updatedPerson]
    )
    #expect(try store.enqueueReview(secondReview))
    try store.acceptReview(
        secondReview,
        selectedCandidateIDs: [updatedPerson.id]
    )

    let entities = store.loadEntities()
    #expect(entities.count == 1)
    #expect(entities.first?.sources.count == 2)
    #expect(entities.first?.summary.contains("customer success") == true)
}

@Test
func semanticReviewDismissalPreventsRepeatedSuggestions() throws {
    let root = try temporarySemanticRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SharedSemanticStore(root: root)
    let source = SharedSemanticSourceReference(
        itemID: "knowledge:note-1",
        title: "Notes",
        locator: "Note",
        excerpt: "TODO: send the recap"
    )
    let review = SharedSemanticReview(
        sourceID: source.itemID,
        sourceRevision: "revision-1",
        sourceTitle: source.title,
        source: source,
        candidates: [
            SharedSemanticCandidate(
                task: SharedTaskDraft(title: "Send the recap"),
                evidence: source.excerpt
            ),
        ]
    )

    #expect(try store.enqueueReview(review))
    try store.dismissReview(review)
    #expect(store.loadPendingReviews().isEmpty)
    #expect(store.isProcessed(sourceID: source.itemID, revision: "revision-1"))
    #expect(try !store.enqueueReview(review))
}

@Test
func semanticReviewCanBeExplicitlyExtractedAgain() throws {
    let root = try temporarySemanticRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SharedSemanticStore(root: root)
    let source = SharedSemanticSourceReference(
        itemID: "recording:meeting-2",
        title: "Planning call",
        locator: "Transcript",
        excerpt: "Action item: send the recap."
    )
    let review = SharedSemanticReview(
        sourceID: source.itemID,
        sourceRevision: "revision-1",
        sourceTitle: source.title,
        source: source,
        candidates: [
            SharedSemanticCandidate(
                task: SharedTaskDraft(title: "Send the recap"),
                evidence: source.excerpt
            ),
        ]
    )

    #expect(try store.enqueueReview(review))
    try store.dismissReview(review)
    #expect(try !store.enqueueReview(review))

    try store.resetProcessing(sourceID: source.itemID)
    #expect(!store.isProcessed(sourceID: source.itemID, revision: "revision-1"))
    #expect(try store.enqueueReview(review))
    #expect(store.loadPendingReviews().map(\.id) == [review.id])
}

@Test
func semanticExtractionParsesStructuredLocalModelResponse() {
    let source = SharedSemanticSourceReference(
        itemID: "recording:call",
        title: "Call",
        locator: "Transcript",
        excerpt: "Meet Alice in Rome and send the deck tomorrow."
    )
    let response = """
    ```json
    {
      "tasks": [{
        "title": "Send the deck",
        "description": "Send the latest deck to Alice.",
        "due_date": "2026-08-01",
        "priority": "high",
        "evidence": "send the deck tomorrow"
      }],
      "entities": [
        {
          "kind": "person",
          "name": "Alice",
          "summary": "Deck recipient",
          "start_date": null,
          "end_date": null,
          "evidence": "Alice"
        },
        {
          "kind": "place",
          "name": "Rome",
          "summary": "Meeting location",
          "start_date": null,
          "end_date": null,
          "evidence": "in Rome"
        }
      ]
    }
    ```
    """

    let candidates = SharedSemanticExtraction.parse(response, source: source)
    #expect(candidates.count == 3)
    #expect(candidates.first?.task?.priority == .high)
    #expect(candidates.first?.task?.dueDate != nil)
    #expect(candidates.compactMap(\.entity).map(\.kind) == [.person, .place])
}

@Test
func semanticHeuristicsFindExplicitActionItemsAndEvents() {
    let source = SharedSemanticSourceReference(
        itemID: "knowledge:note",
        title: "Workshop notes",
        locator: "Note",
        excerpt: ""
    )
    let candidates = SharedSemanticExtraction.heuristicCandidates(
        in: """
        Action item: Send the revised proposal by tomorrow.
        Product workshop next week with Alice Smith.
        """,
        source: source,
        processingDate: Date(timeIntervalSince1970: 1_785_456_000)
    )

    #expect(candidates.contains { $0.task?.title.contains("Send") == true })
    #expect(candidates.contains { $0.entity?.kind == .event })
}

private func temporarySemanticRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "DropsiftSemanticTests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    return url
}
