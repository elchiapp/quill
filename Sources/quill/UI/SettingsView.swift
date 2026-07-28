import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Quill settings")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            GroupBox("Local AI") {
                Form {
                    LabeledContent("Model", value: BuiltInLLMEngine.modelDisplayName)
                    LabeledContent("Engine", value: "Built into Quill · Apple MLX")
                    LabeledContent("Download", value: BuiltInLLMEngine.approximateDownloadSize)

                    LabeledContent("Status") {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 7, height: 7)
                            Text(statusText)
                        }
                    }

                    if case .downloading(let fraction) = model.aiStatus {
                        ProgressView(value: fraction)
                    }
                }
                .formStyle(.grouped)

                HStack {
                    Text("Quill downloads the model itself and then runs fully offline. No server or second app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show model files") {
                        model.openModelFolder()
                    }
                    if canPrepare {
                        Button("Download model") {
                            model.downloadBuiltInAI()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            GroupBox("Storage") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Location", value: model.storageLabel)
                    Text(model.root.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack {
                        Text("Completed recordings, transcripts, and chat threads sync through iCloud Drive.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open in Finder") { model.openRecordingsFolder() }
                    }
                }
                .padding(8)
            }
        }
        .padding(24)
        .frame(width: 620)
    }

    private var statusColor: Color {
        switch model.aiStatus {
        case .notDownloaded: .secondary
        case .downloading, .loading: .orange
        case .ready: .green
        case .failed: .red
        }
    }

    private var statusText: String {
        switch model.aiStatus {
        case .notDownloaded:
            "Downloads automatically when you first ask a question"
        case .downloading(let fraction):
            "Downloading inside Quill · \(Int(fraction * 100))%"
        case .loading:
            "Loading model into memory…"
        case .ready:
            "Ready · in-process and offline"
        case .failed(let message):
            message
        }
    }

    private var canPrepare: Bool {
        switch model.aiStatus {
        case .notDownloaded, .failed:
            true
        case .downloading, .loading, .ready:
            false
        }
    }
}
