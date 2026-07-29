import Foundation
import WatchConnectivity

@MainActor
final class WatchPhoneBridge: NSObject, ObservableObject {
    @Published private(set) var status = "Connecting to iPhone…"
    @Published private(set) var pendingCount = 0

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        } else {
            status = "iPhone transfer unavailable"
        }
        refreshPendingCount()
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
}
