import Foundation

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
        return try? decoder.decode(ContentPresentation.self, from: data)
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
    Return exactly one JSON object with this schema:
    {"title":"specific title","description":"one or two concise sentences"}

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
        guard let opening = response.firstIndex(of: "{"),
              let closing = response.lastIndex(of: "}"),
              opening <= closing,
              let data = String(response[opening ... closing]).data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let title = cleanTitle(decoded.title),
              let description = cleanDescription(decoded.description)
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
              !generic.contains(value.lowercased())
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
        guard value.count >= 12 else { return nil }
        if value.count > 280 {
            let prefix = String(value.prefix(277))
            let boundary = prefix.lastIndex(of: " ") ?? prefix.endIndex
            value = String(prefix[..<boundary]) + "…"
        }
        return value
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
