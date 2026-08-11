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
    let plan = AIModelCatalog.plan(
        for: AIModelCatalog.defaultModel,
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
        ]
    )
    let presentation = try #require(
        ContentPresentationGenerator.parse(
            metadataResponse,
            sourceRevision: "integration-fixture",
            model: plan.model.name
        )
    )
    #expect(
        presentation.title.localizedCaseInsensitiveContains("Fineco")
            || presentation.title.localizedCaseInsensitiveContains("BKN301")
    )
    #expect(presentation.description.count >= 12)

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
        ]
    )
    let conversationTitle = try #require(
        ContentPresentationGenerator.cleanTitle(conversationTitleResponse)
    )
    #expect(
        conversationTitle.localizedCaseInsensitiveContains("Fineco")
            || conversationTitle.localizedCaseInsensitiveContains("BKN301")
    )
}
