import Foundation

public enum SharedClipboardContent {
    public static func titleAndDescription(
        title: String,
        description: String
    ) -> String {
        joined([
            title.trimmingCharacters(in: .whitespacesAndNewlines),
            description.trimmingCharacters(in: .whitespacesAndNewlines),
        ])
    }

    public static func summary(
        title: String,
        summary: RecordingSummary,
        includesParticipants: Bool
    ) -> String {
        var blocks = [
            title.trimmingCharacters(in: .whitespacesAndNewlines),
            "Summary\n" + summary.overview.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
        ]
        if includesParticipants {
            blocks.append(
                list(
                    title: "Participants (\(summary.participantCount))",
                    values: summary.participants
                )
            )
        }
        blocks.append(list(title: "Topics", values: summary.topics))
        blocks.append(list(title: "Decisions", values: summary.decisions))
        blocks.append(list(title: "Action items", values: summary.actionItems))
        blocks.append("Generated locally with \(summary.model)")
        return joined(blocks)
    }

    public static func extractedText(
        title: String,
        sections: [(locator: String, text: String)]
    ) -> String {
        let content = sections.compactMap { section -> String? in
            let text = section.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !text.isEmpty else { return nil }
            let locator = section.locator.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return locator.isEmpty ? text : locator + "\n" + text
        }
        guard !content.isEmpty else { return "" }
        return joined(
            [title.trimmingCharacters(in: .whitespacesAndNewlines)] + content
        )
    }

    public static func semanticReview(_ review: SharedSemanticReview?) -> String {
        guard let review, !review.candidates.isEmpty else { return "" }
        var blocks = [
            review.sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            "Tasks & details",
        ]
        let tasks = review.candidates.filter { $0.kind == .task }
        if !tasks.isEmpty {
            blocks.append(
                candidateList(title: "Things to do", candidates: tasks)
            )
        }
        for kind in SharedSemanticEntityKind.allCases {
            let candidates = review.candidates.filter {
                $0.entity?.kind == kind
            }
            if !candidates.isEmpty {
                blocks.append(
                    candidateList(
                        title: kind.displayName,
                        candidates: candidates
                    )
                )
            }
        }
        return joined(blocks)
    }

    public static func everything(_ sections: [String]) -> String {
        sections
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n---\n\n")
    }

    private static func list(title: String, values: [String]) -> String {
        let values = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !values.isEmpty else { return "" }
        return title + "\n" + values.map { "- " + $0 }.joined(separator: "\n")
    }

    private static func candidateList(
        title: String,
        candidates: [SharedSemanticCandidate]
    ) -> String {
        let values = candidates.compactMap { candidate -> String? in
            let name = candidate.task?.title
                ?? candidate.entity?.name
                ?? ""
            guard !name.isEmpty else { return nil }
            var details: [String] = []
            if let task = candidate.task {
                details.append(task.priority.displayName + " priority")
                if let dueDate = task.dueDate {
                    details.append(
                        "Due " + dueDate.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                    )
                }
                if !task.description.isEmpty {
                    details.append(task.description)
                }
            } else if let summary = candidate.entity?.summary,
                      !summary.isEmpty {
                details.append(summary)
            }
            if !candidate.evidence.isEmpty {
                details.append("Evidence: " + candidate.evidence)
            }
            return "- " + name + (details.isEmpty
                ? ""
                : "\n  " + details.joined(separator: " · "))
        }
        guard !values.isEmpty else { return "" }
        return title + "\n" + values.joined(separator: "\n")
    }

    private static func joined(_ blocks: [String]) -> String {
        blocks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}
