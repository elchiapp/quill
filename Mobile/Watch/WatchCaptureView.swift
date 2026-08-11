import SwiftUI
import WatchKit

struct WatchCaptureView: View {
    @ObservedObject var recorder: WatchVoiceRecorder
    @ObservedObject var bridge: WatchPhoneBridge

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.indigo)

                Text(
                    recorder.isRecording
                        ? recorder.elapsedLabel
                        : "Voice message"
                )
                .font(recorder.isRecording ? .title.bold() : .headline)
                .monospacedDigit()

                Button {
                    if recorder.isRecording {
                        if let capture = recorder.stop() {
                            bridge.queue(capture)
                            WKInterfaceDevice.current().play(.success)
                        }
                    } else {
                        Task {
                            await recorder.start()
                            if recorder.isRecording {
                                WKInterfaceDevice.current().play(.start)
                            }
                        }
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(recorder.isRecording ? .red : .indigo)
                            .frame(width: 92, height: 92)
                        Image(
                            systemName: recorder.isRecording
                                ? "stop.fill"
                                : "mic.fill"
                        )
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)

                Text(
                    recorder.isRecording
                        ? "Tap to save and send"
                        : bridge.status
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

                if bridge.pendingCount > 0 {
                    Label(
                        "\(bridge.pendingCount) queued",
                        systemImage: "arrow.up.circle"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }

                Text(versionLabel)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .alert(
            "Dropsift",
            isPresented: Binding(
                get: { recorder.errorMessage != nil },
                set: { if !$0 { recorder.errorMessage = nil } }
            )
        ) {
            Button("OK") { recorder.errorMessage = nil }
        } message: {
            Text(recorder.errorMessage ?? "")
        }
    }

    private var versionLabel: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "Development"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String
        return build.map { "v\(version) (\($0))" } ?? "v\(version)"
    }
}
