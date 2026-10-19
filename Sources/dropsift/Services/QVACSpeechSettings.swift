import Foundation

struct QVACSpeechSettings: Codable, Equatable, Sendable {
    enum Route: String, Codable, CaseIterable, Identifiable, Sendable {
        case sdk
        case fabricDirect
        var id: String { rawValue }
        var title: String { self == .sdk ? "QVAC SDK" : "Fabric Speech direct" }
    }
    enum Model: String, Codable, CaseIterable, Identifiable, Sendable {
        case parakeet
        case transcribepsy
        var id: String { rawValue }
        var title: String { self == .parakeet ? "Parakeet TDT v3 · 25 languages" : "TranscribePsy 250M · 8 languages" }
        var modelID: String { self == .parakeet ? "parakeet-tdt-0.6b-v3-q8_0" : "transcribepsy-250m-eu-sub-q8_0" }
    }
    enum Acceleration: String, Codable, CaseIterable, Identifiable, Sendable {
        case metal
        case cpu
        case coreml
        var id: String { rawValue }
        var title: String {
            switch self {
            case .metal: "GPU · Metal"
            case .cpu: "CPU only"
            case .coreml: "Core ML · ANE eligible"
            }
        }
    }
    static let defaultsKey = "dropsift.qvac.speech.settings"
    var route: Route = .sdk
    var model: Model = .parakeet
    var acceleration: Acceleration = .metal

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value.validated
    }
    var validated: Self {
        var value = self
        if model == .transcribepsy && acceleration == .coreml { value.acceleration = .metal }
        return value
    }
    var bridgeParams: QVACBridgeParams {
        QVACBridgeParams(speechRoute: route.rawValue, speechModel: model.rawValue,
                         speechAcceleration: acceleration.rawValue)
    }
    var performanceDirectory: URL { Config.qvacCacheRoot.appendingPathComponent("Performance", isDirectory: true) }
}
