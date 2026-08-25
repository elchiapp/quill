import DropsiftShared
import Foundation

enum MobileTab: Hashable {
    case capture
    case timeline
    case organize
    case ask
}

enum MobileAnswerModel: String, CaseIterable, Identifiable {
    case automatic
    case appleIntelligence
    case localSearch

    var id: String { rawValue }

    var name: String {
        switch self {
        case .automatic:
            "Automatic"
        case .appleIntelligence:
            "Apple Intelligence"
        case .localSearch:
            "Local source search"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            "Use Apple’s on-device model when available, otherwise return ranked source excerpts."
        case .appleIntelligence:
            "Apple’s private on-device Foundation Model. Requires Apple Intelligence."
        case .localSearch:
            "Retrieval only—no generative model and no model download."
        }
    }
}

struct MobileChatMessage: Identifiable, Equatable {
    enum Role {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    let text: String
    let sources: [SharedSearchResult]
}

enum MobileImportState: Equatable {
    case idle
    case importing(String)
    case transcribing(String)

    var label: String? {
        switch self {
        case .idle: nil
        case .importing(let name): "Importing \(name)…"
        case .transcribing(let name): "Transcribing \(name)…"
        }
    }
}

enum MobileLibrarySyncState: Equatable {
    case disconnected
    case syncing(shared: Bool)
    case synced(itemCount: Int, at: Date)
    case local(itemCount: Int, at: Date)
    case failed(String)

    var isSyncing: Bool {
        if case .syncing = self { return true }
        return false
    }

    var systemImage: String {
        switch self {
        case .disconnected: "icloud.slash"
        case .syncing: "icloud.and.arrow.down"
        case .synced: "checkmark.icloud"
        case .local: "iphone"
        case .failed: "exclamationmark.icloud"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .disconnected:
            "Not connected to iCloud"
        case .syncing(let shared):
            shared ? "Syncing iCloud Drive" : "Loading local library"
        case .synced(let itemCount, let date):
            "iCloud synced, \(itemCount) items, \(date.formatted(date: .omitted, time: .shortened))"
        case .local(let itemCount, _):
            "Local library, \(itemCount) items"
        case .failed(let message):
            "Library sync failed: \(message)"
        }
    }
}
