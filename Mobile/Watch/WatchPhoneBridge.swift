import DropsiftShared
import Foundation
import WatchConnectivity

@MainActor
final class WatchPhoneBridge: NSObject, ObservableObject {
    @Published private(set) var status = "Connecting to iPhone…"
    @Published private(set) var pendingCount = 0
    @Published private(set) var snapshot = WatchCompanionSnapshot.empty
    @Published private(set) var isRefreshing = false
    @Published private(set) var isAsking = false
    @Published private(set) var answer: WatchCompanionAnswer?
    @Published private(set) var companionError: String?

    private static let cachedSnapshotKey = "Dropsift.watch.cachedSnapshot"

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: Self.cachedSnapshotKey),
           let cached = try? JSONDecoder().decode(
               WatchCompanionSnapshot.self,
               from: data
           ) {
            snapshot = cached
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        } else {
            status = "iPhone transfer unavailable"
        }
        refreshPendingCount()
    }

    var isPhoneReachable: Bool {
        WCSession.isSupported() && WCSession.default.isReachable
    }

    func refreshLibrary() {
        guard WCSession.default.activationState == .activated else {
            companionError = "Open DropSift on iPhone to sync."
            return
        }
        guard WCSession.default.isReachable else {
            companionError = snapshot == .empty
                ? "Open DropSift on the paired iPhone first."
                : "Showing the last sync. Open DropSift on iPhone to refresh."
            return
        }
        isRefreshing = true
        companionError = nil
        WCSession.default.sendMessage(
            ["action": "snapshot"],
            replyHandler: { [weak self] reply in
                Task { @MainActor in
                    self?.isRefreshing = false
                    self?.handleSnapshotReply(reply)
                }
            },
            errorHandler: { [weak self] error in
                Task { @MainActor in
                    self?.isRefreshing = false
                    self?.companionError = error.localizedDescription
                }
            }
        )
    }

    func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAsking else { return }
        guard WCSession.default.activationState == .activated,
              WCSession.default.isReachable
        else {
            companionError = "Open DropSift on iPhone to ask your library."
            return
        }
        isAsking = true
        answer = nil
        companionError = nil
        WCSession.default.sendMessage(
            ["action": "ask", "question": question],
            replyHandler: { [weak self] reply in
                Task { @MainActor in
                    guard let self else { return }
                    self.isAsking = false
                    if let data = reply["answer"] as? Data,
                       let value = try? JSONDecoder().decode(
                           WatchCompanionAnswer.self,
                           from: data
                       ) {
                        self.answer = value
                    } else {
                        self.companionError = reply["error"] as? String
                            ?? "The iPhone couldn’t answer."
                    }
                }
            },
            errorHandler: { [weak self] error in
                Task { @MainActor in
                    self?.isAsking = false
                    self?.companionError = error.localizedDescription
                }
            }
        )
    }

    func toggleTask(_ task: WatchCompanionTask) {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isReachable
        else {
            companionError = "Open DropSift on iPhone to update tasks."
            return
        }
        WCSession.default.sendMessage(
            ["action": "toggleTask", "taskID": task.id.uuidString],
            replyHandler: { [weak self] reply in
                Task { @MainActor in
                    self?.handleSnapshotReply(reply)
                }
            },
            errorHandler: { [weak self] error in
                Task { @MainActor in
                    self?.companionError = error.localizedDescription
                }
            }
        )
    }

    func queue(_ capture: WatchVoiceCapture) {
        let sidecar = capture.url
            .deletingPathExtension()
            .appendingPathExtension("json")
        let title = "Watch voice · \(capture.startedAt.formatted(date: .abbreviated, time: .shortened))"
        let metadata = [
            "started": ISO8601DateFormatter().string(from: capture.startedAt),
            "duration_seconds": String(capture.durationSeconds),
            "title": title,
            "origin": "apple-watch",
        ]
        do {
            try JSONEncoder().encode(metadata).write(to: sidecar, options: .atomic)
            sendPending()
        } catch {
            status = "Couldn’t queue recording"
        }
        refreshPendingCount()
    }

    private func sendPending() {
        let session = WCSession.default
        guard session.activationState == .activated else {
            status = "Queued until iPhone connects"
            return
        }
        let outgoing = outgoingFiles()
        let activePaths = Set(
            session.outstandingFileTransfers.map { $0.file.fileURL.path }
        )
        for url in outgoing where !activePaths.contains(url.path) {
            let sidecar = url.deletingPathExtension().appendingPathExtension("json")
            let metadata = (try? Data(contentsOf: sidecar))
                .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
                ?? [:]
            session.transferFile(url, metadata: metadata)
        }
        status = outgoing.isEmpty ? "Ready" : "Sending to iPhone…"
    }

    private func outgoingFiles() -> [URL] {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("OutgoingVoice", isDirectory: true)
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              )
        else { return [] }
        return files.filter { $0.pathExtension.lowercased() != "json" }
    }

    private func refreshPendingCount() {
        pendingCount = outgoingFiles().count
    }

    private func handleSnapshotReply(_ reply: [String: Any]) {
        if let data = reply["snapshot"] as? Data {
            applySnapshot(data)
        } else if let error = reply["error"] as? String {
            companionError = error
        }
    }

    private func applySnapshot(_ data: Data) {
        guard let value = try? JSONDecoder().decode(
            WatchCompanionSnapshot.self,
            from: data
        ) else {
            companionError = "The iPhone sent an unreadable library update."
            return
        }
        snapshot = value
        companionError = nil
        UserDefaults.standard.set(data, forKey: Self.cachedSnapshotKey)
    }
}

extension WatchPhoneBridge: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let errorMessage = error?.localizedDescription
        Task { @MainActor [weak self] in
            if let errorMessage {
                self?.status = "iPhone unavailable: \(errorMessage)"
            } else {
                self?.sendPending()
                self?.refreshLibrary()
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        fileTransfer: WCSessionFileTransfer,
        didFinishWithError error: (any Error)?
    ) {
        let transferredPath = fileTransfer.file.fileURL.path
        let errorMessage = error?.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let errorMessage {
                status = "Will retry: \(errorMessage)"
            } else {
                let url = URL(fileURLWithPath: transferredPath)
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(
                    at: url.deletingPathExtension().appendingPathExtension("json")
                )
                refreshPendingCount()
                status = pendingCount == 0 ? "Saved to iPhone" : "Sending…"
                sendPending()
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let data = applicationContext["dropsiftSnapshot"] as? Data else {
            return
        }
        Task { @MainActor [weak self] in
            self?.applySnapshot(data)
        }
    }
}
