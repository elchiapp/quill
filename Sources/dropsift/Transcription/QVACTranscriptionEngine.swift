import AVFoundation
import Foundation

actor QVACTranscriptionEngine: TranscriptionEngine {
    nonisolated let name = "qvac-parakeet"
    nonisolated let model = "parakeet-tdt-0.6b-v3-q8_0-metal"
    // QVAC's public Parakeet API currently returns text without word timing
    // metadata. One-minute batches preserve useful, bounded source anchors.
    nonisolated static let chunkDuration: TimeInterval = 60

    private let runtime: QVACRuntime
    private let onPreparationProgress: (@Sendable (Double, String) -> Void)?
    private let onTranscriptionProgress: (@Sendable (Double, String) -> Void)?
    private var prepared = false
    private var preparedGeneration: Int?

    init(
        runtime: QVACRuntime = .shared,
        onPreparationProgress: (@Sendable (Double, String) -> Void)? = nil,
        onTranscriptionProgress: (@Sendable (Double, String) -> Void)? = nil
    ) {
        self.runtime = runtime
        self.onPreparationProgress = onPreparationProgress
        self.onTranscriptionProgress = onTranscriptionProgress
    }

    func prepare() async throws {
        let generation = await runtime.currentGeneration()
        guard !prepared || preparedGeneration != generation else { return }
        prepared = false
        preparedGeneration = nil
        onPreparationProgress?(0, "Preparing QVAC Parakeet speech model")
        _ = try await runtime.request(
            "prepareTranscription",
            onEvent: { [onPreparationProgress] event in
                guard event.type == "progress" else { return }
                onPreparationProgress?(
                    (event.percentage ?? 0) / 100,
                    event.detail ?? "Preparing QVAC Parakeet model"
                )
            }
        )
        prepared = true
        preparedGeneration = await runtime.currentGeneration()
        onPreparationProgress?(1, "QVAC Parakeet model ready")
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        try await prepare()
        let duration = try await QVACAudioConverter.duration(of: audio)
        let chunks = QVACAudioChunkPlan.make(
            duration: duration,
            maximumDuration: Self.chunkDuration
        )
        var transcript: [TranscriptSegment] = []

        for chunk in chunks {
            let baseProgress = chunk.start / max(duration, 1)
            onTranscriptionProgress?(
                baseProgress,
                "QVAC transcribing part \(chunk.index + 1) of \(chunks.count)"
            )
            let converted = try await QVACAudioConverter.convertToPCM(
                audio,
                range: chunk
            )
            defer { try? FileManager.default.removeItem(at: converted) }

            let response = try await transcribeChunk(
                converted,
                chunk: chunk,
                totalDuration: duration,
                totalChunks: chunks.count
            )
            transcript.append(contentsOf: (response.segments ?? []).compactMap {
                segment in
                let text = segment.text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !text.isEmpty else { return nil }
                return TranscriptSegment(
                    start: chunk.start
                        + TimeInterval(segment.startMs) / 1_000,
                    end: chunk.start
                        + TimeInterval(segment.endMs) / 1_000,
                    text: text
                )
            })
            onTranscriptionProgress?(
                min(1, (chunk.start + chunk.duration) / max(duration, 1)),
                "QVAC transcribed part \(chunk.index + 1) of \(chunks.count)"
            )
        }
        return transcript
    }

    private func transcribeChunk(
        _ audio: URL,
        chunk: QVACAudioChunkPlan.Chunk,
        totalDuration: TimeInterval,
        totalChunks: Int
    ) async throws -> QVACBridgeResponse {
        do {
            return try await runtime.request(
                "transcribe",
                params: QVACBridgeParams(
                    audioPath: audio.path,
                    audioDurationMs: Int((chunk.duration * 1_000).rounded())
                ),
                timeout: .seconds(75),
                onEvent: { [onTranscriptionProgress] event in
                    guard event.type == "progress" else { return }
                    onTranscriptionProgress?(
                        chunk.start / max(totalDuration, 1),
                        "QVAC transcribing part \(chunk.index + 1) of \(totalChunks)"
                    )
                }
            )
        } catch QVACRuntime.RuntimeError.requestTimedOut {
            await runtime.restart()
            prepared = false
            preparedGeneration = nil
            throw QVACRuntime.RuntimeError.requestTimedOut("transcription")
        }
    }

    func release() async {
        if prepared {
            _ = try? await runtime.request("unloadTranscription")
        }
        prepared = false
        preparedGeneration = nil
    }
}

enum QVACAudioChunkPlan {
    struct Chunk: Sendable, Equatable {
        let index: Int
        let start: TimeInterval
        let duration: TimeInterval
    }

    static func make(
        duration: TimeInterval,
        maximumDuration: TimeInterval
    ) -> [Chunk] {
        guard duration > 0, maximumDuration > 0 else { return [] }
        var chunks: [Chunk] = []
        var start: TimeInterval = 0
        while start < duration {
            chunks.append(Chunk(
                index: chunks.count,
                start: start,
                duration: min(maximumDuration, duration - start)
            ))
            start += maximumDuration
        }
        return chunks
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
        let converted = try await QVACAudioConverter.convertToPCM(audio)
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

enum QVACAudioConverter {
    enum ConversionError: LocalizedError {
        case unsupported(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let file):
                "QVAC could not convert " + file
                    + " to a supported audio format."
            case .failed(let file):
                "QVAC could not normalize " + file
                    + " to 16 kHz mono audio."
            }
        }
    }

    static func duration(of source: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: source)
        return max(0, try await asset.load(.duration).seconds)
    }

    static func convertToPCM(
        _ source: URL,
        range: QVACAudioChunkPlan.Chunk? = nil
    ) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropsift-qvac-" + UUID().uuidString)
            .appendingPathExtension("raw")
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(
            withMediaType: .audio
        ).first else {
            throw ConversionError.unsupported(source.lastPathComponent)
        }
        let reader = try AVAssetReader(asset: asset)
        if let range {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: range.start, preferredTimescale: 1_000),
                duration: CMTime(
                    seconds: range.duration,
                    preferredTimescale: 1_000
                )
            )
        }

        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ConversionError.unsupported(source.lastPathComponent)
        }
        reader.add(output)

        do {
            FileManager.default.createFile(
                atPath: destination.path,
                contents: nil
            )
            let file = try FileHandle(forWritingTo: destination)
            defer { try? file.close() }
            guard reader.startReading() else {
                throw reader.error
                    ?? ConversionError.failed(source.lastPathComponent)
            }
            while let sample = output.copyNextSampleBuffer() {
                guard let buffer = CMSampleBufferGetDataBuffer(sample) else {
                    continue
                }
                let length = CMBlockBufferGetDataLength(buffer)
                var data = Data(count: length)
                let status = data.withUnsafeMutableBytes { bytes in
                    guard let address = bytes.baseAddress else {
                        return kCMBlockBufferBadCustomBlockSourceErr
                    }
                    return CMBlockBufferCopyDataBytes(
                        buffer,
                        atOffset: 0,
                        dataLength: length,
                        destination: address
                    )
                }
                guard status == kCMBlockBufferNoErr else {
                    throw ConversionError.failed(source.lastPathComponent)
                }
                try file.write(contentsOf: data)
            }
            guard reader.status == .completed else {
                throw reader.error
                    ?? ConversionError.failed(source.lastPathComponent)
            }
            return destination
        } catch {
            reader.cancelReading()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
