import Darwin
import Foundation

struct QVACBridgeMessage: Codable, Sendable {
    let role: String
    let content: String
}

struct QVACBridgeParams: Codable, Sendable {
    var modelSize: String?
    var contextTokens: Int?
    var systemPrompt: String?
    var messages: [QVACBridgeMessage]?
    var maxTokens: Int?
    var audioPath: String?
    var audioDurationMs: Int?
    var imagePath: String?

    init(
        modelSize: String? = nil,
        contextTokens: Int? = nil,
        systemPrompt: String? = nil,
        messages: [QVACBridgeMessage]? = nil,
        maxTokens: Int? = nil,
        audioPath: String? = nil,
        audioDurationMs: Int? = nil,
        imagePath: String? = nil
    ) {
        self.modelSize = modelSize
        self.contextTokens = contextTokens
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.maxTokens = maxTokens
        self.audioPath = audioPath
        self.audioDurationMs = audioDurationMs
        self.imagePath = imagePath
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

struct QVACBridgeResponse: Codable, Sendable {
    let id: String
    let type: String
    let text: String?
    let percentage: Double?
    let detail: String?
    let model: String?
    let segments: [QVACBridgeSegment]?
    let turns: [QVACBridgeTurn]?
    let blocks: [QVACBridgeBlock]?
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
    private var outputBuffer = ""
    private var pending: [String: PendingRequest] = [:]
    private var operationIsActive = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var processGeneration = 0

    func request(
        _ method: String,
        params: QVACBridgeParams = QVACBridgeParams(),
        onEvent: EventHandler? = nil
    ) async throws -> QVACBridgeResponse {
        await acquireOperation()
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
                do {
                    try input?.write(contentsOf: data)
                } catch {
                    pending.removeValue(forKey: id)
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
    }

    func shutdown() async {
        if process?.isRunning == true {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    guard let self else { return }
                    _ = try? await self.performRequest("shutdown")
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(5))
                }
                _ = await group.next()
                group.cancelAll()
            }
        }
        await stopProcess()
    }

    private func acquireOperation() async {
        guard operationIsActive else {
            operationIsActive = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperation() {
        guard !operationWaiters.isEmpty else {
            operationIsActive = false
            return
        }
        operationWaiters.removeFirst().resume()
    }

    private func startIfNeeded() throws {
        if process?.isRunning == true { return }
        let layout = try Self.runtimeLayout()
        let configURL = try Self.writeConfiguration()

        let task = Process()
        task.executableURL = layout.executable
        task.arguments = [layout.bridge.path]
        task.currentDirectoryURL = layout.root
        var environment = ProcessInfo.processInfo.environment
        environment["QVAC_CONFIG_PATH"] = configURL.path
        if let isolatedHome = environment[
            "DROPSIFT_QVAC_HOME_OVERRIDE"
        ], !isolatedHome.isEmpty {
            environment["HOME"] = isolatedHome
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
            Task { await self?.consume(data) }
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            FileHandle.standardError.write(data)
        }
        task.terminationHandler = { [weak self] terminated in
            Task { await self?.processTerminated(terminated.terminationStatus) }
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
        processGeneration += 1
    }

    private func consume(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        outputBuffer += chunk
        while let newline = outputBuffer.firstIndex(of: "\n") {
            let line = String(outputBuffer[..<newline])
            outputBuffer.removeSubrange(...newline)
            consume(line: line)
        }
    }

    private func consume(line: String) {
        guard let marker = line.range(of: Self.protocolPrefix) else { return }
        let payload = String(line[marker.upperBound...])
        guard let data = payload.data(using: .utf8),
              let response = try? JSONDecoder().decode(
                  QVACBridgeResponse.self,
                  from: data
              )
        else { return }
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

    private func processTerminated(_ status: Int32) {
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.continuation.resume(
                throwing: RuntimeError.bridgeExited(status)
            )
        }
        process = nil
        input = nil
        outputBuffer = ""
    }

    private func stopProcess() async {
        guard let process else {
            input = nil
            outputBuffer = ""
            return
        }
        if process.isRunning {
            process.terminate()
            for _ in 0..<20 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        self.process = nil
        input = nil
        outputBuffer = ""
    }

    private struct RuntimeLayout {
        let root: URL
        let executable: URL
        let bridge: URL
    }

    private static func runtimeLayout() throws -> RuntimeLayout {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(
                "QVACRuntime",
                isDirectory: true
            ),
            sourceProjectRoot.appendingPathComponent(
                "QVACBridge",
                isDirectory: true
            ),
        ].compactMap { $0 }

        for root in candidates {
            let executable = root.appendingPathComponent(
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

    private static func writeConfiguration() throws -> URL {
        let root = Config.qvacCacheRoot
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
