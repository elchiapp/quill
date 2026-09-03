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
