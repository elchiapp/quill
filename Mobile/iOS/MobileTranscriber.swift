import DropsiftShared
import Foundation
import Speech

enum MobileTranscriber {
    static func transcribe(_ url: URL) async throws -> SharedTranscriptDocument? {
        let authorization = await authorizationStatus()
        guard authorization == .authorized else { return nil }
        guard let recognizer = SFSpeechRecognizer(locale: .current),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition
        else { return nil }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        let output = try await withCheckedThrowingContinuation {
            continuation in
            let gate = SpeechContinuationGate(continuation)
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    gate.resume(throwing: error)
                } else if let result, result.isFinal {
                    gate.resume(
                        returning: SpeechRecognitionOutput(
                            segments: result.bestTranscription.segments.map {
                                SpeechSegment(
                                    text: $0.substring,
                                    startSeconds: $0.timestamp,
                                    durationSeconds: $0.duration
                                )
                            }
                        )
                    )
                }
            }
        }
        let segments = output.segments.map { segment in
            SharedTranscriptDocument.Segment(
                speaker: "me",
                startMs: Int(segment.startSeconds * 1_000),
                endMs: Int(
                    (segment.startSeconds + segment.durationSeconds) * 1_000
                ),
                text: segment.text
            )
        }
        guard !segments.isEmpty else { return nil }
        return SharedTranscriptDocument(
            engine: "apple-speech",
            model: "on-device",
            createdAt: ISO8601DateFormatter().string(from: Date()),
            segments: segments,
            languageCode: recognizer.locale.language.languageCode?.identifier
        )
    }

    private static func authorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

private struct SpeechRecognitionOutput: Sendable {
    let segments: [SpeechSegment]
}

private struct SpeechSegment: Sendable {
    let text: String
    let startSeconds: TimeInterval
    let durationSeconds: TimeInterval
}

private final class SpeechContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation:
        CheckedContinuation<SpeechRecognitionOutput, any Error>?

    init(
        _ continuation: CheckedContinuation<SpeechRecognitionOutput, any Error>
    ) {
        self.continuation = continuation
    }

    func resume(returning result: SpeechRecognitionOutput) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }

    func resume(throwing error: any Error) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}
