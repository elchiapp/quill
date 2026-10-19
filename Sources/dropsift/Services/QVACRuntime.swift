import Darwin
import Foundation

struct QVACBridgeMessage: Codable, Sendable {
    let role: String
    let content: String
}

struct QVACBridgeParams: Codable, Sendable {
    var modelSize: String?
    var modelID: String?
    var contextTokens: Int?
    var systemPrompt: String?
    var messages: [QVACBridgeMessage]?
    var maxTokens: Int?
    var audioPath: String?
    var audioDurationMs: Int?
    var imagePath: String?
    var speechModelPath: String?
    var speechRoute: String?
    var speechModel: String?
    var speechAcceleration: String?
    var responseFormat: String?

    init(
        modelSize: String? = nil,
        modelID: String? = nil,
        contextTokens: Int? = nil,
        systemPrompt: String? = nil,
        messages: [QVACBridgeMessage]? = nil,
        maxTokens: Int? = nil,
        audioPath: String? = nil,
        audioDurationMs: Int? = nil,
        imagePath: String? = nil,
        speechModelPath: String? = nil,
        responseFormat: String? = nil,
        speechRoute: String? = nil,
        speechModel: String? = nil,
        speechAcceleration: String? = nil
    ) {
        self.modelSize = modelSize
        self.modelID = modelID
        self.contextTokens = contextTokens
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.maxTokens = maxTokens
        self.audioPath = audioPath
        self.audioDurationMs = audioDurationMs
        self.imagePath = imagePath
        self.speechModelPath = speechModelPath
        self.responseFormat = responseFormat
        self.speechRoute = speechRoute
        self.speechModel = speechModel
        self.speechAcceleration = speechAcceleration
    }
}

struct QVACBridgeSegment: Codable, Sendable {
    let startMs: Int
    let endMs: Int
    let text: String
}

struct QVACBridgeTurn: Codable, Sendable {
    let speaker: String
    let startMs: Int
    let endMs: Int
    let confidence: Float
}

struct QVACBridgeBlock: Codable, Sendable {
    let text: String
    let confidence: Double?
}

struct QVACBridgeSpeechStats: Codable, Sendable {
    let encoderUsedCoreml: Int?
    let encoderOnCoreml: Int?
    let backendId: Int?
    let backendDevice: Int?
    let totalTime: Double?
    let totalWallMs: Double?
    let encoderTime: Double?
    let decoderTime: Double?
    let melSpecTime: Double?
    let encoderMs: Double?
    let decoderMs: Double?
    let modelLoadMs: Double?
    let totalSamples: Int?
    let totalTokens: Int?
}

struct QVACBridgeDiagnostics: Codable, Sendable {
    let selectedBackend: String?
    let selectedDevice: String?
    let speechRoute: String?
    let requestedAcceleration: String?
    let npuHardwareVerified: Bool?
    let bypassReason: String?
}

struct QVACBridgeResponse: Codable, Sendable {
    let id: String
    let type: String
    let text: String?
    let percentage: Double?
    let downloaded: Int64?
    let total: Int64?
    let detail: String?
    let model: String?
    let segments: [QVACBridgeSegment]?
    let turns: [QVACBridgeTurn]?
    let blocks: [QVACBridgeBlock]?
    let stats: QVACBridgeSpeechStats?
    let diagnostics: QVACBridgeDiagnostics?
    let error: String?
}

private struct QVACBridgeRequest: Codable, Sendable {
    let id: String
    let method: String
    let params: QVACBridgeParams
}

actor QVACRuntime {
    enum RuntimeError: LocalizedError {
        case bridgeUnavailable
        case bridgeExited(Int32)
        case invalidResponse
        case requestFailed(String)
        case requestTimedOut(String)

        var errorDescription: String? {
            switch self {
            case .bridgeUnavailable:
                "The packaged QVAC runtime is missing. Reinstall this build of DropSift."
            case .bridgeExited(let status):
                "The QVAC engine stopped unexpectedly (status "
                    + String(status) + ")."
            case .invalidResponse:
                "QVAC returned an unreadable response."
            case .requestFailed(let message):
                message
            case .requestTimedOut(let operation):
                "QVAC \(operation) stopped responding. DropSift will restart it and retry."
            }
        }
    }

    static let shared = QVACRuntime()

    typealias EventHandler = @Sendable (QVACBridgeResponse) -> Void

    private struct PendingRequest {
        let continuation: CheckedContinuation<QVACBridgeResponse, Error>
        let eventHandler: EventHandler?
    }

    private static let protocolPrefix = "__DROPSIFT_QVAC__"

    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var pending: [String: PendingRequest] = [:]
    private var operationIsActive = false
    private struct OperationWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var operationWaiters: [OperationWaiter] = []
    private var processGeneration = 0
    private let runtimeRoot: URL?
    private let cacheRoot: URL?
    private let executableOverride: URL?

    init(runtimeRoot: URL? = nil, cacheRoot: URL? = nil, executable: URL? = nil) {
        self.runtimeRoot = runtimeRoot
        self.cacheRoot = cacheRoot
        executableOverride = executable
    }

    func request(
        _ method: String,
        params: QVACBridgeParams = QVACBridgeParams(),
        onEvent: EventHandler? = nil
    ) async throws -> QVACBridgeResponse {
        try await acquireOperation()
        do {
            try Task.checkCancellation()
            let response = try await performRequest(
                method,
                params: params,
                onEvent: onEvent
            )
            releaseOperation()
            return response
        } catch {
            releaseOperation()
            throw error
        }
    }

    func request(
        _ method: String,
        params: QVACBridgeParams = QVACBridgeParams(),
        timeout: Duration,
        onEvent: EventHandler? = nil
    ) async throws -> QVACBridgeResponse {
        try await withThrowingTaskGroup(of: QVACBridgeResponse.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.request(
                    method,
                    params: params,
                    onEvent: onEvent
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RuntimeError.requestTimedOut(method)
            }
            defer { group.cancelAll() }
            guard let response = try await group.next() else {
                throw CancellationError()
            }
            return response
        }
    }

    func restart() async {
        await stopProcess()
    }

    func currentGeneration() -> Int {
        processGeneration
    }

    private func performRequest(
        _ method: String,
        params: QVACBridgeParams = QVACBridgeParams(),
        onEvent: EventHandler? = nil
    ) async throws -> QVACBridgeResponse {
        try startIfNeeded()
        let id = UUID().uuidString
        let request = QVACBridgeRequest(id: id, method: method, params: params)
        let data = try JSONEncoder().encode(request) + Data("\n".utf8)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = PendingRequest(
                    continuation: continuation,
                    eventHandler: onEvent
                )
                guard let writer = input else {
                    pending.removeValue(forKey: id)
                    continuation.resume(throwing: RuntimeError.bridgeUnavailable)
                    return
                }
                // A stalled child must not block this actor on a full stdin pipe.
                // Cancellation and timeout can still close the pipe and stop it.
                Task.detached(priority: .userInitiated) { [weak self] in
                    do { try writer.write(contentsOf: data) }
                    catch { await self?.failRequest(id, error: error) }
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
    }

    func shutdown(gracePeriod: Duration = .seconds(5)) async {
        if process?.isRunning == true {
            _ = try? await request("shutdown", timeout: gracePeriod)
        }
        await stopProcess()
    }

    private func acquireOperation() async throws {
        try Task.checkCancellation()
        guard operationIsActive else {
            operationIsActive = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operationWaiters.append(OperationWaiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelOperationWaiter(id) }
        }
    }

    private func cancelOperationWaiter(_ id: UUID) {
        guard let index = operationWaiters.firstIndex(where: { $0.id == id }) else { return }
        operationWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func releaseOperation() {
        guard !operationWaiters.isEmpty else {
            operationIsActive = false
            return
        }
        operationWaiters.removeFirst().continuation.resume()
    }

    private func startIfNeeded() throws {
        if process?.isRunning == true { return }
        let layout = try runtimeLayout()
        let configURL = try writeConfiguration()
        processGeneration += 1
        let generation = processGeneration

        let task = Process()
        task.executableURL = layout.executable
        task.arguments = [layout.bridge.path]
        task.currentDirectoryURL = layout.root
        var environment = ProcessInfo.processInfo.environment
        environment["QVAC_CONFIG_PATH"] = configURL.path
        // Keep SDK registry identity/locks separate from other QVAC applications.
        // Both SDK generations honor SNAP_USER_COMMON as their data-home override.
        environment["SNAP_USER_COMMON"] = configURL.deletingLastPathComponent()
            .appendingPathComponent("RuntimeHome", isDirectory: true).path
        if let isolatedHome = environment[
            "DROPSIFT_QVAC_HOME_OVERRIDE"
        ], !isolatedHome.isEmpty {
            environment["SNAP_USER_COMMON"] = isolatedHome
        }
        task.environment = environment

        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        task.standardInput = standardInput
        task.standardOutput = standardOutput
        task.standardError = standardError

        standardOutput.fileHandleForReading.readabilityHandler = {
            [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.consume(data, generation: generation) }
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            FileHandle.standardError.write(data)
        }
        task.terminationHandler = { [weak self] terminated in
            Task { await self?.processTerminated(terminated.terminationStatus, generation: generation) }
        }

        do {
            try task.run()
        } catch {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            throw RuntimeError.bridgeUnavailable
        }
        process = task
        input = standardInput.fileHandleForWriting
    }

    private func consume(_ data: Data, generation: Int) {
        guard generation == processGeneration else { return }
        // Pipe reads can end inside a multibyte character. Decode only complete
        // lines so accented/non-Latin transcripts cannot lose an entire response.
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0a) {
            let bytes = outputBuffer[..<newline]
            let line = String(data: bytes, encoding: .utf8)
            outputBuffer.removeSubrange(...newline)
            if let line { consume(line: line) }
        }
    }

    private func consume(line: String) {
        guard let marker = line.range(of: Self.protocolPrefix) else { return }
        let payload = String(line[marker.upperBound...])
        guard let data = payload.data(using: .utf8) else { return }
        let response: QVACBridgeResponse
        do { response = try JSONDecoder().decode(QVACBridgeResponse.self, from: data) }
        catch {
            // A valid JSON envelope with an invalid typed field belongs to a
            // known request. Fail it now instead of silently waiting 75 seconds.
            if let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = envelope["id"] as? String,
               let request = pending.removeValue(forKey: id) {
                request.continuation.resume(throwing: RuntimeError.invalidResponse)
            }
            return
        }
        guard let request = pending[response.id] else { return }

        switch response.type {
        case "progress", "token":
            request.eventHandler?(response)
        case "result":
            pending.removeValue(forKey: response.id)
            request.continuation.resume(returning: response)
        case "error":
            pending.removeValue(forKey: response.id)
            request.continuation.resume(
                throwing: RuntimeError.requestFailed(
                    response.error ?? "QVAC could not complete the request."
                )
            )
        default:
            break
        }
    }

    private func cancelRequest(_ id: String) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(throwing: CancellationError())
    }

    private func failRequest(_ id: String, error: Error) {
        pending.removeValue(forKey: id)?.continuation.resume(throwing: error)
    }

    private func failPending(_ error: Error) {
        let requests = Array(pending.values)
        pending.removeAll()
        for request in requests {
            request.continuation.resume(throwing: error)
        }
        let waiters = operationWaiters
        operationWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(throwing: error)
        }
    }

    private func processTerminated(_ status: Int32, generation: Int) {
        guard generation == processGeneration else { return }
        failPending(RuntimeError.bridgeExited(status))
        process = nil
        input = nil
        outputBuffer = Data()
    }

    private func stopProcess() async {
        guard let process else {
            input = nil
            outputBuffer = Data()
            return
        }
        self.process = nil
        try? input?.close()
        input = nil
        outputBuffer = Data()
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        failPending(CancellationError())
        if process.isRunning {
            process.terminate()
            for _ in 0..<20 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    private struct RuntimeLayout {
        let root: URL
        let executable: URL
        let bridge: URL
    }

    private func runtimeLayout() throws -> RuntimeLayout {
        let override = runtimeRoot ?? ProcessInfo.processInfo.environment[
            "DROPSIFT_QVAC_RUNTIME_ROOT"
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let candidates = override.map { [$0] } ?? [
            Bundle.main.resourceURL?.appendingPathComponent(
                "QVACRuntime",
                isDirectory: true
            ),
            Self.sourceProjectRoot.appendingPathComponent(
                "QVACBridge",
                isDirectory: true
            ),
        ].compactMap { $0 }

        for root in candidates {
            let executable = executableOverride ?? root.appendingPathComponent(
                "node_modules/bare-runtime-darwin-arm64/bin/bare"
            )
            let bridge = root.appendingPathComponent("bootstrap.cjs")
            if FileManager.default.isExecutableFile(atPath: executable.path),
               FileManager.default.fileExists(atPath: bridge.path) {
                return RuntimeLayout(
                    root: root,
                    executable: executable,
                    bridge: bridge
                )
            }
        }
        throw RuntimeError.bridgeUnavailable
    }

    private static var sourceProjectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func writeConfiguration() throws -> URL {
        let root = cacheRoot ?? ProcessInfo.processInfo.environment[
            "DROPSIFT_QVAC_CACHE_ROOT"
        ].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Config.qvacCacheRoot
        let modelRoot = root.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelRoot,
            withIntermediateDirectories: true
        )
        let configURL = root.appendingPathComponent("qvac.config.json")
        let object: [String: Any] = [
            "cacheDirectory": modelRoot.path,
            "loggerConsoleOutput": false,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: configURL, options: .atomic)
        return configURL
    }
}
