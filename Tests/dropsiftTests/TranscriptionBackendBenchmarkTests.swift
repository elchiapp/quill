import Foundation
import Testing
@testable import dropsift

private struct TranscriptionBenchmarkMetric: Codable {
    let backend: String
    let model: String
    let gpuRequested: Bool
    let prepareSeconds: Double
    let runSeconds: Double
    let segmentCount: Int
    let characterCount: Int
    let wordCount: Int
}

private struct TranscriptionBenchmarkReport: Codable {
    let sourceRevision: String
    let fixture: String
    let recordingDurationSeconds: Int
    let hardware: String
    let startedAt: String
    let metrics: [TranscriptionBenchmarkMetric]
    let qvacWarmPrepareSeconds: Double
}

private func elapsed(
    _ operation: () async throws -> Void
) async rethrows -> Double {
    let started = Date()
    try await operation()
    return Date().timeIntervalSince(started)
}

private func words(in segments: [TranscriptSegment]) -> Int {
    segments.reduce(0) { total, segment in
        total + segment.text.split(whereSeparator: \.isWhitespace).count
    }
}

@Test(
    "Compare native and QVAC Parakeet transcription",
    .enabled(
        if: ProcessInfo.processInfo.environment[
            "DROPSIFT_TRANSCRIPTION_BENCHMARK"
        ] == "1",
        "Set DROPSIFT_TRANSCRIPTION_BENCHMARK=1 to run the long benchmark."
    )
)
func compareNativeAndQVACParakeetTranscription() async throws {
    let environment = ProcessInfo.processInfo.environment
    let fixturePath = try #require(
        environment["DROPSIFT_TRANSCRIPTION_BENCHMARK_FIXTURE"]
    )
    let outputPath = try #require(
        environment["DROPSIFT_TRANSCRIPTION_BENCHMARK_OUTPUT"]
    )
    let fixtureURL = URL(fileURLWithPath: fixturePath, isDirectory: true)
    let recording = try #require(RecordingItem.load(from: fixtureURL))
    let tracks = [recording.micURL, recording.systemURL].compactMap { $0 }
    #expect(!tracks.isEmpty)
    let qvacOnly = environment[
        "DROPSIFT_TRANSCRIPTION_BENCHMARK_QVAC_ONLY"
    ] == "1"
    var metrics: [TranscriptionBenchmarkMetric] = []

    if !qvacOnly {
        let native = ParakeetEngine()
        let nativePrepare = try await elapsed {
            try await native.prepare()
        }
        var nativeSegments: [TranscriptSegment] = []
        let nativeRun = try await elapsed {
            for track in tracks {
                nativeSegments += try await native.transcribe(track)
            }
        }
        await native.release()
        metrics.append(TranscriptionBenchmarkMetric(
            backend: "Apple native FluidAudio/Core ML",
            model: native.model,
            gpuRequested: false,
            prepareSeconds: nativePrepare,
            runSeconds: nativeRun,
            segmentCount: nativeSegments.count,
            characterCount: nativeSegments.reduce(0) {
                $0 + $1.text.count
            },
            wordCount: words(in: nativeSegments)
        ))
    }

    let qvac = QVACTranscriptionEngine()
    let qvacPrepare = try await elapsed {
        try await qvac.prepare()
    }
    var qvacSegments: [TranscriptSegment] = []
    let qvacRun = try await elapsed {
        for track in tracks {
            qvacSegments += try await qvac.transcribe(track)
        }
    }
    await qvac.release()
    await QVACRuntime.shared.shutdown()

    let warmQVAC = QVACTranscriptionEngine()
    let qvacWarmPrepare = try await elapsed {
        try await warmQVAC.prepare()
    }
    await warmQVAC.release()
    await QVACRuntime.shared.shutdown()

    let report = TranscriptionBenchmarkReport(
        sourceRevision: environment["DROPSIFT_TRANSCRIPTION_BENCHMARK_SHA"]
            ?? "unknown",
        fixture: fixtureURL.lastPathComponent,
        recordingDurationSeconds: recording.durationSeconds,
        hardware: DeviceProfile.current.summary,
        startedAt: ISO8601DateFormatter().string(from: Date()),
        metrics: metrics + [TranscriptionBenchmarkMetric(
            backend: "QVAC Parakeet/Metal",
            model: qvac.model,
            gpuRequested: true,
            prepareSeconds: qvacPrepare,
            runSeconds: qvacRun,
            segmentCount: qvacSegments.count,
            characterCount: qvacSegments.reduce(0) {
                $0 + $1.text.count
            },
            wordCount: words(in: qvacSegments)
        )],
        qvacWarmPrepareSeconds: qvacWarmPrepare
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(
        to: URL(fileURLWithPath: outputPath),
        options: .atomic
    )
    print("DROPSIFT_TRANSCRIPTION_BENCHMARK_RESULT=" + outputPath)
}
