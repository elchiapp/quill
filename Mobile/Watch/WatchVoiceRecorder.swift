import AVFAudio
import Foundation

struct WatchVoiceCapture {
    let url: URL
    let startedAt: Date
    let durationSeconds: Int
}

@MainActor
final class WatchVoiceRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsedSeconds = 0
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var startedAt: Date?
    private var timer: Timer?

    var elapsedLabel: String {
        String(format: "%d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }

    func start() async {
        guard !isRecording else { return }
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { value in
                continuation.resume(returning: value)
            }
        }
        guard granted else {
            errorMessage = "Allow microphone access in Settings."
            return
        }
        let session = AVAudioSession.sharedInstance()
        var stage = "configuring the microphone"
        do {
            // `.spokenAudio` is a playback mode. On a physical Watch it can
            // make the record-only session fail with paramErr (OSStatus -50).
            // Configure a plain recording session and use watchOS's
            // asynchronous activation path before creating the recorder.
            try session.setCategory(.record, mode: .default)
            stage = "activating the microphone"
            let activated = try await session.activate()
            guard activated else {
                throw WatchVoiceRecorderError.sessionActivationFailed
            }

            stage = "creating the recording file"
            let directory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first?
                .appendingPathComponent("OutgoingVoice", isDirectory: true)
                ?? FileManager.default.temporaryDirectory
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let url = directory.appendingPathComponent("\(UUID().uuidString).m4a")
            let recorder = try AVAudioRecorder(
                url: url,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    // Match WatchKit's wide-band speech preset. This is a
                    // format Apple Watch hardware accepts consistently.
                    AVSampleRateKey: 16_000.0,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 32_000,
                    AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
                ]
            )
            stage = "preparing the recorder"
            guard recorder.prepareToRecord() else {
                recorder.deleteRecording()
                throw WatchVoiceRecorderError.preparationFailed
            }
            stage = "starting the recorder"
            guard recorder.record() else {
                recorder.deleteRecording()
                throw WatchVoiceRecorderError.recordingFailed
            }
            self.recorder = recorder
            startedAt = Date()
            elapsedSeconds = 0
            isRecording = true
            errorMessage = nil
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    self?.elapsedSeconds = Int(self?.recorder?.currentTime ?? 0)
                }
            }
        } catch {
            try? session.setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            errorMessage = "Couldn’t start recording while \(stage): \(error.localizedDescription)"
        }
    }

    func stop() -> WatchVoiceCapture? {
        guard let recorder, let startedAt else { return nil }
        let duration = max(1, Int(recorder.currentTime.rounded()))
        let url = recorder.url
        recorder.stop()
        timer?.invalidate()
        timer = nil
        self.recorder = nil
        self.startedAt = nil
        isRecording = false
        elapsedSeconds = 0
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        return WatchVoiceCapture(
            url: url,
            startedAt: startedAt,
            durationSeconds: duration
        )
    }
}

private enum WatchVoiceRecorderError: LocalizedError {
    case sessionActivationFailed
    case preparationFailed
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .sessionActivationFailed:
            "The Watch couldn’t activate its microphone."
        case .preparationFailed:
            "The Watch couldn’t prepare the audio file."
        case .recordingFailed:
            "The Watch microphone didn’t start."
        }
    }
}
