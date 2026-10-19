import Foundation
import Testing
@testable import dropsift

@Test func speechPerformanceLogContainsOnlyMetricsAndAppends() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = SpeechPerformanceLog(directory: directory)
    let metric = SpeechPerformanceMetric(phase: "normalized-chunk", settings: QVACSpeechSettings(),
        audioSeconds: 60, wallSeconds: 1.5, succeeded: true, stats: nil, diagnostics: nil)
    await log.append(metric)
    await log.append(metric)
    let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
    let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 2)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let row = try decoder.decode(SpeechPerformanceMetric.self, from: Data(lines[0].utf8))
    #expect(row.wallSeconds == 1.5)
    #expect(row.realTimeFactor == 0.025)
    #expect(!lines[0].contains("transcript"))
}
