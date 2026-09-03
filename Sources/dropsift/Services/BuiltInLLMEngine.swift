import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers
#if canImport(Darwin)
import Darwin
#endif

func localAIErrorDescription(_ error: Error) -> String {
    if let error = error as? HTTPClientError {
        return error.description
    }
    return error.localizedDescription
}

enum PublicModelHub {
    static func client(cache: HubCache) -> HubClient {
        // Every model in AIModelCatalog is public. Supplying the host
        // explicitly selects TokenProvider.none, so an unrelated stale token
        // from HF_TOKEN or the user's Hugging Face CLI cannot turn public
        // downloads into 401 failures.
        HubClient(
            host: HubClient.defaultHost,
            userAgent: "Dropsift/1.0 built-in-local-ai",
            bearerToken: nil,
            cache: cache
        )
    }
}

private final class DownloadProgressCollection: @unchecked Sendable {
    let files: [Progress]
    let aggregate: Progress

    init(fileSizes: [Int64]) {
        files = fileSizes.map { Progress(totalUnitCount: max($0, 1)) }
        aggregate = Progress(
            totalUnitCount: max(fileSizes.reduce(0, +), 1)
        )
    }

    func refresh() -> Progress {
        aggregate.completedUnitCount = files.reduce(Int64.zero) {
            $0 + min($1.completedUnitCount, $1.totalUnitCount)
        }
        return aggregate
    }

    func finish() -> Progress {
        aggregate.completedUnitCount = aggregate.totalUnitCount
        return aggregate
    }
}

private actor LocalGenerationGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private final class RedirectRejectingDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private final class ResumableModelDownload: NSObject, URLSessionDataDelegate,
    @unchecked Sendable
{
    typealias ProgressHandler = @Sendable (_ completed: Int64, _ total: Int64) -> Void

    private let destination: URL
    private let initialOffset: Int64
    private let progressHandler: ProgressHandler
    private let completionLock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var file: FileHandle?
    private var completedBytes: Int64
    private var expectedBytes: Int64
    private var responseError: Error?

    init(
        destination: URL,
        initialOffset: Int64,
        progressHandler: @escaping ProgressHandler
    ) {
        self.destination = destination
        self.initialOffset = initialOffset
        self.progressHandler = progressHandler
        completedBytes = initialOffset
        expectedBytes = max(initialOffset, 1)
    }

    func run(request: URLRequest) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: destination.path) {
            FileManager.default.createFile(
                atPath: destination.path,
                contents: nil
            )
        }
        file = try FileHandle(forWritingTo: destination)
        try file?.seekToEnd()

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let session = URLSession(
            configuration: .default,
            delegate: self,
            delegateQueue: queue
        )
        self.session = session

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completionLock.lock()
                self.continuation = continuation
                let task = session.dataTask(with: request)
                self.task = task
                completionLock.unlock()
                task.resume()
            }
        } onCancel: {
            self.task?.cancel()
        }
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode)
        else {
            responseError = URLError(.badServerResponse)
            completionHandler(.cancel)
            return
        }

        let isResume = http.statusCode == 206 && initialOffset > 0
        if !isResume, initialOffset > 0 {
            do {
                try file?.truncate(atOffset: 0)
                try file?.seek(toOffset: 0)
                completedBytes = 0
            } catch {
                responseError = error
                completionHandler(.cancel)
                return
            }
        }
        let responseBytes = max(response.expectedContentLength, 0)
        expectedBytes = max(completedBytes + responseBytes, 1)
        progressHandler(completedBytes, expectedBytes)
        completionHandler(.allow)
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive data: Data
    ) {
        do {
            try file?.write(contentsOf: data)
            completedBytes += Int64(data.count)
            progressHandler(completedBytes, expectedBytes)
        } catch {
            responseError = error
            task?.cancel()
        }
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        try? file?.close()
        file = nil
        session?.finishTasksAndInvalidate()
        session = nil

        let finalError = responseError ?? error
        finish(
            finalError.map(Result.failure) ?? .success(())
        )
    }

    private func finish(_ result: Result<Void, Error>) {
        completionLock.lock()
        let continuation = continuation
        self.continuation = nil
        completionLock.unlock()

        switch result {
        case .success:
            continuation?.resume()
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}

private struct DropsiftHubDownloader: Downloader {
    let client: HubClient
    let cache: HubCache
    let root: URL

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest _: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        if let snapshot = CachedModelSnapshot.resolve(
            modelID: id,
            revision: revision ?? "main",
            in: root
        ) {
            let progress = Progress(totalUnitCount: 1)
            progress.completedUnitCount = 1
            progressHandler(progress)
            return snapshot
        }
        guard let repo = Repo.ID(rawValue: id) else {
            throw BuiltInLLMEngine.EngineError.invalidRepositoryID(id)
        }
        let revision = revision ?? "main"
        let entries = try await client.listFiles(
            in: repo,
            revision: revision,
            recursive: true
        )
        .filter { entry in
            guard entry.type == .file else { return false }
            guard !patterns.isEmpty else { return true }
            #if canImport(Darwin)
            return patterns.contains { fnmatch($0, entry.path, 0) == 0 }
            #else
            return patterns.contains {
                entry.path.hasSuffix($0.replacingOccurrences(of: "*", with: ""))
            }
            #endif
        }

        let progress = DownloadProgressCollection(
            fileSizes: entries.map { Int64(max($0.size ?? 1, 1)) }
        )
        progressHandler(progress.refresh())
        let bearerToken = await client.bearerToken

        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            if cache.cachedFilePath(
                repo: repo,
                kind: .model,
                revision: revision,
                filename: entry.path
            ) != nil {
                progress.files[index].completedUnitCount =
                    progress.files[index].totalUnitCount
                progressHandler(progress.refresh())
                continue
            }

            let fileURL = client.host
                .appending(path: repo.namespace)
                .appending(path: repo.name)
                .appending(path: "resolve")
                .appending(component: revision)
                .appending(path: entry.path)
            let metadata = try await metadata(
                for: fileURL,
                bearerToken: bearerToken
            )
            let incomplete = try cache.incompleteBlobPath(
                repo: repo,
                kind: .model,
                etag: metadata.etag
            )
            let offset = Self.fileSize(at: incomplete)
            var request = URLRequest(url: fileURL)
            request.setValue(
                "Dropsift/1.0 built-in-local-ai",
                forHTTPHeaderField: "User-Agent"
            )
            if let bearerToken {
                request.setValue(
                    "Bearer \(bearerToken)",
                    forHTTPHeaderField: "Authorization"
                )
            }
            if offset > 0 {
                request.setValue(
                    "bytes=\(offset)-",
                    forHTTPHeaderField: "Range"
                )
            }

            let download = ResumableModelDownload(
                destination: incomplete,
                initialOffset: offset
            ) { completed, total in
                progress.files[index].totalUnitCount = max(total, 1)
                progress.files[index].completedUnitCount = completed
                progressHandler(progress.refresh())
            }
            try await download.run(request: request)
            try await cache.storeFile(
                at: incomplete,
                repo: repo,
                kind: .model,
                revision: metadata.commit,
                filename: entry.path,
                etag: metadata.etag,
                ref: revision
            )
            try? FileManager.default.removeItem(at: incomplete)
            progress.files[index].completedUnitCount =
                progress.files[index].totalUnitCount
            progressHandler(progress.refresh())
        }

        progressHandler(progress.finish())
        guard let commit = cache.resolveRevision(
            repo: repo,
            kind: .model,
            ref: revision
        ) else {
            throw BuiltInLLMEngine.EngineError.snapshotResolutionFailed(id)
        }
        return cache.snapshotsDirectory(repo: repo, kind: .model)
            .appendingPathComponent(commit, isDirectory: true)
    }

    private func metadata(
        for url: URL,
        bearerToken: String?
    ) async throws -> (commit: String, etag: String) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "Dropsift/1.0 built-in-local-ai",
            forHTTPHeaderField: "User-Agent"
        )
        if let bearerToken {
            request.setValue(
                "Bearer \(bearerToken)",
                forHTTPHeaderField: "Authorization"
            )
        }

        let delegate = RedirectRejectingDelegate()
        let (_, response) = try await URLSession.shared.data(
            for: request,
            delegate: delegate
        )
        guard let http = response as? HTTPURLResponse,
              (200 ..< 400).contains(http.statusCode),
              let commit = http.value(forHTTPHeaderField: "X-Repo-Commit"),
              let etag = http.value(forHTTPHeaderField: "X-Linked-ETag")
                ?? http.value(forHTTPHeaderField: "ETag")
        else {
            throw BuiltInLLMEngine.EngineError.modelMetadataUnavailable(
                url.lastPathComponent
            )
        }
        return (commit, etag)
    }

    private static func fileSize(at url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        else { return 0 }
        return Int64(values.fileSize ?? 0)
    }
}

enum CachedModelSnapshot {
    static func resolve(
        modelID: String,
        revision: String = "main",
        in root: URL
    ) -> URL? {
        guard let repo = Repo.ID(rawValue: modelID) else { return nil }
        let cache = HubCache(cacheDirectory: root)
        guard let commit = cache.resolveRevision(
            repo: repo,
            kind: .model,
            ref: revision
        ) else { return nil }
        let snapshot = cache.snapshotsDirectory(repo: repo, kind: .model)
            .appendingPathComponent(commit, isDirectory: true)
        return isComplete(snapshot) ? snapshot : nil
    }

    private static func isComplete(_ snapshot: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(
            atPath: snapshot.appendingPathComponent("config.json").path
        ) else { return false }

        let tokenizerFiles = [
            "tokenizer.json",
            "tokenizer.model",
            "tokenizer_config.json",
            "vocab.json",
        ]
        guard tokenizerFiles.contains(where: {
            fileManager.fileExists(
                atPath: snapshot.appendingPathComponent($0).path
            )
        }) else { return false }

        let indexURL = snapshot.appendingPathComponent(
            "model.safetensors.index.json"
        )
        if let data = try? Data(contentsOf: indexURL),
           let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
           let weightMap = object["weight_map"] as? [String: String] {
            let filenames = Set(weightMap.values)
            guard !filenames.isEmpty else { return false }
            return filenames.allSatisfy {
                validWeightFile(snapshot.appendingPathComponent($0))
            }
        }

        guard let entries = try? fileManager.contentsOfDirectory(
            at: snapshot,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        return entries.contains {
            $0.pathExtension == "safetensors" && validWeightFile($0)
        }
    }

    private static func validWeightFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        else { return false }
        return (values.fileSize ?? 0) > 0
    }
}

struct ModelDownloadProgress: Sendable, Equatable {
    let fraction: Double
    let completedBytes: Int64
    let totalBytes: Int64

    init(
        fraction: Double,
        completedBytes: Int64 = 0,
        totalBytes: Int64 = 0
    ) {
        self.fraction = max(0, min(1, fraction))
        self.completedBytes = max(0, completedBytes)
        self.totalBytes = max(0, totalBytes)
    }

    init(completedBytes: Int64, totalBytes: Int64) {
        let total = max(0, totalBytes)
        let completed = max(0, completedBytes)
        self.init(
            fraction: total > 0
                ? Double(min(completed, total)) / Double(total)
                : 0,
            completedBytes: completed,
            totalBytes: total
        )
    }
}

enum BuiltInAIState: Sendable, Equatable {
    case notDownloaded
    case downloaded
    case downloading(ModelDownloadProgress)
    case loading
    case ready
    case failed(String)
}

actor BuiltInLLMEngine {
    enum EngineError: LocalizedError {
        case emptyConversation
        case emptyResponse
        case invalidRepositoryID(String)
        case modelChanged
        case modelMetadataUnavailable(String)
        case requiresAppleSilicon
        case snapshotResolutionFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyConversation:
                "There is no question to answer."
            case .emptyResponse:
                "The built-in model returned an empty response."
            case .invalidRepositoryID(let id):
                "The local model repository ID is invalid: \(id)"
            case .modelChanged:
                "The selected local model changed while it was loading."
            case .modelMetadataUnavailable(let file):
                "Hugging Face did not return download metadata for \(file)."
            case .requiresAppleSilicon:
                "Built-in MLX inference requires a Mac with Apple silicon."
            case .snapshotResolutionFailed(let id):
                "The downloaded model snapshot could not be resolved: \(id)"
            }
        }
    }

    typealias StateHandler = @Sendable (String, BuiltInAIState) -> Void

    private let cacheRoot: URL
    private var plan: BuiltInModelPlan
    private var container: ModelContainer?
    private var loadedModelID: String?
    private var preparation: (
        id: UUID,
        modelID: String,
        task: Task<ModelContainer, Error>
    )?
    private var stateHandler: StateHandler?
    private let generationGate = LocalGenerationGate()

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

    func cancelPreparation() {
        preparation?.task.cancel()
        preparation = nil

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

    /// Stops network/model preparation without removing any cached or
    /// partially downloaded files. A later prepare() resumes from the blob's
    /// existing byte offset.
    func pausePreparation() {
        cancelPreparation()
    }

    func unloadModel(_ modelID: String) {
        if preparation?.modelID == modelID {
            preparation?.task.cancel()
            preparation = nil
        }
        if loadedModelID == modelID {
            container = nil
            loadedModelID = nil
            Memory.clearCache()
        }
        if plan.model.id == modelID {
            emit(.notDownloaded)
        }
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
        for try await chunk in stream {
            response += chunk
        }
        let cleaned = Self.clean(response)
        guard !cleaned.isEmpty else { throw EngineError.emptyResponse }
        return cleaned
    }

    func stream(
        systemPrompt: String,
        messages: [ChatMessage],
        maxTokens: Int? = nil
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard let prompt = messages.last, prompt.role == .user else {
            throw EngineError.emptyConversation
        }

        await generationGate.acquire()
        let model: ModelContainer
        do {
            model = try await modelContainer()
        } catch {
            await generationGate.release()
            throw error
        }
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
            maxTokens: maxTokens
                ?? min(2_048, max(900, plan.contextTokens / 64)),
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
            generateParameters: parameters,
            additionalContext: ["enable_thinking": false]
        )
        let upstream = session.streamResponse(to: prompt.content)
        let gate = generationGate
        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                do {
                    var cleaner = StreamingResponseCleaner()
                    for try await chunk in upstream {
                        let visible = cleaner.consume(chunk)
                        if !visible.isEmpty {
                            continuation.yield(visible)
                        }
                    }
                    let tail = cleaner.finish()
                    if !tail.isEmpty {
                        continuation.yield(tail)
                    }
                    if let self {
                        await self.generationFinished()
                    }
                    await gate.release()
                    continuation.finish()
                } catch {
                    if let self {
                        await self.generationFinished()
                    }
                    await gate.release()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
                modelID: preparation.modelID,
                preparationID: preparation.id
            )
        }

        let requestedPlan = plan
        let modelID = requestedPlan.model.id
        let preparationID = UUID()
        let cached = Self.hasCachedModel(requestedPlan.model, in: cacheRoot)
        emit(
            cached
                ? .loading
                : .downloading(
                    ModelDownloadProgress(
                        fraction: 0,
                        totalBytes: Int64(requestedPlan.model.downloadBytes)
                    )
                )
        )
        let root = cacheRoot
        let task = Task<ModelContainer, Error> {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let cache = HubCache(cacheDirectory: root)
            let client = PublicModelHub.client(cache: cache)
            let configuration = ModelConfiguration(
                id: modelID,
                extraEOSTokens: ["<|im_end|>"]
            )
            return try await LLMModelFactory.shared.loadContainer(
                from: DropsiftHubDownloader(
                    client: client,
                    cache: cache,
                    root: root
                ),
                using: #huggingFaceTokenizerLoader(),
                configuration: configuration,
                progressHandler: { progress in
                    let update = ModelDownloadProgress(
                        completedBytes: progress.completedUnitCount,
                        totalBytes: progress.totalUnitCount
                    )
                    Task {
                        await self.updateDownloadProgress(
                            update,
                            modelID: modelID
                        )
                    }
                }
            )
        }
        preparation = (preparationID, modelID, task)
        return try await finish(
            task,
            modelID: modelID,
            preparationID: preparationID
        )
        #endif
    }

    private func finish(
        _ task: Task<ModelContainer, Error>,
        modelID: String,
        preparationID: UUID
    ) async throws -> ModelContainer {
        do {
            let loaded = try await task.value
            guard plan.model.id == modelID,
                  preparation?.id == preparationID
            else {
                throw EngineError.modelChanged
            }
            container = loaded
            loadedModelID = modelID
            preparation = nil
            emit(.ready)
            return loaded
        } catch {
            let isCurrentPreparation = preparation?.id == preparationID
            if isCurrentPreparation {
                preparation = nil
            }
            if isCurrentPreparation, plan.model.id == modelID {
                container = nil
                loadedModelID = nil
                Memory.clearCache()
                emit(.failed(localAIErrorDescription(error)))
            }
            throw error
        }
    }

    private func updateDownloadProgress(
        _ progress: ModelDownloadProgress,
        modelID: String
    ) {
        guard plan.model.id == modelID else { return }
        emit(progress.fraction >= 1 ? .loading : .downloading(progress))
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
        stateHandler?(plan.model.id, state)
    }

    private func generationFinished() {
        emit(.ready)
    }

    static func hasCachedModel(_ model: BuiltInModel, in root: URL) -> Bool {
        let repository = modelCacheDirectory(for: model, in: root)
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

    static func hasPartialModel(_ model: BuiltInModel, in root: URL) -> Bool {
        guard !hasCachedModel(model, in: root) else { return false }
        let repository = modelCacheDirectory(for: model, in: root)
        guard let enumerator = FileManager.default.enumerator(
            at: repository,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            ) else { continue }
            if values.isRegularFile == true, (values.fileSize ?? 0) > 0 {
                return true
            }
        }
        return false
    }

    static func modelCacheDirectory(
        for model: BuiltInModel,
        in root: URL
    ) -> URL {
        root.appendingPathComponent(
            "models--" + model.id.replacingOccurrences(of: "/", with: "--"),
            isDirectory: true
        )
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

struct StreamingResponseCleaner: Sendable {
    private static let openingTag = "<think>"
    private static let closingTag = "</think>"

    private var buffer = ""
    private var isInsideThought = false

    mutating func consume(_ chunk: String) -> String {
        buffer += chunk
        var output = ""

        while !buffer.isEmpty {
            if isInsideThought {
                if let closing = buffer.range(of: Self.closingTag) {
                    buffer.removeSubrange(buffer.startIndex..<closing.upperBound)
                    isInsideThought = false
                    continue
                }
                buffer = trailingTagPrefix(in: buffer, tag: Self.closingTag)
                return output
            }

            if let opening = buffer.range(of: Self.openingTag) {
                output += buffer[..<opening.lowerBound]
                buffer.removeSubrange(buffer.startIndex..<opening.upperBound)
                isInsideThought = true
                continue
            }

            let heldSuffix = trailingTagPrefix(in: buffer, tag: Self.openingTag)
            let visibleCount = buffer.count - heldSuffix.count
            if visibleCount > 0 {
                let boundary = buffer.index(buffer.startIndex, offsetBy: visibleCount)
                output += buffer[..<boundary]
            }
            buffer = heldSuffix
            return output
        }
        return output
    }

    mutating func finish() -> String {
        guard !isInsideThought else {
            buffer = ""
            return ""
        }
        defer { buffer = "" }
        return buffer
    }

    private func trailingTagPrefix(in value: String, tag: String) -> String {
        let maximumLength = min(value.count, tag.count - 1)
        guard maximumLength > 0 else { return "" }
        for length in stride(from: maximumLength, through: 1, by: -1) {
            let suffix = value.suffix(length)
            if tag.hasPrefix(suffix) {
                return String(suffix)
            }
        }
        return ""
    }
}
