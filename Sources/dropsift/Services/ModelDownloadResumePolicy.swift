import Foundation

enum ModelDownloadResumePolicy {
    static func shouldPrepare(
        backend: AIBackend,
        resumedTranscription: Bool,
        isCached: Bool,
        pendingModelID: String?,
        selectedModelID: String,
        isPaused: Bool
    ) -> Bool {
        guard !isPaused else { return false }
        switch backend {
        case .native:
            return isCached || pendingModelID == selectedModelID
        case .qvac:
            return !resumedTranscription
        }
    }
}

enum ModelDownloadTelemetry {
    static func label(
        completedBytes: Int64,
        totalBytes: Int64,
        bytesPerSecond: Double?
    ) -> String {
        var parts: [String] = []
        if totalBytes > 0 {
            parts.append(
                size(completedBytes) + " of " + size(totalBytes)
            )
        } else if completedBytes > 0 {
            parts.append(size(completedBytes) + " downloaded")
        }
        if let bytesPerSecond, bytesPerSecond > 0 {
            parts.append(size(Int64(bytesPerSecond)) + "/s")
        }
        return parts.joined(separator: " · ")
    }

    static func size(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes))
        let kib = 1_024.0
        let mib = kib * 1_024
        let gib = mib * 1_024
        if value >= gib {
            return String(format: "%.1f GB", value / gib)
        }
        if value >= mib {
            return String(format: "%.1f MB", value / mib)
        }
        if value >= kib {
            return String(format: "%.1f KB", value / kib)
        }
        return "\(Int64(value)) B"
    }
}
