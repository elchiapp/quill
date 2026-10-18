import FluidAudio
import Foundation
import Hub
import Synchronization

enum PackageResourceCheck {
    enum Failure: Error { case notPackaged, missingResources, timedOut }

    /// A data-free CLI check for the packaged app. No microphone prompt,
    /// model download, user defaults, Keychain, or library migration occurs.
    static func run() throws {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let resources = Bundle.main.resourceURL else { throw Failure.notPackaged }
        for name in ["swift-transformers_Hub.bundle", "FluidAudio_FluidAudio.bundle"] {
            guard Bundle(url: resources.appendingPathComponent(name)) != nil else {
                throw Failure.missingResources
            }
        }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dropsift-resource-check-" + UUID().uuidString, isDirectory: true
        )
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Data(#"{"model_type":"gpt2"}"#.utf8).write(to: fixture.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: fixture.appendingPathComponent("tokenizer.json"))
        let result = Mutex<[String: Bool]>([:])
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            defer { finished.signal() }
            do {
                let configuration = LanguageModelConfigurationFromHub(modelFolder: fixture)
                let tokenizer = try await configuration.tokenizerConfig
                let g2p = try LuxTtsG2p()
                let values = [
                    "fallbackTokenizer": tokenizer?.tokenizerClass.string() == "GPT2Tokenizer",
                    "speechResourceTables": !g2p.phonemize(text: "Hello world").isEmpty,
                ]
                result.withLock { $0 = values }
            } catch {
                result.withLock { $0 = ["resourceLoad": false] }
            }
        }
        guard finished.wait(timeout: .now() + 30) == .success else { throw Failure.timedOut }
        let values = result.withLock { $0 }
        guard !values.isEmpty, values.values.allSatisfy({ $0 }) else { throw Failure.missingResources }
        let json = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }
}
