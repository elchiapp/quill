import Foundation

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
            "llama.cpp, Parakeet TDT on Metal, Sortformer, and OCR through QVAC"
        }
    }
}
