import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

enum BuiltInAIState: Sendable, Equatable {
    case notDownloaded
    case downloading(Double)
    case loading
    case ready
    case failed(String)
}

actor BuiltInLLMEngine {
    static let modelID = "mlx-community/Qwen3-1.7B-4bit"
    static let modelDisplayName = "Qwen3 1.7B · MLX 4-bit"
    static let approximateDownloadSize = "about 1 GB"

    enum EngineError: LocalizedError {
        case emptyConversation
        case emptyResponse
        case requiresAppleSilicon

        var errorDescription: String? {
            switch self {
            case .emptyConversation:
                "There is no question to answer."
            case .emptyResponse:
                "The built-in model returned an empty response."
            case .requiresAppleSilicon:
                "Built-in MLX inference requires a Mac with Apple silicon."
            }
        }
    }

    typealias StateHandler = @Sendable (BuiltInAIState) -> Void

    private let cacheRoot: URL
    private var container: ModelContainer?
    private var preparation: Task<ModelContainer, Error>?
    private var stateHandler: StateHandler?

    init(cacheRoot: URL) {
        self.cacheRoot = cacheRoot
    }

    func setStateHandler(_ handler: @escaping StateHandler) {
        stateHandler = handler
        emit(Self.hasCachedModel(in: cacheRoot) ? .loading : .notDownloaded)
    }

    func prepare() async throws {
        _ = try await modelContainer()
    }

    func complete(
        systemPrompt: String,
        messages: [ChatMessage]
    ) async throws -> String {
        guard let prompt = messages.last, prompt.role == .user else {
            throw EngineError.emptyConversation
        }

        let model = try await modelContainer()
        let history: [Chat.Message] = messages
            .dropLast()
            .suffix(14)
            .map { message in
                switch message.role {
                case .user:
                    .user(message.content)
                case .assistant:
                    .assistant(message.content)
                }
            }
        let parameters = GenerateParameters(
            maxTokens: 900,
            maxKVSize: 8_192,
            kvBits: 8,
            temperature: 0.4,
            topP: 0.8,
            topK: 20,
            repetitionPenalty: 1.05
        )
        let session = ChatSession(
            model,
            instructions: systemPrompt + "\n/no_think",
            history: history,
            generateParameters: parameters
        )
        let response = try await session.respond(to: prompt.content)
        let cleaned = Self.clean(response)
        guard !cleaned.isEmpty else { throw EngineError.emptyResponse }
        emit(.ready)
        return cleaned
    }

    private func modelContainer() async throws -> ModelContainer {
        #if !arch(arm64)
        throw EngineError.requiresAppleSilicon
        #else
        if let container {
            return container
        }
        if let preparation {
            return try await preparation.value
        }

        let cached = Self.hasCachedModel(in: cacheRoot)
        emit(cached ? .loading : .downloading(0))
        let handler = stateHandler
        let root = cacheRoot
        let task = Task<ModelContainer, Error> {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let cache = HubCache(cacheDirectory: root)
            let client = HubClient(
                userAgent: "Quill/1.0 built-in-local-ai",
                cache: cache
            )
            return try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(client),
                using: #huggingFaceTokenizerLoader(),
                configuration: LLMRegistry.qwen3_1_7b_4bit,
                progressHandler: { progress in
                    let fraction = max(0, min(1, progress.fractionCompleted))
                    handler?(fraction >= 1 ? .loading : .downloading(fraction))
                }
            )
        }
        preparation = task

        do {
            let loaded = try await task.value
            container = loaded
            preparation = nil
            emit(.ready)
            return loaded
        } catch {
            preparation = nil
            emit(.failed(error.localizedDescription))
            throw error
        }
        #endif
    }

    private func emit(_ state: BuiltInAIState) {
        stateHandler?(state)
    }

    static func hasCachedModel(in root: URL) -> Bool {
        let repository = root.appendingPathComponent(
            "models--mlx-community--Qwen3-1.7B-4bit",
            isDirectory: true
        )
        guard let enumerator = FileManager.default.enumerator(
            at: repository,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }

        var hasConfiguration = false
        var hasWeights = false
        for case let url as URL in enumerator {
            hasConfiguration = hasConfiguration || url.lastPathComponent == "config.json"
            hasWeights = hasWeights || url.pathExtension == "safetensors"
            if hasConfiguration && hasWeights {
                return true
            }
        }
        return false
    }

    static func clean(_ response: String) -> String {
        var value = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if let opening = value.range(of: "<think>"),
           let closing = value.range(
               of: "</think>",
               range: opening.upperBound..<value.endIndex
           ) {
            value.removeSubrange(opening.lowerBound..<closing.upperBound)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
