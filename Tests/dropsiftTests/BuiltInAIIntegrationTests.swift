import Foundation
import DropsiftShared
import Testing
@testable import dropsift

@Test(
    "Built-in MLX answers from transcript context without a server",
    .enabled(
        if: ProcessInfo.processInfo.environment["DROPSIFT_BUILTIN_AI_INTEGRATION"] == "1",
        "Set DROPSIFT_BUILTIN_AI_INTEGRATION=1 to download/load the app-managed model."
    )
)
func builtInMLXIntegration() async throws {
    let requestedModelID = ProcessInfo.processInfo.environment[
        "DROPSIFT_BUILTIN_AI_MODEL_ID"
    ]
    let plan = AIModelCatalog.plan(
        for: AIModelCatalog.model(id: requestedModelID),
        device: .current
    )
    let engine = BuiltInLLMEngine(
        cacheRoot: Config.modelCacheRoot,
        plan: plan
    )
    let stream = try await engine.stream(
        systemPrompt: """
        You are a transcript assistant. Use only the supplied excerpt and cite it as [1].

        [1] Release planning @ 00:04
        The team decided to ship the release on Friday.
        """,
        messages: [
            ChatMessage(role: .user, content: "When did the team decide to ship?")
        ]
    )
    var chunks: [String] = []
    for try await chunk in stream {
        chunks.append(chunk)
    }
    let answer = BuiltInLLMEngine.clean(chunks.joined())

    #expect(chunks.count > 1)
    #expect(answer.lowercased().contains("friday"))
    #expect(answer.contains("[1]"))

    let metadataResponse = try await engine.complete(
        systemPrompt: ContentPresentationGenerator.systemPrompt,
        messages: [
            ChatMessage(
                role: .user,
                content: ContentPresentationGenerator.userPrompt(
                    kind: "meeting transcript",
                    currentTitle: "Meeting · Friday",
                    text: """
                    Davide: Fineco and BKN301 need a shared integration data model.
                    Dario: We agreed to validate the API fields with the engineering team next week.
                    """
                )
            ),
        ],
        maxTokens: 512
    )
    let presentation = try #require(
        ContentPresentationGenerator.parse(
            metadataResponse,
            sourceRevision: "integration-fixture",
            model: plan.model.name
        )
    )
    #expect(presentation.title.split(separator: " ").count >= 2)
    #expect(presentation.description.count >= 12)

    let summaryResponse = try await engine.complete(
        systemPrompt: RecordingSummaryGenerator.systemPrompt,
        messages: [
            ChatMessage(
                role: .user,
                content: RecordingSummaryGenerator.userPrompt(
                    text: """
                    Davide: Fineco and BKN301 reviewed the shared integration data model.
                    Dario: We decided to use the shared asset schema.
                    Davide: I will schedule an API validation workshop for next week.
                    """,
                    detectedSpeakers: ["Davide", "Dario"],
                    characterLimit: 32_000
                )
            ),
        ],
        maxTokens: 1_536
    )
    let summary = try #require(
        RecordingSummaryGenerator.parse(
            summaryResponse,
            detectedSpeakers: ["Davide", "Dario"],
            sourceRevision: "summary-integration-fixture",
            model: plan.model.name
        )
    )
    #expect(summary.participantCount == 2)
    #expect(!summary.topics.isEmpty)
    #expect(!summary.decisions.isEmpty)
    #expect(!summary.actionItems.isEmpty)

    let conversationTitleResponse = try await engine.complete(
        systemPrompt: ContentPresentationGenerator.conversationTitleSystemPrompt,
        messages: [
            ChatMessage(
                role: .user,
                content: """
                USER: What was the call with BKN301 about?

                DROPSIFT: The Fineco and BKN301 teams discussed a shared integration data model and planned an API validation with engineering.
                """
            ),
        ],
        maxTokens: 128
    )
    let conversationTitle = try #require(
        ContentPresentationGenerator.cleanTitle(conversationTitleResponse)
    )
    #expect(conversationTitle.split(separator: " ").count >= 2)
}

@Test(
    "Built-in MLX generates metadata for a supplied recording",
    .enabled(
        if: ProcessInfo.processInfo.environment[
            "DROPSIFT_PRESENTATION_FIXTURE"
        ] != nil,
        "Set DROPSIFT_PRESENTATION_FIXTURE to a recording directory."
    )
)
func builtInMLXPresentationFixture() async throws {
    let path = try #require(
        ProcessInfo.processInfo.environment["DROPSIFT_PRESENTATION_FIXTURE"]
    )
    let recording = try #require(
        RecordingItem.load(from: URL(fileURLWithPath: path, isDirectory: true))
    )
    let text = (recording.transcript?.segments ?? [])
        .map(\.text)
        .joined(separator: "\n")
    let requestedModelID = ProcessInfo.processInfo.environment[
        "DROPSIFT_BUILTIN_AI_MODEL_ID"
    ]
    let plan = AIModelCatalog.plan(
        for: AIModelCatalog.model(id: requestedModelID),
        device: .current
    )
    let engine = BuiltInLLMEngine(
        cacheRoot: Config.modelCacheRoot,
        plan: plan
    )
    let response = try await engine.complete(
        systemPrompt: ContentPresentationGenerator.systemPrompt,
        messages: [
            ChatMessage(
                role: .user,
                content: ContentPresentationGenerator.userPrompt(
                    kind: "recording or meeting transcript",
                    currentTitle: recording.title,
                    text: text
                )
            ),
        ],
        maxTokens: 512
    )
    print("RAW PRESENTATION RESPONSE:\n\(response)")
    let presentation = try #require(
        ContentPresentationGenerator.parse(
            response,
            sourceRevision: "fixture",
            model: plan.model.name
        )
    )
    print("PARSED TITLE: \(presentation.title)")
    print("PARSED DESCRIPTION: \(presentation.description)")
}
