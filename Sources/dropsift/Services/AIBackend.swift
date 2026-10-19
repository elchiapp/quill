import Foundation

enum LocalAIResponseFormat: String, Sendable {
    case presentation
    case summary
}

enum AIBackend: String, CaseIterable, Identifiable, Sendable {
    case native
    case qvac

    var id: String { rawValue }

    var name: String {
        switch self {
        case .native: "Apple native"
        case .qvac: "QVAC"
        }
    }

    var shortDetail: String {
        switch self {
        case .native:
            "MLX language model, FluidAudio transcription, and Apple Vision"
        case .qvac:
            "llama.cpp, selectable Fabric Speech transcription, Sortformer, and OCR through QVAC"
        }
    }
}
