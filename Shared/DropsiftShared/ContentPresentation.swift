import Foundation

public enum LocalModelOutputError: LocalizedError {
    case unreadableStructuredResponse

    public var errorDescription: String? {
        switch self {
        case .unreadableStructuredResponse:
            "The local model returned a response Dropsift couldn’t read. Try again."
        }
    }
}

public struct ContentPresentation: Codable, Sendable, Equatable {
    public var title: String
    public var description: String
    public let sourceRevision: String
    public let generatedAt: Date
    public let model: String

    public init(
        title: String,
        description: String,
        sourceRevision: String,
        generatedAt: Date = Date(),
        model: String
    ) {
        self.title = title
        self.description = description
        self.sourceRevision = sourceRevision
        self.generatedAt = generatedAt
        self.model = model
    }
}

public enum ContentPresentationStore {
    public static let filename = "presentation.json"

    public static func load(from directory: URL) -> ContentPresentation? {
        let url = directory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let presentation = try? decoder.decode(
            ContentPresentation.self,
            from: data
        ), !ContentPresentationGenerator.containsPromptPlaceholder(
            title: presentation.title,
            description: presentation.description
        ) else { return nil }
        return presentation
    }

    public static func save(
        _ presentation: ContentPresentation,
        to directory: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(presentation).write(
            to: directory.appendingPathComponent(filename),
            options: .atomic
        )
    }

    public static func invalidate(in directory: URL) throws {
        let url = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public static func isCurrent(in directory: URL, revision: String) -> Bool {
        load(from: directory)?.sourceRevision == revision
    }

    public static func revision(for text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

public enum ContentPresentationGenerator {
    private struct Response: Decodable {
        let title: String
        let description: String
    }

    public static let systemPrompt = """
    You name and describe items in a private personal knowledge base.
    Return exactly one JSON object containing exactly two string fields named
    "title" and "description". Every value must be derived from the supplied
    item content. Never copy wording from these instructions into either value.

    Requirements:
    - Infer the central subject and purpose from the supplied content.
    - Preserve the most distinctive organization, project, product, or identifier in the title when one is present.
    - Prefer the subject organizations/projects over the names of people merely speaking.
    - Title: 3-10 words, specific, natural, no trailing punctuation.
    - Description: one or two short sentences explaining what the item is about.
    - Do not use generic titles such as Meeting, Notes, Recording, Conversation, or Summary.
    - Do not invent facts. Do not include Markdown or any text outside the JSON object.
    """

    public static let conversationTitleSystemPrompt = """
    Create a concise, specific title for this conversation based on what the
    user asked and what was answered. Preserve useful names and identifiers.
    If a distinctive organization, project, product, or alphanumeric identifier
    is central to the question, include it in the title. Prefer the subject of
    the conversation over phrases such as "What was" or "Tell me about".
    Return only a natural 3-8 word title with no quotation marks, prefix,
    Markdown, or trailing punctuation. Never return a generic title such as
    Conversation, Question, Chat, or New conversation.
    """

    public static func userPrompt(
        kind: String,
        currentTitle: String,
        text: String
    ) -> String {
        let excerpt = sampled(text, limit: 32_000)
        let terms = distinctiveTerms(in: excerpt)
        return """
        ITEM TYPE: \(kind)
        CURRENT TITLE: \(currentTitle)
        DISTINCTIVE TERMS TO PRESERVE WHEN CENTRAL: \(terms.isEmpty ? "(none detected)" : terms.joined(separator: ", "))

        CONTENT:
        \(excerpt)
        """
    }

    public static func parse(
        _ response: String,
        sourceRevision: String,
        model: String
    ) -> ContentPresentation? {
        let decoded = LocalModelStructuredOutput.jsonObjects(in: response)
            .compactMap { object -> Response? in
                guard let data = object.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(Response.self, from: data)
            }
            .first
        let rawTitle = decoded?.title
            ?? LocalModelStructuredOutput.stringValue(
                for: "title",
                in: response
            )
        let rawDescription = decoded?.description
            ?? LocalModelStructuredOutput.stringValue(
                for: "description",
                in: response
            )
        guard let rawTitle,
              let rawDescription,
              let title = cleanTitle(rawTitle),
              let description = cleanDescription(rawDescription),
              !containsPromptPlaceholder(
                  title: title,
                  description: description
              )
        else { return nil }

        return ContentPresentation(
            title: title,
            description: description,
            sourceRevision: sourceRevision,
            model: model
        )
    }

    public static func cleanTitle(_ raw: String) -> String? {
        var value = raw
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("title:") {
            value = String(value.dropFirst(6))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let quotationMarks = CharacterSet(charactersIn: "\"'`“”‘’")
        let trailingPunctuation = CharacterSet(charactersIn: ".:;,-–—")
        value = value.trimmingCharacters(in: quotationMarks)
        value = value
            .components(separatedBy: .newlines)
            .first?
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        value = value.trimmingCharacters(in: trailingPunctuation)
        value = value.trimmingCharacters(in: quotationMarks)
        value = value.trimmingCharacters(in: trailingPunctuation)
        let generic = [
            "conversation", "new conversation", "chat", "question",
            "meeting", "recording", "notes", "summary",
        ]
        guard value.count >= 3,
              value.count <= 100,
              !generic.contains(value.lowercased()),
              !titlePlaceholders.contains(normalizedPlaceholder(value))
        else { return nil }
        return value
    }

    public static func cleanDescription(_ raw: String) -> String? {
        var value = raw
            .replacingOccurrences(of: "```", with: "")
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("description:") {
            value = String(value.dropFirst(12))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        value = value.trimmingCharacters(
            in: CharacterSet(charactersIn: "\"'`“”‘’")
        )
        guard value.count >= 12,
              !descriptionPlaceholders.contains(normalizedPlaceholder(value))
        else { return nil }
        if value.count > 280 {
            let prefix = String(value.prefix(277))
            let boundary = prefix.lastIndex(of: " ") ?? prefix.endIndex
            value = String(prefix[..<boundary]) + "…"
        }
        return value
    }

    fileprivate static func containsPromptPlaceholder(
        title: String,
        description: String
    ) -> Bool {
        titlePlaceholders.contains(normalizedPlaceholder(title))
            || descriptionPlaceholders.contains(
                normalizedPlaceholder(description)
            )
    }

    private static let titlePlaceholders: Set<String> = [
        "title",
        "specific title",
        "concise title",
        "concise specific title",
        "generated title",
        "item title",
    ]

    private static let descriptionPlaceholders: Set<String> = [
        "description",
        "brief description",
        "concise description",
        "item description",
        "one or two concise sentences",
        "one or two short sentences",
    ]

    private static func normalizedPlaceholder(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(
                of: #"[^a-z0-9]+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sampled(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let headCount = limit * 3 / 4
        let tailCount = limit - headCount
        return String(text.prefix(headCount))
            + "\n\n[…middle omitted…]\n\n"
            + String(text.suffix(tailCount))
    }

    private static func distinctiveTerms(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"\b[A-Za-z][A-Za-z0-9-]{2,}\b"#
        ) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let ignored: Set<String> = [
            "the", "this", "that", "these", "those", "they", "their", "we",
            "there", "where", "when", "what", "with", "from", "into",
            "notes", "transcript", "speaker", "user", "dropsift", "item",
        ]
        var seen = Set<String>()
        var terms: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard let tokenRange = Range(match.range, in: text) else { continue }
            let token = String(text[tokenRange])
            let lowercased = token.lowercased()
            let isIdentifier = token.contains(where: \.isNumber)
            let isAcronym = token == token.uppercased() && token.count <= 10
            let isProperName = token.first?.isUppercase == true
            let isSpeakerLabel = text.contains("\(token):")
            guard !ignored.contains(lowercased),
                  !isSpeakerLabel,
                  isIdentifier || isAcronym || isProperName,
                  seen.insert(lowercased).inserted
            else { continue }
            terms.append(token)
            if terms.count == 12 { break }
        }
        return terms
    }
}

/// Small local models occasionally wrap a valid object in prose, emit more
/// than one brace-delimited block, or return labeled fields instead of strict
/// JSON. Keeping that tolerance here prevents every feature from inventing a
/// different parser for the same model behavior.
public enum LocalModelStructuredOutput {
    public static func jsonObjects(in response: String) -> [String] {
        var objects: [String] = []
        var start: String.Index?
        var depth = 0
        var isInString = false
        var quote: Character?
        var isEscaped = false

        for index in response.indices {
            let character = response[index]
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == quote {
                    isInString = false
                    quote = nil
                }
                continue
            }
            if depth > 0 && (character == "\"" || character == "'") {
                isInString = true
                quote = character
                continue
            }
            if character == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if character == "}", depth > 0 {
                depth -= 1
                if depth == 0, let start {
                    objects.append(String(response[start ... index]))
                    isInString = false
                    quote = nil
                    isEscaped = false
                }
            }
        }
        return objects
    }

    public static func stringValue(
        for key: String,
        in response: String
    ) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let quotedPattern = #"(?is)[\"']?\b"# + escapedKey
            + #"\b[\"']?\s*:\s*([\"'])(.*?)\1\s*(?:,|\}|$)"#
        if let value = firstCapture(
            pattern: quotedPattern,
            capture: 2,
            in: response
        ) {
            return value
                .replacingOccurrences(of: #"\n"#, with: "\n")
                .replacingOccurrences(of: #"\""#, with: "\"")
        }
        let linePattern = #"(?im)^\s*"# + escapedKey
            + #"\s*:\s*(.+?)\s*$"#
        return firstCapture(
            pattern: linePattern,
            capture: 1,
            in: response
        )
    }

    public static func stringArray(
        for key: String,
        in response: String
    ) -> [String] {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let arrayPattern = #"(?is)[\"']?\b"# + escapedKey
            + #"\b[\"']?\s*:\s*\[(.*?)\]"#
        guard let body = firstCapture(
            pattern: arrayPattern,
            capture: 1,
            in: response
        ) else { return [] }
        guard let regex = try? NSRegularExpression(
            pattern: #"(?s)([\"'])(.*?)\1"#
        ) else { return [] }
        let range = NSRange(body.startIndex..., in: body)
        return regex.matches(in: body, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 2), in: body) else {
                return nil
            }
            return String(body[valueRange])
                .replacingOccurrences(of: #"\n"#, with: "\n")
                .replacingOccurrences(of: #"\""#, with: "\"")
        }
    }

    private static func firstCapture(
        pattern: String,
        capture: Int,
        in value: String
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
              ),
              let range = Range(match.range(at: capture), in: value)
        else { return nil }
        return String(value[range])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

}


public struct RecordingSummary: Codable, Sendable, Equatable {
    public let overview: String
    public let participantCount: Int
    public let participants: [String]
    public let topics: [String]
    public let decisions: [String]
    public let actionItems: [String]
    public let sourceRevision: String
    public let generatedAt: Date
    public let model: String

    public init(
        overview: String,
        participantCount: Int,
        participants: [String],
        topics: [String],
        decisions: [String],
        actionItems: [String],
        sourceRevision: String,
        generatedAt: Date = Date(),
        model: String
    ) {
        self.overview = overview
        self.participantCount = participantCount
        self.participants = participants
        self.topics = topics
        self.decisions = decisions
        self.actionItems = actionItems
        self.sourceRevision = sourceRevision
        self.generatedAt = generatedAt
        self.model = model
    }
}

public enum RecordingSummaryStore {
    public static let filename = "summary.json"

    public static func load(from directory: URL) -> RecordingSummary? {
        guard let data = try? Data(
            contentsOf: directory.appendingPathComponent(filename)
        ) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RecordingSummary.self, from: data)
    }

    public static func save(
        _ summary: RecordingSummary,
        to directory: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(summary).write(
            to: directory.appendingPathComponent(filename),
            options: .atomic
        )
    }

    public static func invalidate(in directory: URL) throws {
        let url = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public static func isCurrent(in directory: URL, revision: String) -> Bool {
        load(from: directory)?.sourceRevision == revision
    }
}

public enum RecordingSummaryGenerator {
    private struct Response: Decodable {
        let overview: String
        let participants: [String]
        let topics: [String]
        let decisions: [String]
        let actionItems: [String]

        enum CodingKeys: String, CodingKey {
            case overview, participants, topics, decisions
            case actionItems = "action_items"
        }
    }

    public static let systemPrompt = """
    Summarize a private meeting transcript faithfully and concisely.
    Return exactly one JSON object with this schema:
    {"overview":"two to four sentences","participants":["name or speaker label"],"topics":["topic"],"decisions":["decision"],"action_items":["action with owner and due date when stated"]}

    Requirements:
    - Cover what the meeting was about and the main outcome.
    - Include only people supported by speaker labels or explicitly named.
    - Keep topics, decisions, and action items short and specific.
    - An action item must be a genuine commitment or request, not a general discussion point.
    - If no decisions or action items were stated, return an empty array.
    - Do not invent names, owners, dates, facts, or outcomes.
    - Do not include Markdown or any text outside the JSON object.
    """

    public static func userPrompt(
        text: String,
        detectedSpeakers: [String],
        characterLimit: Int
    ) -> String {
        let limit = max(8_000, characterLimit)
        let transcript: String
        if text.count <= limit {
            transcript = text
        } else {
            let headCount = limit * 3 / 4
            transcript = String(text.prefix(headCount))
                + "\n\n[…middle omitted because the transcript exceeded the model budget…]\n\n"
                + String(text.suffix(limit - headCount))
        }
        return """
        DETECTED SPEAKER TRACKS (\(detectedSpeakers.count)):
        \(detectedSpeakers.isEmpty ? "(none)" : detectedSpeakers.joined(separator: ", "))

        MEETING TRANSCRIPT AND NOTES:
        \(transcript)
        """
    }

    public static func parse(
        _ response: String,
        detectedSpeakers: [String],
        sourceRevision: String,
        model: String
    ) -> RecordingSummary? {
        let decoded = LocalModelStructuredOutput.jsonObjects(in: response)
            .compactMap { object -> Response? in
                guard let data = object.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(Response.self, from: data)
            }
            .first
        guard let overview = cleanOverview(
            decoded?.overview
                ?? LocalModelStructuredOutput.stringValue(
                    for: "overview",
                    in: response
                )
                ?? ""
        ) else { return nil }

        let participants = cleanList(
            decoded?.participants
                ?? LocalModelStructuredOutput.stringArray(
                    for: "participants",
                    in: response
                )
        )
        let resolvedParticipants = participants.isEmpty
            ? cleanList(detectedSpeakers)
            : participants
        return RecordingSummary(
            overview: overview,
            participantCount: Set(detectedSpeakers).count,
            participants: resolvedParticipants,
            topics: cleanList(
                decoded?.topics
                    ?? LocalModelStructuredOutput.stringArray(
                        for: "topics",
                        in: response
                    )
            ),
            decisions: cleanList(
                decoded?.decisions
                    ?? LocalModelStructuredOutput.stringArray(
                        for: "decisions",
                        in: response
                    )
            ),
            actionItems: cleanList(
                decoded?.actionItems
                    ?? LocalModelStructuredOutput.stringArray(
                        for: "action_items",
                        in: response
                    )
            ),
            sourceRevision: sourceRevision,
            model: model
        )
    }

    private static func cleanOverview(_ raw: String) -> String? {
        let value = raw.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 12 else { return nil }
        return String(value.prefix(1_200))
    }

    private static func cleanList(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { raw in
            let value = raw.replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  seen.insert(value.lowercased()).inserted
            else { return nil }
            return String(value.prefix(300))
        }
    }
}

/// Builds the same portable summary document for every Timeline item. Meeting
/// summaries retain their participant fields; notes, documents, and images
/// simply leave those fields empty while sharing overview/topics/outcomes.
public enum ContentSummaryGenerator {
    public static func systemPrompt(kind: String) -> String {
        if kind.localizedCaseInsensitiveContains("recording")
            || kind.localizedCaseInsensitiveContains("meeting") {
            return RecordingSummaryGenerator.systemPrompt
        }
        return """
        Summarize a private knowledge-base item faithfully and concisely.
        Return exactly one JSON object with this schema:
        {"overview":"two to four sentences","participants":[],"topics":["topic"],"decisions":["conclusion or decision"],"action_items":["action with owner and due date when stated"]}

        Requirements:
        - Explain what the item is and what it is about, including its main point.
        - Keep topics, conclusions, decisions, and action items short and specific.
        - Use an empty array when a category is not supported by the content.
        - Do not invent people, dates, facts, visual details, or outcomes.
        - Do not include Markdown or any text outside the JSON object.
        """
    }

    public static func userPrompt(
        title: String,
        kind: String,
        text: String,
        detectedSpeakers: [String],
        characterLimit: Int
    ) -> String {
        if kind.localizedCaseInsensitiveContains("recording")
            || kind.localizedCaseInsensitiveContains("meeting") {
            return RecordingSummaryGenerator.userPrompt(
                text: text,
                detectedSpeakers: detectedSpeakers,
                characterLimit: characterLimit
            )
        }
        let limit = max(8_000, characterLimit)
        let content: String
        if text.count <= limit {
            content = text
        } else {
            let headCount = limit * 3 / 4
            content = String(text.prefix(headCount))
                + "\n\n[…middle omitted because the item exceeded the model budget…]\n\n"
                + String(text.suffix(limit - headCount))
        }
        return """
        ITEM TYPE: \(kind)
        CURRENT TITLE: \(title)

        ITEM CONTENT, EXTRACTED TEXT, IMAGE DESCRIPTION, AND NOTES:
        \(content)
        """
    }

    public static func parse(
        _ response: String,
        detectedSpeakers: [String],
        sourceRevision: String,
        model: String
    ) -> RecordingSummary? {
        RecordingSummaryGenerator.parse(
            response,
            detectedSpeakers: detectedSpeakers,
            sourceRevision: sourceRevision,
            model: model
        )
    }
}
