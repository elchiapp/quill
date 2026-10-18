import AVFoundation
import Darwin
import DropsiftShared
import Foundation
import MLX
import Testing
@testable import dropsift

private struct BenchmarkPrompt: Codable {
    let name: String
    let systemPrompt: String
    let question: String
    let maxTokens: Int
}

private func benchmarkSeconds(_ start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now).components
    return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
}

private func processPeakRSS() -> Int64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int64(usage.ru_maxrss)
}

@Test(
    "Measure a native ASR or MLX lane with isolated output",
    .enabled(if: ProcessInfo.processInfo.environment["DROPSIFT_NATIVE_BENCHMARK"] != nil,
             "Set DROPSIFT_NATIVE_BENCHMARK to asr or llm to run the local benchmark.")
)
func measureNativeBackendPerformance() async throws {
    let environment = ProcessInfo.processInfo.environment
    let lane = try #require(environment["DROPSIFT_NATIVE_BENCHMARK"])
    let outputPath = try #require(environment["DROPSIFT_BENCHMARK_OUTPUT"])
    let output = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    let repeats = Int(environment["DROPSIFT_BENCHMARK_REPEATS"] ?? "3") ?? 3
    var rows: [[String: Any]] = []
    var report: [String: Any] = [
        "lane": lane, "hardware": DeviceProfile.current.summary,
        "startedAt": ISO8601DateFormatter().string(from: Date()),
        "sourceRevision": environment["DROPSIFT_BENCHMARK_SHA"] ?? "working-tree",
    ]
    func save() throws {
        report["runs"] = rows
        report["peakProcessRSSBytes"] = processPeakRSS()
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output, options: .atomic)
    }

    if lane == "asr" {
        let root = URL(fileURLWithPath: try #require(environment["DROPSIFT_BENCHMARK_AUDIO"]), isDirectory: true)
        let tracks = [root.appendingPathComponent("system.wav"), root.appendingPathComponent("mic.wav")]
        let engine = ParakeetEngine()
        let prepare = ContinuousClock.now
        try await engine.prepare()
        report["prepareSeconds"] = benchmarkSeconds(prepare)
        report["model"] = engine.model
        for run in 1...repeats {
            let started = ContinuousClock.now
            var segments: [TranscriptSegment] = []
            for track in tracks { segments += try await engine.transcribe(track) }
            let seconds = benchmarkSeconds(started)
            let text = segments.map(\.text).joined(separator: " ")
            #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            rows.append([
                "run": run, "seconds": seconds, "segmentCount": segments.count,
                "wordCount": text.split(whereSeparator: \.isWhitespace).count,
                "characterCount": text.count,
            ])
            let transcript = output.deletingLastPathComponent().appendingPathComponent("private-transcript-\(run).txt")
            try Data(text.utf8).write(to: transcript, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transcript.path)
            print("NATIVE_ASR run=\(run) seconds=\(seconds) words=\(text.split(whereSeparator: \.isWhitespace).count)")
            try save()
        }
        let reference = root.appendingPathComponent("reference.wav")
        if FileManager.default.fileExists(atPath: reference.path) {
            let result = try await engine.transcribe(reference)
            let text = result.map(\.text).joined(separator: " ")
            try Data(text.utf8).write(to: output.deletingLastPathComponent().appendingPathComponent("reference.txt"))
        }
        await engine.release()
    } else if lane == "llm" {
        let model = AIModelCatalog.model(id: "mlx-community/Qwen3.5-4B-4bit")
        let plan = BuiltInModelPlan(model: model, contextTokens: 32_768,
                                    memoryBudgetBytes: DeviceProfile.current.modelMemoryBudgetBytes)
        let engine = BuiltInLLMEngine(cacheRoot: Config.modelCacheRoot, plan: plan)
        let fixture = URL(fileURLWithPath: try #require(environment["DROPSIFT_BENCHMARK_RECORDING"]), isDirectory: true)
        let recording = try #require(RecordingItem.load(from: fixture))
        let text = (recording.transcript?.segments ?? []).map {
            recording.speakerName(for: $0.speaker) + ": " + recording.corrected($0.text)
        }.joined(separator: "\n")
        #expect(!text.isEmpty)
        let prompts = [
            BenchmarkPrompt(name: "answer", systemPrompt: "Use only this source and cite [1]: Alice will send the budget on Friday. Marco will run the offline test on Monday.", question: "Who will send the budget and when?", maxTokens: 256),
            BenchmarkPrompt(name: "title", systemPrompt: ContentPresentationGenerator.systemPrompt,
                question: ContentPresentationGenerator.userPrompt(kind: "meeting transcript", currentTitle: recording.title, text: text), maxTokens: 512),
            BenchmarkPrompt(name: "summary", systemPrompt: RecordingSummaryGenerator.systemPrompt,
                question: RecordingSummaryGenerator.userPrompt(text: text, detectedSpeakers: ["You", "Them"], characterLimit: 32_000), maxTokens: 1_536),
        ]
        let promptFile = output.deletingLastPathComponent().appendingPathComponent("workloads.json")
        try JSONEncoder().encode(prompts).write(to: promptFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: promptFile.path)
        report["model"] = model.id
        report["contextTokens"] = plan.contextTokens
        let prepare = ContinuousClock.now
        try await engine.prepare()
        report["prepareSeconds"] = benchmarkSeconds(prepare)
        for run in 1...repeats {
            for prompt in prompts {
                let start = ContinuousClock.now
                var firstToken: Double?
                var result = ""
                let stream = try await engine.stream(systemPrompt: prompt.systemPrompt,
                    messages: [ChatMessage(role: .user, content: prompt.question)], maxTokens: prompt.maxTokens)
                for try await chunk in stream {
                    if firstToken == nil { firstToken = benchmarkSeconds(start) }
                    result += chunk
                }
                let seconds = benchmarkSeconds(start)
                let cleaned = BuiltInLLMEngine.clean(result)
                let valid: Bool
                if prompt.name == "answer" { valid = cleaned.lowercased().contains("friday") }
                else if prompt.name == "title" {
                    valid = ContentPresentationGenerator.parse(cleaned, sourceRevision: "benchmark", model: model.name) != nil
                } else {
                    valid = RecordingSummaryGenerator.parse(cleaned, detectedSpeakers: ["You", "Them"], sourceRevision: "benchmark", model: model.name) != nil
                }
                rows.append([
                    "run": run, "task": prompt.name, "seconds": seconds,
                    "firstTokenMs": (firstToken ?? seconds) * 1000,
                    "characters": cleaned.count, "valid": valid,
                ])
                let resultFile = output.deletingLastPathComponent().appendingPathComponent("private-\(prompt.name)-\(run).txt")
                try Data(cleaned.utf8).write(to: resultFile, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resultFile.path)
                report["peakMLXMemoryBytes"] = MLX.Memory.peakMemory
                print("NATIVE_MLX task=\(prompt.name) run=\(run) seconds=\(seconds) firstTokenMs=\((firstToken ?? seconds) * 1000) valid=\(valid)")
                #expect(!cleaned.isEmpty)
                try save()
            }
        }
        await engine.unloadModel(model.id)
    } else { throw CocoaError(.validationMissingMandatoryProperty) }
    report["finishedAt"] = ISO8601DateFormatter().string(from: Date())
    try save()
}
