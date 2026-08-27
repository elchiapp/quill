import DropsiftShared
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum MobileAnswerService {
    enum AnswerError: LocalizedError {
        case appleIntelligenceUnavailable

        var errorDescription: String? {
            switch self {
            case .appleIntelligenceUnavailable:
                "Apple Intelligence isn’t available on this iPhone. Choose Automatic or Local source search."
            }
        }
    }

    static var isAppleIntelligenceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    static func resolvedModel(for selection: MobileAnswerModel) -> MobileAnswerModel {
        switch selection {
        case .automatic:
            isAppleIntelligenceAvailable ? .appleIntelligence : .localSearch
        case .appleIntelligence, .localSearch:
            selection
        }
    }

    static func answer(
        question: String,
        sources: [SharedSearchResult],
        model selection: MobileAnswerModel
    ) async throws -> String {
        guard !sources.isEmpty else {
            return "I couldn’t find anything relevant in your DropSift library."
        }

        let model = resolvedModel(for: selection)
        if model == .localSearch {
            return extractiveAnswer(sources)
        }

        #if canImport(FoundationModels)
        if model == .appleIntelligence, #available(iOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else {
                throw AnswerError.appleIntelligenceUnavailable
            }
            let context = sources.enumerated().map { index, source in
                "[\(index + 1)] \(source.title) · \(source.locator)\n\(source.text)"
            }
            .joined(separator: "\n\n")
            .prefix(14_000)
            let session = LanguageModelSession(
                model: .default,
                instructions: """
                You are DropSift, a private local knowledge assistant. Answer only from the
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

        throw AnswerError.appleIntelligenceUnavailable
    }

    private static func extractiveAnswer(
        _ sources: [SharedSearchResult]
    ) -> String {
        let excerpts = sources.prefix(3).enumerated().map { index, source in
            "[\(index + 1)] \(source.title) · \(source.locator): \(source.text)"
        }
        return """
        Here are the most relevant local results:

        \(excerpts.joined(separator: "\n\n"))
        """
    }
}

enum MobileSemanticExtractionService {
    static func candidates(
        text: String,
        sourceTitle: String,
        source: SharedSemanticSourceReference
    ) async -> [SharedSemanticCandidate] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *),
           SystemLanguageModel.default.isAvailable {
            do {
                let session = LanguageModelSession(
                    model: .default,
                    instructions: SharedSemanticExtraction.systemPrompt
                )
                let response = try await session.respond(
                    to: SharedSemanticExtraction.userPrompt(
                        text: text,
                        sourceTitle: sourceTitle
                    )
                )
                let parsed = SharedSemanticExtraction.parse(
                    response.content,
                    source: source
                )
                if !parsed.isEmpty { return parsed }
            } catch {
                // The deterministic fallback below keeps ingestion useful on
                // devices where the system model is busy or unavailable.
            }
        }
        #endif
        return SharedSemanticExtraction.heuristicCandidates(
            in: text,
            source: source
        )
    }
}
