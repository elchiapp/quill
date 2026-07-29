import AVFAudio
import Foundation

struct VoiceCapture: Sendable {
    let url: URL
    let startedAt: Date
    let durationSeconds: Int
}

@MainActor
final class VoiceRecorder: NSObject, ObservableObject {
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
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard granted else {
            errorMessage = "Microphone permission is required to record a voice message."
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DropsiftVoice", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let url = directory.appendingPathComponent("\(UUID().uuidString).m4a")
            let recorder = try AVAudioRecorder(
                url: url,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                ]
            )
            guard recorder.prepareToRecord(), recorder.record() else {
                throw CocoaError(.fileWriteUnknown)
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
            errorMessage = "Couldn’t start recording: \(error.localizedDescription)"
        }
    }

    func stop() -> VoiceCapture? {
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
        return VoiceCapture(
            url: url,
            startedAt: startedAt,
            durationSeconds: duration
        )
    }
}
