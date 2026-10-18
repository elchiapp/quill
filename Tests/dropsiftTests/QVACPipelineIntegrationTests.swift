import AppKit
import Foundation
import Testing
@testable import dropsift

@Test(
    "QVAC speech, failure recovery, diarization and OCR through the app bridge",
    .enabled(if: ProcessInfo.processInfo.environment["DROPSIFT_QVAC_PIPELINE_SMOKE"] != nil,
             "Set DROPSIFT_QVAC_PIPELINE_SMOKE to an isolated output directory.")
)
@MainActor
func qvacPipelineIntegrationSmoke() async throws {
    let environment = ProcessInfo.processInfo.environment
    let root = URL(fileURLWithPath: try #require(environment["DROPSIFT_QVAC_PIPELINE_SMOKE"]), isDirectory: true)
    let runtimeRoot = URL(fileURLWithPath: try #require(environment["DROPSIFT_QVAC_RUNTIME_ROOT"]), isDirectory: true)
    let modelPath = try #require(environment["DROPSIFT_QVAC_SPEECH_MODEL"])
    let audio = try #require(environment["DROPSIFT_QVAC_SMOKE_AUDIO"])
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let runtime = QVACRuntime(runtimeRoot: runtimeRoot, cacheRoot: root.appendingPathComponent("cache"))
    var evidence: [String: Any] = [:]
    let started = Date()
    func checkpoint(_ phase: String) throws {
        evidence["phase"] = phase
        evidence["totalSeconds"] = Date().timeIntervalSince(started)
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("result.json"), options: .atomic)
        print("QVAC_PIPELINE_PHASE=" + phase)
    }
    do {
        do {
            _ = try await runtime.request("prepareTranscription", params: QVACBridgeParams(
                speechModelPath: root.appendingPathComponent("missing.gguf").path
            ), timeout: .seconds(15))
            Issue.record("Missing speech model unexpectedly loaded")
        } catch QVACRuntime.RuntimeError.requestFailed {
            evidence["missingModelFails"] = true
        }
        let ping = try await runtime.request("ping", timeout: .seconds(5))
        #expect(ping.text?.contains("0.21.1") == true)
        evidence["recoversAfterMissingModel"] = ping.text?.contains("0.21.1") == true
        try checkpoint("missing-model recovery")
        _ = try await runtime.request("prepareTranscription", params: QVACBridgeParams(
            speechModelPath: modelPath
        ), timeout: .seconds(60))
        let transcript = try await runtime.request("transcribe", params: QVACBridgeParams(
            audioPath: audio, audioDurationMs: 11_157
        ), timeout: .seconds(30))
        let segments = transcript.segments ?? []
        #expect(transcript.stats?.encoderUsedCoreml == 0)
        #expect(transcript.diagnostics?.selectedBackend == "metal")
        evidence["speechUsesMetal"] = transcript.stats?.encoderUsedCoreml == 0
            && transcript.diagnostics?.selectedBackend == "metal"
        #expect(!segments.isEmpty)
        #expect(segments.allSatisfy { $0.startMs >= 0 && $0.endMs >= $0.startMs })
        let text = segments.map(\.text).joined(separator: " ")
        #expect(text.localizedCaseInsensitiveContains("Friday"))
        #expect(text.localizedCaseInsensitiveContains("budget"))
        evidence["speechHasValidTimedText"] = !segments.isEmpty
            && text.localizedCaseInsensitiveContains("Friday")
            && segments.allSatisfy { $0.startMs >= 0 && $0.endMs >= $0.startMs }
        try checkpoint("timed speech transcription")
        _ = try await runtime.request("unloadTranscription", timeout: .seconds(10))

        _ = try await runtime.request("prepareDiarization", timeout: .seconds(180))
        let turns = try await runtime.request("diarize", params: QVACBridgeParams(
            audioPath: audio, audioDurationMs: 11_157
        ), timeout: .seconds(60)).turns ?? []
        #expect(!turns.isEmpty)
        #expect(turns.allSatisfy { $0.startMs >= 0 && $0.endMs > $0.startMs })
        evidence["diarizationTurnCount"] = turns.count
        evidence["diarizationHasValidTurns"] = !turns.isEmpty
            && turns.allSatisfy { $0.startMs >= 0 && $0.endMs > $0.startMs }
        try checkpoint("speaker diarization")
        _ = try await runtime.request("unloadDiarization", timeout: .seconds(10))

        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 260,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1200, height: 260).fill()
        ("Nebula launch Friday\nBudget 1234\nOwner Alice" as NSString).draw(
            in: NSRect(x: 30, y: 25, width: 1140, height: 210),
            withAttributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black]
        )
        NSGraphicsContext.restoreGraphicsState()
        let image = root.appendingPathComponent("ocr-fixture.png")
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: image)
        let extractor = QVACImageExtractor(runtime: runtime)
        let blocks = try await extractor.extract(from: image)
        let recognized = blocks.map(\.text).joined(separator: " ")
        #expect(recognized.localizedCaseInsensitiveContains("Nebula"))
        #expect(recognized.localizedCaseInsensitiveContains("Friday"))
        #expect(recognized.contains("1234"))
        evidence["ocrBlocks"] = blocks.count
        evidence["ocrText"] = recognized
        evidence["ocrRecognizesFixture"] = recognized.localizedCaseInsensitiveContains("Nebula")
            && recognized.localizedCaseInsensitiveContains("Friday") && recognized.contains("1234")
        try checkpoint("OCR")
        await extractor.unload()

        let model = AIModelCatalog.model(id: "mlx-community/Qwen3.5-4B-4bit")
        let modelCache = root.appendingPathComponent("cache/Models", isDirectory: true)
        let sourceModels = URL(fileURLWithPath: modelPath).deletingLastPathComponent()
        for file in try FileManager.default.contentsOfDirectory(at: sourceModels, includingPropertiesForKeys: nil)
            where file.pathExtension == "gguf" {
            let target = modelCache.appendingPathComponent(file.lastPathComponent)
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.linkItem(at: file, to: target)
            }
        }
        let plan = BuiltInModelPlan(model: model, contextTokens: 32_768,
            memoryBudgetBytes: DeviceProfile.current.modelMemoryBudgetBytes)
        let llm = QVACLLMEngine(runtime: runtime, plan: plan)
        let response = try await llm.complete(
            systemPrompt: "Return only JSON with title and description string fields. Describe the provided meeting.",
            messages: [ChatMessage(role: .user, content: "Alice and Marco agreed to launch Project Nebula on Friday after testing offline recording.")],
            maxTokens: 256, responseFormat: .presentation
        )
        let object = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: String]
        #expect(object?["title"]?.isEmpty == false)
        #expect(object?["description"]?.isEmpty == false)
        evidence["appLLMStructuredOutput"] = object?["title"]?.isEmpty == false
            && object?["description"]?.isEmpty == false
        try checkpoint("app LLM structured output")
        await llm.unload()
        let shutdown = Date()
        await runtime.shutdown(gracePeriod: .seconds(2))
        evidence["shutdownSeconds"] = Date().timeIntervalSince(shutdown)
        evidence["totalSeconds"] = Date().timeIntervalSince(started)
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("result.json"), options: .atomic)
        print("QVAC_PIPELINE_SMOKE=" + root.path)
    } catch {
        evidence["error"] = error.localizedDescription
        evidence["totalSeconds"] = Date().timeIntervalSince(started)
        try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("result.json"), options: .atomic)
        await runtime.shutdown(gracePeriod: .seconds(1))
        throw error
    }
}
