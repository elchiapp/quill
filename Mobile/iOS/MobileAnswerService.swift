import DropsiftShared
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum MobileAnswerService {
    static func answer(
        question: String,
        sources: [SharedSearchResult]
    ) async throws -> String {
        guard !sources.isEmpty else {
            return "I couldn’t find anything relevant in your Dropsift library."
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *),
           SystemLanguageModel.default.isAvailable {
            let context = sources.enumerated().map { index, source in
                "[\(index + 1)] \(source.title) · \(source.locator)\n\(source.text)"
            }
            .joined(separator: "\n\n")
            .prefix(14_000)
            let session = LanguageModelSession(
                model: .default,
                instructions: """
                You are Dropsift, a private local knowledge assistant. Answer only from the
                supplied sources. Cite claims inline as [1], [2], and say when the sources
                are insufficient. Keep the answer concise.
                """
            )
            let response = try await session.respond(
                to: "Question: \(question)\n\nSources:\n\(context)"
            )
            return response.content
        }
        #endif

        let excerpts = sources.prefix(3).enumerated().map { index, source in
            "[\(index + 1)] \(source.title) · \(source.locator): \(source.text)"
        }
        return """
        Apple Intelligence isn’t available on this iPhone, so here are the most relevant local results:

        \(excerpts.joined(separator: "\n\n"))
        """
    }
}
