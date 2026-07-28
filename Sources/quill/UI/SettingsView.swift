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
                    model.saveAISettings()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            GroupBox("Local AI") {
                Form {
                    TextField("Server", text: $model.endpoint)
                        .textFieldStyle(.roundedBorder)

                    Picker("Chat model", selection: $model.selectedModel) {
                        if model.availableModels.isEmpty {
                            Text("No chat models found").tag("")
                        }
                        ForEach(model.availableModels, id: \.self) { modelName in
                            Text(modelName).tag(modelName)
                        }
                    }

                    LabeledContent("Status") {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 7, height: 7)
                            Text(statusText)
                        }
                    }
                }
                .formStyle(.grouped)

                HStack {
                    Text("Compatible with LM Studio, llama.cpp server, and mlx_lm.server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reconnect") {
                        model.saveAISettings()
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
        case .checking: .orange
        case .connected: .green
        case .offline: .red
        }
    }

    private var statusText: String {
        switch model.aiStatus {
        case .checking:
            "Checking…"
        case .connected(let server):
            "\(server) connected"
        case .offline(let message):
            message
        }
    }
}
