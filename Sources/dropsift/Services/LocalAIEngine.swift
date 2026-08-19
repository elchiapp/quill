import Foundation

actor LocalAIEngine {
    typealias StateHandler = @Sendable (BuiltInAIState) -> Void

    private let native: BuiltInLLMEngine
    private let qvac: QVACLLMEngine
    private var backend: AIBackend
    private var plan: BuiltInModelPlan
    private var stateHandler: StateHandler?

    init(
        cacheRoot: URL,
        plan: BuiltInModelPlan,
        backend: AIBackend
    ) {
        native = BuiltInLLMEngine(cacheRoot: cacheRoot, plan: plan)
        qvac = QVACLLMEngine(plan: plan)
        self.plan = plan
        self.backend = backend
    }

    func setStateHandler(_ handler: @escaping StateHandler) async {
        stateHandler = handler
        await native.setStateHandler { [weak self] state in
            Task { await self?.received(state, from: .native) }
        }
        await qvac.setStateHandler { [weak self] state in
            Task { await self?.received(state, from: .qvac) }
        }
        handler(await activeState())
    }

    func setBackend(_ newBackend: AIBackend) async {
        guard newBackend != backend else {
            stateHandler?(await activeState())
            return
        }
        let oldBackend = backend
        backend = newBackend
        if oldBackend == .qvac {
            await qvac.unload()
        } else {
            await native.cancelPreparation()
            await native.unloadModel(plan.model.id)
        }
        if newBackend == .native {
            await native.configure(plan)
        } else {
            await qvac.configure(plan)
        }
        stateHandler?(await activeState())
    }

    func configure(_ newPlan: BuiltInModelPlan) async {
        plan = newPlan
        await native.configure(newPlan)
        await qvac.configure(newPlan)
    }

    func prepare() async throws {
        switch backend {
        case .native: try await native.prepare()
        case .qvac: try await qvac.prepare()
        }
    }

    func cancelPreparation() async {
        switch backend {
        case .native: await native.cancelPreparation()
        case .qvac: await qvac.cancelPreparation()
        }
    }

    func unloadModel(_ modelID: String) async {
        await native.unloadModel(modelID)
    }

    func complete(
        systemPrompt: String,
        messages: [ChatMessage],
        maxTokens: Int? = nil
    ) async throws -> String {
        switch backend {
        case .native:
            try await native.complete(
                systemPrompt: systemPrompt,
                messages: messages,
                maxTokens: maxTokens
            )
        case .qvac:
            try await qvac.complete(
                systemPrompt: systemPrompt,
                messages: messages,
                maxTokens: maxTokens
            )
        }
    }

    func stream(
        systemPrompt: String,
        messages: [ChatMessage],
        maxTokens: Int? = nil
    ) async throws -> AsyncThrowingStream<String, Error> {
        switch backend {
        case .native:
            try await native.stream(
                systemPrompt: systemPrompt,
                messages: messages,
                maxTokens: maxTokens
            )
        case .qvac:
            try await qvac.stream(
                systemPrompt: systemPrompt,
                messages: messages,
                maxTokens: maxTokens
            )
        }
    }

    private func received(_ state: BuiltInAIState, from source: AIBackend) {
        guard source == backend else { return }
        stateHandler?(state)
    }

    private func activeState() async -> BuiltInAIState {
        switch backend {
        case .native:
            if BuiltInLLMEngine.hasCachedModel(plan.model, in: Config.modelCacheRoot) {
                return .downloaded
            }
            return .notDownloaded
        case .qvac:
            return await qvac.currentState()
        }
    }
}
