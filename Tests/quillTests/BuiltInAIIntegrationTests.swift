import Foundation
import Testing
@testable import quill

@Test(
    "Built-in MLX answers from transcript context without a server",
    .enabled(
        if: ProcessInfo.processInfo.environment["QUILL_BUILTIN_AI_INTEGRATION"] == "1",
        "Set QUILL_BUILTIN_AI_INTEGRATION=1 to download/load the app-managed model."
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
    let answer = try await engine.complete(
        systemPrompt: """
        You are a transcript assistant. Use only the supplied excerpt and cite it as [1].

        [1] Release planning @ 00:04
        The team decided to ship the release on Friday.
        """,
        messages: [
            ChatMessage(role: .user, content: "When did the team decide to ship?")
        ]
    )

    #expect(answer.lowercased().contains("friday"))
    #expect(answer.contains("[1]"))
}
