import DropsiftShared
import Foundation
import WatchConnectivity

struct WatchInboxEntry: Sendable {
    let audioURL: URL
    let metadataURL: URL
    let metadata: [String: String]
}

private final class WatchReplyHandler: @unchecked Sendable {
    private let handler: ([String: Any]) -> Void

    init(_ handler: @escaping ([String: Any]) -> Void) {
        self.handler = handler
    }

    func callAsFunction(_ reply: [String: Any]) {
        handler(reply)
    }
}

@MainActor
final class PhoneWatchBridge: NSObject, ObservableObject {
    @Published private(set) var status = "Looking for Apple Watch…"
    @Published private(set) var pendingCount = 0

    var onInboxChanged: (() -> Void)?

    private var snapshotProvider: (() -> WatchCompanionSnapshot)?
    private var answerProvider: ((String) async -> WatchCompanionAnswer)?
    private var taskToggleHandler: ((UUID) -> WatchCompanionSnapshot)?

    private nonisolated let inboxRoot: URL

    override init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        inboxRoot = base.appendingPathComponent("WatchInbox", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(
            at: inboxRoot,
            withIntermediateDirectories: true
        )
        refreshPendingCount()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        } else {
            status = "Watch Connectivity unavailable"
        }
    }

    func configureCompanion(
        snapshot: @escaping () -> WatchCompanionSnapshot,
        answer: @escaping (String) async -> WatchCompanionAnswer,
        toggleTask: @escaping (UUID) -> WatchCompanionSnapshot
    ) {
        snapshotProvider = snapshot
        answerProvider = answer
        taskToggleHandler = toggleTask
        publishCurrentSnapshot()
    }

    func publishCurrentSnapshot() {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated,
              let snapshot = snapshotProvider?(),
              let data = try? JSONEncoder().encode(snapshot)
        else { return }
        do {
            try WCSession.default.updateApplicationContext([
                "dropsiftSnapshot": data,
            ])
        } catch {
            status = "Watch sync pending: \(error.localizedDescription)"
        }
    }

    func inboxEntries() -> [WatchInboxEntry] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: inboxRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files
            .filter { $0.pathExtension.lowercased() != "json" }
            .compactMap { audioURL in
                let metadataURL = audioURL
                    .deletingPathExtension()
                    .appendingPathExtension("json")
                let metadata: [String: String]
                if let data = try? Data(contentsOf: metadataURL),
                   let value = try? JSONDecoder().decode(
                       [String: String].self,
                       from: data
                   ) {
                    metadata = value
                } else {
                    metadata = [:]
                }
                return WatchInboxEntry(
                    audioURL: audioURL,
                    metadataURL: metadataURL,
                    metadata: metadata
                )
            }
    }

    func markProcessed(_ entry: WatchInboxEntry) {
        try? FileManager.default.removeItem(at: entry.audioURL)
        try? FileManager.default.removeItem(at: entry.metadataURL)
        refreshPendingCount()
    }

    private nonisolated func receive(_ file: WCSessionFile) {
        let ext = file.fileURL.pathExtension.isEmpty
            ? "m4a"
            : file.fileURL.pathExtension
        let base = UUID().uuidString
        let audioURL = inboxRoot
            .appendingPathComponent(base)
            .appendingPathExtension(ext)
        let metadataURL = inboxRoot
            .appendingPathComponent(base)
            .appendingPathExtension("json")
        do {
            try FileManager.default.moveItem(at: file.fileURL, to: audioURL)
            let metadata = (file.metadata ?? [:]).reduce(
                into: [String: String]()
            ) { partial, pair in
                partial[pair.key] = String(describing: pair.value)
            }
            try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
            Task { @MainActor [weak self] in
                self?.refreshPendingCount()
                self?.onInboxChanged?()
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.status = "Watch transfer failed: \(error.localizedDescription)"
            }
        }
    }

    private func refreshPendingCount() {
        pendingCount = inboxEntries().count
    }
}

extension PhoneWatchBridge: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let errorMessage = error?.localizedDescription
        let watchReady = session.isPaired && session.isWatchAppInstalled
        Task { @MainActor [weak self] in
            if let errorMessage {
                self?.status = "Watch unavailable: \(errorMessage)"
            } else if watchReady {
                self?.status = "Apple Watch connected"
                self?.publishCurrentSnapshot()
            } else {
                self?.status = "Install DropSift on your Apple Watch"
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        receive(file)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let action = message["action"] as? String
        let question = message["question"] as? String
        let taskID = (message["taskID"] as? String).flatMap(UUID.init(uuidString:))
        let reply = WatchReplyHandler(replyHandler)
        Task { @MainActor [weak self] in
            guard let self else {
                reply(["error": "DropSift is unavailable on iPhone."])
                return
            }
            switch action {
            case "snapshot":
                reply(encodedSnapshotReply())
            case "ask":
                guard let question,
                      !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let answerProvider
                else {
                    reply(["error": "Enter a question first."])
                    return
                }
                let answer = await answerProvider(question)
                if let data = try? JSONEncoder().encode(answer) {
                    reply(["answer": data])
                } else {
                    reply(["error": "Couldn’t prepare the answer."])
                }
            case "toggleTask":
                guard let taskID, let taskToggleHandler else {
                    reply(["error": "Couldn’t update that task."])
                    return
                }
                let snapshot = taskToggleHandler(taskID)
                publishCurrentSnapshot()
                if let data = try? JSONEncoder().encode(snapshot) {
                    reply(["snapshot": data])
                } else {
                    reply(["error": "Couldn’t refresh tasks."])
                }
            default:
                reply(["error": "Unknown Watch request."])
            }
        }
    }

    private func encodedSnapshotReply() -> [String: Any] {
        guard let snapshot = snapshotProvider?(),
              let data = try? JSONEncoder().encode(snapshot)
        else {
            return ["error": "The DropSift library isn’t ready yet."]
        }
        return ["snapshot": data]
    }
}
