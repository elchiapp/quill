import Foundation
import Testing
@testable import dropsift

private struct ASRAccuracyManifest: Decodable {
    struct Sample: Decodable {
        let id: String
        let wav: String
        let condition: String
        let durationSeconds: Double
    }
    let samples: [Sample]
}

@Test("Native ASR on reference-backed accuracy samples", .enabled(
    if: ProcessInfo.processInfo.environment["DROPSIFT_ASR_ACCURACY_MANIFEST"] != nil,
    "Set DROPSIFT_ASR_ACCURACY_MANIFEST and DROPSIFT_ASR_ACCURACY_OUTPUT to opt in."
))
func benchmarkNativeASRAccuracySamples() async throws {
    let environment = ProcessInfo.processInfo.environment
    let input = URL(fileURLWithPath: try #require(environment["DROPSIFT_ASR_ACCURACY_MANIFEST"]))
    let output = URL(fileURLWithPath: try #require(environment["DROPSIFT_ASR_ACCURACY_OUTPUT"]))
    let manifest = try JSONDecoder().decode(ASRAccuracyManifest.self, from: Data(contentsOf: input))
    #expect(!manifest.samples.isEmpty)
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    let repeats = Int(environment["DROPSIFT_BENCHMARK_REPEATS"] ?? "3") ?? 3
    let engine = ParakeetEngine()
    func seconds(_ start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
    var report: [String: Any] = ["label": "Native FluidAudio / Parakeet TDT Core ML",
        "startedAt": ISO8601DateFormatter().string(from: Date()),
        "model": engine.model, "hardware": DeviceProfile.current.summary,
        "sourceRevision": environment["DROPSIFT_BENCHMARK_SHA"] ?? "working-tree"]
    var rows: [[String: Any]] = []
    func save() throws {
        report["runs"] = rows
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output, options: .atomic)
    }
    do {
        let prepare = ContinuousClock.now
        try await engine.prepare()
        report["prepareSeconds"] = seconds(prepare)
        let warmup = ContinuousClock.now
        let first = try #require(manifest.samples.first { $0.condition == "clean" })
        _ = try await engine.transcribe(URL(fileURLWithPath: first.wav))
        report["warmupSeconds"] = seconds(warmup)
        for run in 1...repeats {
            let offset = (run - 1) * 17 % manifest.samples.count
            let samples = Array(manifest.samples[offset...]) + Array(manifest.samples[..<offset])
            for sample in samples {
                let start = ContinuousClock.now
                do {
                    let result = try await engine.transcribe(URL(fileURLWithPath: sample.wav))
                    let elapsed = seconds(start)
                    let text = result.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    rows.append(["sampleID": sample.id, "run": run, "seconds": elapsed,
                                 "durationSeconds": sample.durationSeconds, "text": text])
                    print("NATIVE_ACCURACY \(sample.id) run=\(run) seconds=\(elapsed)")
                } catch {
                    rows.append(["sampleID": sample.id, "run": run, "seconds": seconds(start),
                                 "durationSeconds": sample.durationSeconds, "error": error.localizedDescription])
                    Issue.record("Native ASR failed for \(sample.id): \(error)")
                }
                try save()
            }
        }
        report["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        await engine.release()
        try save()
    } catch {
        await engine.release()
        throw error
    }
}
