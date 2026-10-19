import Foundation
import Testing
@testable import dropsift

private struct SpeechIntegrationManifest: Decodable {
    struct Sample: Decodable { let id: String; let wav: String; let durationSeconds: Double }
    let samples: [Sample]
}

@Test("Speech settings and AVFoundation conversion through the real app engine", .enabled(
    if: ProcessInfo.processInfo.environment["DROPSIFT_SPEECH_E2E_MANIFEST"] != nil,
    "Opt in with isolated public fixtures and explicit model paths."
))
func qvacSpeechMatrixEndToEnd() async throws {
    let env = ProcessInfo.processInfo.environment
    let manifest = try JSONDecoder().decode(SpeechIntegrationManifest.self, from: Data(contentsOf:
        URL(fileURLWithPath: try #require(env["DROPSIFT_SPEECH_E2E_MANIFEST"]))))
    let root = URL(fileURLWithPath: try #require(env["DROPSIFT_SPEECH_E2E_OUTPUT"]))
    let runtime = QVACRuntime(runtimeRoot: URL(fileURLWithPath: try #require(env["DROPSIFT_QVAC_RUNTIME_ROOT"])),
        cacheRoot: root.appendingPathComponent("cache"))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var rows: [[String: Any]] = []
    for route in QVACSpeechSettings.Route.allCases {
        for model in QVACSpeechSettings.Model.allCases {
            let settings = QVACSpeechSettings(route: route, model: model, acceleration: .metal)
            let path = try #require(env[model == .parakeet ? "DROPSIFT_QVAC_SPEECH_MODEL" : "DROPSIFT_QVAC_PSY_MODEL"])
            let metrics = SpeechPerformanceLog(directory: root.appendingPathComponent("metrics/\(route.rawValue)-\(model.rawValue)"))
            let engine = QVACTranscriptionEngine(runtime: runtime, settings: settings, explicitModelPath: path,
                onPerformance: { await metrics.append($0) })
            do {
                try await engine.prepare()
                for sample in manifest.samples {
                    let start = ProcessInfo.processInfo.systemUptime
                    do {
                        let segments = try await engine.transcribe(URL(fileURLWithPath: sample.wav))
                        let valid = segments.allSatisfy { $0.start >= 0 && $0.end >= $0.start && $0.end <= sample.durationSeconds + 0.1 }
                        #expect(valid)
                        rows.append(["route": route.rawValue, "model": model.rawValue, "sampleID": sample.id,
                            "seconds": ProcessInfo.processInfo.systemUptime - start, "durationSeconds": sample.durationSeconds,
                            "text": segments.map(\.text).joined(separator: " "), "validTimestamps": valid])
                    } catch {
                        rows.append(["route": route.rawValue, "model": model.rawValue, "sampleID": sample.id,
                            "seconds": ProcessInfo.processInfo.systemUptime - start, "error": String(describing: error)])
                        Issue.record("App speech route failed: \(route.rawValue)/\(model.rawValue)/\(sample.id): \(error)")
                    }
                    try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                        .write(to: root.appendingPathComponent("result.json"), options: .atomic)
                }
            } catch { Issue.record("Speech model preparation failed: \(error)") }
            await engine.release()
        }
    }
    await runtime.shutdown()
}
