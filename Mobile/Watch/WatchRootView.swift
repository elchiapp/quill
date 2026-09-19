import DropsiftShared
import SwiftUI

struct WatchRootView: View {
    @ObservedObject var recorder: WatchVoiceRecorder
    @ObservedObject var bridge: WatchPhoneBridge

    var body: some View {
        NavigationStack {
            List {
                if let error = bridge.companionError {
                    Section {
                        Label(error, systemImage: "exclamationmark.icloud")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    NavigationLink {
                        WatchCaptureView(recorder: recorder, bridge: bridge)
                            .navigationTitle("Capture")
                    } label: {
                        homeRow(
                            "Capture",
                            detail: recorder.isRecording
                                ? recorder.elapsedLabel
                                : bridge.status,
                            icon: recorder.isRecording
                                ? "stop.circle.fill"
                                : "mic.circle.fill",
                            color: recorder.isRecording ? .red : .indigo
                        )
                    }
                }

                Section("Knowledge") {
                    NavigationLink {
                        WatchTimelineView(bridge: bridge)
                    } label: {
                        homeRow(
                            "Timeline",
                            detail: "\(bridge.snapshot.items.count) recent items",
                            icon: "clock.arrow.circlepath",
                            color: .blue
                        )
                    }
                    NavigationLink {
                        WatchAskView(bridge: bridge)
                    } label: {
                        homeRow(
                            "Ask DropSift",
                            detail: bridge.isPhoneReachable
                                ? "iPhone ready"
                                : "Open iPhone to ask",
                            icon: "sparkles",
                            color: .purple
                        )
                    }
                }

                Section("Organize") {
                    NavigationLink {
                        WatchTasksView(bridge: bridge)
                    } label: {
                        homeRow(
                            "Tasks",
                            detail: "\(bridge.snapshot.tasks.filter { !$0.isCompleted }.count) open",
                            icon: "checklist",
                            color: .green
                        )
                    }
                    NavigationLink {
                        WatchEntitiesView(bridge: bridge)
                    } label: {
                        homeRow(
                            "People & more",
                            detail: "\(bridge.snapshot.entities.count) saved",
                            icon: "square.grid.2x2",
                            color: .orange
                        )
                    }
                }

                Section {
                    Button {
                        bridge.refreshLibrary()
                    } label: {
                        if bridge.isRefreshing {
                            HStack {
                                ProgressView()
                                Text("Syncing…")
                            }
                        } else {
                            Label("Sync from iPhone", systemImage: "arrow.clockwise")
                        }
                    }
                    Text(syncLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("DropSift")
        }
        .onAppear { bridge.refreshLibrary() }
    }

    private var syncLabel: String {
        guard bridge.snapshot.generatedAt != .distantPast else {
            return "No library has been synced yet."
        }
        return "Updated \(bridge.snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func homeRow(
        _ title: String,
        detail: String,
        icon: String,
        color: Color
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

private struct WatchTimelineView: View {
    @ObservedObject var bridge: WatchPhoneBridge

    var body: some View {
        List {
            if bridge.snapshot.items.isEmpty {
                Text("Open DropSift on iPhone to sync your timeline.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(bridge.snapshot.items) { item in
                    NavigationLink {
                        WatchTimelineDetail(item: item)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.headline)
                                .lineLimit(2)
                            Text(item.description)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text(item.kind + " · " + item.date.formatted(
                                date: .abbreviated,
                                time: .shortened
                            ))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Timeline")
    }
}

private struct WatchTimelineDetail: View {
    let item: WatchCompanionItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(item.title)
                    .font(.headline)
                Label(item.kind, systemImage: icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !item.summary.isEmpty {
                    Divider()
                    Text("Summary")
                        .font(.caption.weight(.semibold))
                    Text(item.summary)
                        .font(.body)
                }
                if !item.description.isEmpty,
                   item.description != item.summary {
                    Divider()
                    Text(item.description)
                        .font(.body)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(item.kind)
    }

    private var icon: String {
        switch item.kind.lowercased() {
        case "recording": "waveform"
        case "note": "note.text"
        case "image": "photo"
        default: "doc.text"
        }
    }
}

private struct WatchTasksView: View {
    @ObservedObject var bridge: WatchPhoneBridge

    var body: some View {
        List {
            if bridge.snapshot.tasks.isEmpty {
                Text("No tasks yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(bridge.snapshot.tasks) { task in
                    Button {
                        bridge.toggleTask(task)
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(
                                systemName: task.isCompleted
                                    ? "checkmark.circle.fill"
                                    : "circle"
                            )
                            .foregroundStyle(task.isCompleted ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(task.title)
                                    .strikethrough(task.isCompleted)
                                    .lineLimit(3)
                                HStack(spacing: 4) {
                                    Text(task.priority)
                                    if let dueDate = task.dueDate {
                                        Text("·")
                                        Text(dueDate, style: .date)
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Tasks")
    }
}

private struct WatchEntitiesView: View {
    @ObservedObject var bridge: WatchPhoneBridge

    var body: some View {
        List(bridge.snapshot.entities) { entity in
            NavigationLink {
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(entity.name)
                            .font(.headline)
                        Text(entity.kind)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !entity.summary.isEmpty {
                            Text(entity.summary)
                        }
                        if let date = entity.date {
                            Text(date.formatted(date: .long, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entity.name)
                        .lineLimit(2)
                    Text(entity.kind)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Organize")
    }
}

private struct WatchAskView: View {
    @ObservedObject var bridge: WatchPhoneBridge
    @State private var question = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Ask your library", text: $question)
                    .onSubmit { submit() }
                Button {
                    submit()
                } label: {
                    if bridge.isAsking {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Ask", systemImage: "arrow.up.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || bridge.isAsking
                )

                if let answer = bridge.answer {
                    Divider()
                    Text(answer.text)
                        .font(.body)
                    if !answer.sources.isEmpty {
                        Text("Sources")
                            .font(.caption.weight(.semibold))
                        ForEach(answer.sources, id: \.self) { source in
                            Text("• \(source)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Ask")
    }

    private func submit() {
        bridge.ask(question)
    }
}
