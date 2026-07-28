import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Quill settings")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            VStack(alignment: .leading, spacing: 5) {
                Label(model.deviceProfile.summary, systemImage: "memorychip")
                    .font(.body.weight(.semibold))
                Text(
                    "MLX is hard-limited to \(model.recommendedModelPlan.budgetLabel), leaving at least 50% of unified memory available."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Built-in local AI")
                        .font(.headline)
                    Text("In-process Apple MLX · native context up to 262K tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                status
            }

            ForEach(model.modelPlans, id: \.model.id) { plan in
                Divider()
                modelRow(plan)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Model storage")
                        .font(.caption.weight(.semibold))
                    Text(model.modelCacheRoot.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Show model files") { model.openModelFolder() }
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recordings and threads · \(model.storageLabel)")
                        .font(.caption.weight(.semibold))
                    Text(model.root.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Open in Finder") { model.openRecordingsFolder() }
            }
        }
        .padding(24)
        .frame(width: 740)
    }

    private var status: some View {
        HStack(spacing: 7) {
            if case .loading = model.aiStatus {
                ProgressView()
                    .controlSize(.small)
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
            }
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func modelRow(_ plan: BuiltInModelPlan) -> some View {
        let selected = plan.model.id == model.selectedModelID
        let recommended = plan.model.id == model.recommendedModelPlan.model.id
        let compatible = plan.fitsMemoryBudget
            && model.deviceProfile.totalMemoryBytes
                >= plan.model.minimumDeviceMemoryBytes

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .font(.title3)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(plan.model.name)
                        .font(.body.weight(.semibold))
                    Text(plan.model.parameterLabel)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    if plan.model.id == AIModelCatalog.defaultModel.id {
                        Text("Default")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if recommended {
                        Text("Recommended")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                    if model.isModelCached(plan.model) {
                        Text("Downloaded")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }

                Text(plan.model.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(
                    compatible
                        ? "\(plan.model.downloadLabel) download · \(plan.contextLabel) context · ~\(plan.memoryLabel) memory"
                        : "Unavailable under the 50% memory safety limit"
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(compatible ? Color.secondary : Color.red)

                if selected, case .downloading(let fraction) = model.aiStatus {
                    ProgressView(value: fraction) {
                        Text("Downloading · \(Int(fraction * 100))%")
                            .font(.caption2)
                    }
                    .frame(width: 300)
                } else if selected, case .loading = model.aiStatus {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading model into unified memory…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if selected {
                selectedModelAction
            } else {
                Button(model.isModelCached(plan.model) ? "Load & use" : "Download & use") {
                    model.selectModel(plan.model.id)
                }
                .disabled(
                    !compatible
                        || model.isAITransitioning
                        || model.isAnswering
                )
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var selectedModelAction: some View {
        switch model.aiStatus {
        case .notDownloaded:
            Button("Download") { model.downloadBuiltInAI() }
                .buttonStyle(.borderedProminent)
        case .downloaded:
            Button("Load") { model.downloadBuiltInAI() }
                .buttonStyle(.borderedProminent)
        case .failed:
            Button("Retry") { model.downloadBuiltInAI() }
                .buttonStyle(.borderedProminent)
        case .ready:
            Label("In use", systemImage: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        case .downloading, .loading:
            EmptyView()
        }
    }

    private var statusColor: Color {
        switch model.aiStatus {
        case .notDownloaded, .downloaded: .secondary
        case .downloading, .loading: .orange
        case .ready: .green
        case .failed: .red
        }
    }

    private var statusText: String {
        switch model.aiStatus {
        case .notDownloaded:
            "Not downloaded"
        case .downloaded:
            "Downloaded · not loaded"
        case .downloading(let fraction):
            "Downloading \(model.selectedModelPlan.model.name) · \(Int(fraction * 100))%"
        case .loading:
            "Loading \(model.selectedModelPlan.model.name)…"
        case .ready:
            "\(model.selectedModelPlan.model.name) ready"
        case .failed(let message):
            message
        }
    }
}

struct ModelRecommendationView: View {
    @ObservedObject var model: AppModel

    private var recommendation: BuiltInModelPlan {
        model.recommendedModelPlan
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "memorychip.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("This Mac can run a stronger model")
                        .font(.title2.weight(.semibold))
                    Text(model.deviceProfile.summary)
                        .foregroundStyle(.secondary)
                }
            }

            Text(
                "Quill starts conservatively with Qwen3.5 2B. Based on this Mac, the recommended option is \(recommendation.model.name)."
            )

            HStack(spacing: 12) {
                metric(
                    title: "Recommended",
                    value: recommendation.model.parameterLabel
                )
                metric(
                    title: "Context window",
                    value: recommendation.contextLabel
                )
                metric(
                    title: "Estimated model memory",
                    value: "\(recommendation.memoryLabel) / \(recommendation.budgetLabel)"
                )
            }

            Text(
                "The \(recommendation.budgetLabel) ceiling is enforced by MLX and leaves at least half of unified memory available to macOS and your other apps. The model only downloads if you choose it."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button("Review all models") { model.reviewModelChoices() }
                Spacer()
                Button("Keep Qwen3.5 2B") { model.keepConservativeModel() }
                Button("Use \(recommendation.model.name)") {
                    model.useRecommendedModel()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 680)
        .interactiveDismissDisabled()
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.weight(.semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }
}
