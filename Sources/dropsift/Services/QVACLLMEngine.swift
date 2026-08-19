import Foundation

actor QVACLLMEngine {
    typealias StateHandler = @Sendable (BuiltInAIState) -> Void

    private let runtime: QVACRuntime
    private var plan: BuiltInModelPlan
    private var ready = false
    private var state: BuiltInAIState = .notDownloaded
    private var stateHandler: StateHandler?

    init(
        runtime: QVACRuntime = .shared,
        plan: BuiltInModelPlan
    ) {
        self.runtime = runtime
        self.plan = plan
    }

    func setStateHandler(_ handler: @escaping StateHandler) {
        stateHandler = handler
        handler(state)
    }

    func currentState() -> BuiltInAIState { state }

    func configure(_ newPlan: BuiltInModelPlan) async {
        let changed = newPlan.model.id != plan.model.id
            || newPlan.contextTokens != plan.contextTokens
        plan = newPlan
        guard changed, ready else { return }
        _ = try? await runtime.request("unloadLLM")
        ready = false
        emit(.notDownloaded)
    }

    func prepare() async throws {
        guard !ready else {
            emit(.ready)
            return
        }
        emit(.downloading(0))
        let selectedPlan = plan
        do {
            _ = try await runtime.request(
                "prepareLLM",
                params: QVACBridgeParams(
                    modelSize: Self.modelSize(selectedPlan.model),
                    contextTokens: selectedPlan.contextTokens
                ),
                onEvent: { [weak self] event in
                    guard event.type == "progress" else { return }
                    Task {
                        await self?.applyProgress(
                            (event.percentage ?? 0) / 100
                        )
                    }
                }
            )
            guard plan == selectedPlan else {
                throw BuiltInLLMEngine.EngineError.modelChanged
            }
            ready = true
            emit(.ready)
        } catch {
            if !(error is CancellationError) {
                emit(.failed(error.localizedDescription))
            }
            throw error
        }
    }

    func cancelPreparation() {
        emit(ready ? .ready : .notDownloaded)
    }

    func unload() async {
        if ready {
            _ = try? await runtime.request("unloadLLM")
        }
        ready = false
        emit(.notDownloaded)
    }

    func complete(
        systemPrompt: String,
        messages: [ChatMessage],
        maxTokens: Int? = nil
    ) async throws -> String {
        let stream = try await stream(
            systemPrompt: systemPrompt,
            messages: messages,
            maxTokens: maxTokens
        )
        var response = ""
        for try await token in stream { response += token }
        let cleaned = BuiltInLLMEngine.clean(response)
        guard !cleaned.isEmpty else {
            throw BuiltInLLMEngine.EngineError.emptyResponse
        }
        return cleaned
    }

    func stream(
        systemPrompt: String,
        messages: [ChatMessage],
        maxTokens: Int? = nil
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard messages.last?.role == .user else {
            throw BuiltInLLMEngine.EngineError.emptyConversation
        }
        try await prepare()
        let runtime = runtime
        let params = QVACBridgeParams(
            systemPrompt: systemPrompt + "\nDo not reveal private reasoning.",
            messages: messages.map {
                QVACBridgeMessage(role: $0.role.rawValue, content: $0.content)
            },
            maxTokens: maxTokens ?? min(
                2_048,
                max(900, plan.contextTokens / 64)
            )
        )

        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                do {
                    let result = try await runtime.request(
                        "complete",
                        params: params,
                        onEvent: { event in
                            if event.type == "token", let text = event.text {
                                continuation.yield(text)
                            }
                        }
                    )
                    if let finalText = result.text, finalText.isEmpty == false {
                        // Tokens are the canonical streaming surface. The final
                        // text is only a fallback for engines that emit none.
                    }
                    await self?.emit(.ready)
                    continuation.finish()
                } catch {
                    if !(error is CancellationError) {
                        await self?.emit(.failed(error.localizedDescription))
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func applyProgress(_ progress: Double) {
        emit(progress >= 1 ? .loading : .downloading(progress))
    }

    private func emit(_ newState: BuiltInAIState) {
        state = newState
        stateHandler?(newState)
    }

    private static func modelSize(_ model: BuiltInModel) -> String {
        if model.name.contains("35B") { return "35B" }
        if model.name.contains("27B") { return "27B" }
        if model.name.contains("9B") { return "9B" }
        if model.name.contains("4B") { return "4B" }
        return "2B"
    }
}
