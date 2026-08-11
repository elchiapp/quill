import Foundation

public enum SharedSemanticExtraction {
    private struct Payload: Decodable {
        struct Task: Decodable {
            let title: String
            let description: String?
            let dueDate: String?
            let priority: String?
            let evidence: String?

            enum CodingKeys: String, CodingKey {
                case title
                case description
                case dueDate = "due_date"
                case priority
                case evidence
            }
        }

        struct Entity: Decodable {
            let kind: String
            let name: String
            let summary: String?
            let startDate: String?
            let endDate: String?
            let evidence: String?

            enum CodingKeys: String, CodingKey {
                case kind
                case name
                case summary
                case startDate = "start_date"
                case endDate = "end_date"
                case evidence
            }
        }

        let tasks: [Task]
        let entities: [Entity]
    }

    public static let systemPrompt = """
    Extract explicit, actionable tasks and durable semantic entities from private
    user content. Return JSON only, with no Markdown and no commentary:
    {
      "tasks": [
        {
          "title": "short verb-first task",
          "description": "useful context",
          "due_date": "ISO-8601 date/time or null",
          "priority": "low|medium|high|urgent",
          "evidence": "short supporting excerpt"
        }
      ],
      "entities": [
        {
          "kind": "person|place|event|organization|project|topic",
          "name": "canonical concise name",
          "summary": "why it matters in this source",
          "start_date": "ISO-8601 date/time or null",
          "end_date": "ISO-8601 date/time or null",
          "evidence": "short supporting excerpt"
        }
      ]
    }
    Do not invent facts. A task must describe something somebody should actually
    do, not merely a topic being discussed. Keep only meaningful named entities;
    omit pronouns, generic nouns, and incidental locations. Dates must be resolved
    relative to the supplied processing date when possible.
    """

    public static func userPrompt(
        text: String,
        sourceTitle: String,
        processingDate: Date = Date()
    ) -> String {
        let date = ISO8601DateFormatter().string(from: processingDate)
        return """
        Processing date: \(date)
        Source title: \(sourceTitle)

        Content:
        \(String(text.prefix(80_000)))
        """
    }

    public static func parse(
        _ response: String,
        source _: SharedSemanticSourceReference
    ) -> [SharedSemanticCandidate] {
        guard let json = jsonObject(in: response),
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return [] }

        var output: [SharedSemanticCandidate] = []
        var seenTasks = Set<String>()
        for task in payload.tasks {
            let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalized(title)
            guard !title.isEmpty, seenTasks.insert(key).inserted else { continue }
            output.append(
                SharedSemanticCandidate(
                    task: SharedTaskDraft(
                        title: title,
                        description: task.description ?? "",
                        dueDate: parseDate(task.dueDate),
                        priority: SharedTaskPriority(
                            rawValue: task.priority?.lowercased() ?? ""
                        ) ?? .medium
                    ),
                    evidence: task.evidence ?? title
                )
            )
        }

        var seenEntities = Set<String>()
        for entity in payload.entities {
            guard let kind = SharedSemanticEntityKind(
                rawValue: entity.kind.lowercased()
            ) else { continue }
            let name = entity.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = kind.rawValue + "|" + normalized(name)
            guard !name.isEmpty, seenEntities.insert(key).inserted else { continue }
            output.append(
                SharedSemanticCandidate(
                    entity: SharedEntityDraft(
                        kind: kind,
                        name: name,
                        summary: entity.summary ?? "",
                        startDate: parseDate(entity.startDate),
                        endDate: parseDate(entity.endDate)
                    ),
                    evidence: entity.evidence ?? name
                )
            )
        }
        return output
    }

    public static func heuristicCandidates(
        in text: String,
        source _: SharedSemanticSourceReference,
        processingDate: Date = Date()
    ) -> [SharedSemanticCandidate] {
        let lines = text
            .components(separatedBy: .newlines)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(
                        of: #"^[-*•\d.)\s]+"#,
                        with: "",
                        options: .regularExpression
                    )
            }
            .filter { !$0.isEmpty }

        var output: [SharedSemanticCandidate] = []
        var seen = Set<String>()
        let taskSignals = [
            "todo", "to-do", "action item", "follow up", "follow-up",
            "need to", "needs to", "must ", "should ", "remember to",
            "please ", "by tomorrow", "by monday", "by tuesday",
            "by wednesday", "by thursday", "by friday",
        ]
        for line in lines.prefix(300) {
            let lower = line.lowercased()
            guard taskSignals.contains(where: lower.contains) else { continue }
            let title = taskTitle(from: line)
            let key = "task|" + normalized(title)
            guard title.count >= 4, seen.insert(key).inserted else { continue }
            output.append(
                SharedSemanticCandidate(
                    task: SharedTaskDraft(
                        title: title,
                        description: line == title ? "" : line,
                        dueDate: relativeDueDate(in: lower, from: processingDate),
                        priority: priority(in: lower)
                    ),
                    evidence: line
                )
            )
            if output.filter({ $0.kind == .task }).count >= 12 { break }
        }

        let eventSignals = [
            "meeting", "call", "appointment", "conference", "workshop",
            "demo", "interview", "deadline", "launch",
        ]
        for line in lines.prefix(300) {
            let lower = line.lowercased()
            guard eventSignals.contains(where: lower.contains) else { continue }
            let name = String(line.prefix(100))
            let key = "event|" + normalized(name)
            guard seen.insert(key).inserted else { continue }
            output.append(
                SharedSemanticCandidate(
                    entity: SharedEntityDraft(
                        kind: .event,
                        name: name,
                        summary: line,
                        startDate: relativeDueDate(in: lower, from: processingDate)
                    ),
                    evidence: line
                )
            )
            if output.filter({
                $0.entity?.kind == .event
            }).count >= 8 { break }
        }

        let personPattern =
            #"(?:ask|tell|contact|email|meet with|follow up with|from|by)\s+([A-Z][\p{L}'-]+(?:\s+[A-Z][\p{L}'-]+){0,2})"#
        if let regex = try? NSRegularExpression(
            pattern: personPattern,
            options: [.caseInsensitive]
        ) {
            let sourceText = String(text.prefix(40_000))
            let range = NSRange(sourceText.startIndex..., in: sourceText)
            for match in regex.matches(in: sourceText, range: range).prefix(12) {
                guard let nameRange = Range(match.range(at: 1), in: sourceText)
                else { continue }
                let name = String(sourceText[nameRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard name.first?.isUppercase == true else { continue }
                let key = "person|" + normalized(name)
                guard seen.insert(key).inserted else { continue }
                output.append(
                    SharedSemanticCandidate(
                        entity: SharedEntityDraft(
                            kind: .person,
                            name: name,
                            summary: "Mentioned in this source."
                        ),
                        evidence: name
                    )
                )
            }
        }
        return output
    }

    private static func jsonObject(in response: String) -> String? {
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}"),
              start <= end
        else { return nil }
        return String(response[start...end])
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value,
              !value.isEmpty,
              value.lowercased() != "null"
        else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value)
            ?? ISO8601DateFormatter().date(from: value)
        {
            return date
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private static func taskTitle(from line: String) -> String {
        var value = line.replacingOccurrences(
            of: #"(?i)^(todo|to-do|action item)\s*[:\-]\s*"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?i)^(we|i|you|they)\s+(need to|must|should)\s+"#,
            with: "",
            options: .regularExpression
        )
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst()
    }

    private static func priority(in text: String) -> SharedTaskPriority {
        if text.contains("urgent") || text.contains("asap") {
            return .urgent
        }
        if text.contains("important") || text.contains("high priority") {
            return .high
        }
        if text.contains("someday") || text.contains("when possible") {
            return .low
        }
        return .medium
    }

    private static func relativeDueDate(in text: String, from date: Date) -> Date? {
        let calendar = Calendar.current
        if text.contains("tomorrow") {
            return calendar.date(byAdding: .day, value: 1, to: date)
        }
        if text.contains("next week") {
            return calendar.date(byAdding: .day, value: 7, to: date)
        }
        let weekdays = [
            "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
            "thursday": 5, "friday": 6, "saturday": 7,
        ]
        for (name, weekday) in weekdays where text.contains(name) {
            var components = DateComponents()
            components.weekday = weekday
            return calendar.nextDate(
                after: date,
                matching: components,
                matchingPolicy: .nextTime
            )
        }
        let pattern = #"\b(20\d{2})-(\d{2})-(\d{2})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range, in: text)
        else { return nil }
        return parseDate(String(text[range]))
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
