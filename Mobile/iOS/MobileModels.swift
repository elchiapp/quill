import DropsiftShared
import Foundation

enum MobileTab: Hashable {
    case capture
    case timeline
    case ask
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
