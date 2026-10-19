import Foundation

/// Local metadata only. No transcript, audio, item title, or source path is stored.
struct SpeechPerformanceMetric: Codable, Sendable {
    var date = Date()
    let phase: String
    let settings: QVACSpeechSettings
    let audioSeconds: Double
    let wallSeconds: Double
    let succeeded: Bool
    let stats: QVACBridgeSpeechStats?
    let diagnostics: QVACBridgeDiagnostics?
    var realTimeFactor: Double? { audioSeconds > 0 ? wallSeconds / audioSeconds : nil }
}

actor SpeechPerformanceLog {
    static let shared = SpeechPerformanceLog(directory: QVACSpeechSettings().performanceDirectory)
    private let directory: URL
    init(directory: URL) { self.directory = directory }

    func append(_ metric: SpeechPerformanceMetric) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(metric)
            data.append(0x0a)
            // One file per UTC day. No idle timer, polling, or background batch.
            let day = ISO8601DateFormatter().string(from: metric.date).prefix(10)
            let file = directory.appendingPathComponent("speech-\(day).jsonl")
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil,
                    attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // A diagnostic write must never discard or fail a transcription.
        }
    }
}
