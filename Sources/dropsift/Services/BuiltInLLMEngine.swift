import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

enum BuiltInAIState: Sendable, Equatable {
    case notDownloaded
    case downloaded
    case downloading(Double)
    case loading
    case ready
    case failed(String)
}

actor BuiltInLLMEngine {
    enum EngineError: LocalizedError {
        case emptyConversation
        case emptyResponse
        case modelChanged
        case requiresAppleSilicon

        var errorDescription: String? {
            switch self {
            case .emptyConversation:
                "There is no question to answer."
            case .emptyResponse:
                "The built-in model returned an empty response."
            case .modelChanged:
                "The selected local model changed while it was loading."
            case .requiresAppleSilicon:
                "Built-in MLX inference requires a Mac with Apple silicon."
            }
        }
    }

    typealias StateHandler = @Sendable (BuiltInAIState) -> Void

    private let cacheRoot: URL
    private var plan: BuiltInModelPlan
    private var container: ModelContainer?
    private var loadedModelID: String?
    private var preparation: (
        modelID: String,
        task: Task<ModelContainer, Error>
    )?
    private var stateHandler: StateHandler?

    init(cacheRoot: URL, plan: BuiltInModelPlan) {
        self.cacheRoot = cacheRoot
        self.plan = plan
        configureMemoryLimit(for: plan)
    }

    func setStateHandler(_ handler: @escaping StateHandler) {
        stateHandler = handler
        if loadedModelID == plan.model.id, container != nil {
            emit(.ready)
        } else {
            emit(
                Self.hasCachedModel(plan.model, in: cacheRoot)
                    ? .downloaded
                    : .notDownloaded
            )
        }
    }

    func configure(_ newPlan: BuiltInModelPlan) {
        let modelChanged = newPlan.model.id != plan.model.id
        plan = newPlan
        configureMemoryLimit(for: newPlan)

        if modelChanged {
            preparation?.task.cancel()
            preparation = nil
            container = nil
            loadedModelID = nil
            Memory.clearCache()
        }

        if loadedModelID == newPlan.model.id, container != nil {
            emit(.ready)
        } else {
            emit(
                Self.hasCachedModel(newPlan.model, in: cacheRoot)
                    ? .downloaded
                    : .notDownloaded
            )
        }
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
            .suffix(min(48, max(14, plan.contextTokens / 8_192)))
            .map { message in
                switch message.role {
                case .user:
                    .user(message.content)
                case .assistant:
                    .assistant(message.content)
                }
            }
        let parameters = GenerateParameters(
            maxTokens: min(2_048, max(900, plan.contextTokens / 64)),
            maxKVSize: plan.contextTokens,
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
        if let container, loadedModelID == plan.model.id {
            return container
        }
        if let preparation, preparation.modelID == plan.model.id {
            return try await finish(
                preparation.task,
                modelID: preparation.modelID
            )
        }

        let requestedPlan = plan
        let modelID = requestedPlan.model.id
        let cached = Self.hasCachedModel(requestedPlan.model, in: cacheRoot)
        emit(cached ? .loading : .downloading(0))
        let root = cacheRoot
        let task = Task<ModelContainer, Error> {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let cache = HubCache(cacheDirectory: root)
            let client = HubClient(
                userAgent: "Dropsift/1.0 built-in-local-ai",
                cache: cache
            )
            let configuration = ModelConfiguration(
                id: modelID,
                extraEOSTokens: ["<|im_end|>"]
            )
            return try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(client),
                using: #huggingFaceTokenizerLoader(),
                configuration: configuration,
                progressHandler: { progress in
                    let fraction = max(0, min(1, progress.fractionCompleted))
                    Task {
                        await self.updateDownloadProgress(
                            fraction,
                            modelID: modelID
                        )
                    }
                }
            )
        }
        preparation = (modelID, task)
        return try await finish(task, modelID: modelID)
        #endif
    }

    private func finish(
        _ task: Task<ModelContainer, Error>,
        modelID: String
    ) async throws -> ModelContainer {
        do {
            let loaded = try await task.value
            guard plan.model.id == modelID else {
                throw EngineError.modelChanged
            }
            container = loaded
            loadedModelID = modelID
            preparation = nil
            emit(.ready)
            return loaded
        } catch {
            if preparation?.modelID == modelID {
                preparation = nil
            }
            if plan.model.id == modelID {
                emit(.failed(error.localizedDescription))
            }
            throw error
        }
    }

    private func updateDownloadProgress(_ fraction: Double, modelID: String) {
        guard plan.model.id == modelID else { return }
        emit(fraction >= 1 ? .loading : .downloading(fraction))
    }

    private nonisolated func configureMemoryLimit(for plan: BuiltInModelPlan) {
        let limit = Int(
            min(UInt64(Int.max), plan.memoryBudgetBytes)
        )
        let minimumCacheBytes: UInt64 = 64 * 1_024 * 1_024
        let maximumCacheBytes: UInt64 = 512 * 1_024 * 1_024
        let requestedCacheBytes = max(
            minimumCacheBytes,
            plan.memoryBudgetBytes / 32
        )
        let cacheLimit = Int(min(maximumCacheBytes, requestedCacheBytes))
        Memory.memoryLimit = limit
        Memory.cacheLimit = cacheLimit
    }

    private func emit(_ state: BuiltInAIState) {
        stateHandler?(state)
    }

    static func hasCachedModel(_ model: BuiltInModel, in root: URL) -> Bool {
        let repository = root.appendingPathComponent(
            "models--" + model.id.replacingOccurrences(of: "/", with: "--"),
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
