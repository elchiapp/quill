import AVFoundation
import Foundation

actor QVACTranscriptionEngine: TranscriptionEngine {
    nonisolated let name = "qvac-whisper"
    nonisolated let model = "whisper-small-q8_0"

    private let runtime: QVACRuntime
    private let onPreparationProgress: (@Sendable (Double, String) -> Void)?
    private var prepared = false

    init(
        runtime: QVACRuntime = .shared,
        onPreparationProgress: (@Sendable (Double, String) -> Void)? = nil
    ) {
        self.runtime = runtime
        self.onPreparationProgress = onPreparationProgress
    }

    func prepare() async throws {
        guard !prepared else { return }
        onPreparationProgress?(0, "Preparing QVAC multilingual speech model")
        _ = try await runtime.request(
            "prepareTranscription",
            onEvent: { [onPreparationProgress] event in
                guard event.type == "progress" else { return }
                onPreparationProgress?(
                    (event.percentage ?? 0) / 100,
                    event.detail ?? "Preparing QVAC speech model"
                )
            }
        )
        prepared = true
        onPreparationProgress?(1, "QVAC multilingual speech model ready")
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        guard prepared else { throw QVACRuntime.RuntimeError.bridgeUnavailable }
        let converted = try await QVACAudioConverter.convertToM4A(audio)
        defer { try? FileManager.default.removeItem(at: converted) }
        let response = try await runtime.request(
            "transcribe",
            params: QVACBridgeParams(audioPath: converted.path)
        )
        return (response.segments ?? []).compactMap { segment in
            let text = segment.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(
                start: TimeInterval(segment.startMs) / 1_000,
                end: TimeInterval(segment.endMs) / 1_000,
                text: text
            )
        }
    }

    func release() async {
        if prepared {
            _ = try? await runtime.request("unloadTranscription")
        }
        prepared = false
    }
}

actor QVACSpeakerDiarizationEngine: SpeakerDiarization {
    nonisolated let name = "qvac-sortformer"
    nonisolated let model = "parakeet-sortformer-4spk-v2.1-q8_0"

    private let runtime: QVACRuntime
    private var prepared = false

    init(runtime: QVACRuntime = .shared) {
        self.runtime = runtime
    }

    func prepare() async throws {
        guard !prepared else { return }
        _ = try await runtime.request("prepareDiarization")
        prepared = true
    }

    func diarize(_ audio: URL) async throws -> [DetectedSpeakerTurn] {
        guard prepared else { throw QVACRuntime.RuntimeError.bridgeUnavailable }
        let converted = try await QVACAudioConverter.convertToM4A(audio)
        defer { try? FileManager.default.removeItem(at: converted) }
        let response = try await runtime.request(
            "diarize",
            params: QVACBridgeParams(audioPath: converted.path)
        )
        return (response.turns ?? []).map { turn in
            DetectedSpeakerTurn(
                speaker: turn.speaker,
                start: TimeInterval(turn.startMs) / 1_000,
                end: TimeInterval(turn.endMs) / 1_000,
                confidence: turn.confidence
            )
        }
    }

    func release() async {
        if prepared {
            _ = try? await runtime.request("unloadDiarization")
        }
        prepared = false
    }
}

private enum QVACAudioConverter {
    enum ConversionError: LocalizedError {
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let file):
                "QVAC could not convert " + file
                    + " to a supported audio format."
            }
        }
    }

    static func convertToM4A(_ source: URL) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropsift-qvac-" + UUID().uuidString)
            .appendingPathExtension("m4a")
        let asset = AVURLAsset(url: source)
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ConversionError.unsupported(source.lastPathComponent)
        }
        do {
            try await exporter.export(to: destination, as: .m4a)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
