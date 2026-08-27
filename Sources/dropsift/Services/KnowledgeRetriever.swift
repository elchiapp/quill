import DropsiftShared
import Foundation

struct KnowledgeChunk: Sendable {
    let itemID: UUID
    let itemTitle: String
    let kind: KnowledgeItemKind
    let createdAt: Date
    let text: String
    let locator: String
    let page: Int?

    func source(number: Int) -> ChatSource {
        ChatSource(
            number: number,
            recordingID: "",
            recordingTitle: itemTitle,
            startMs: 0,
            endMs: 0,
            excerpt: text,
            knowledgeItemID: itemID,
            locator: locator,
            page: page
        )
    }
}

enum RetrievedContext: Sendable {
    case transcript(TranscriptChunk)
    case knowledge(KnowledgeChunk)

    var title: String {
        switch self {
        case .transcript(let chunk): chunk.recordingTitle
        case .knowledge(let chunk): chunk.itemTitle
        }
    }

    var locator: String {
        switch self {
        case .transcript(let chunk):
            chunk.locator ?? TranscriptDocument.clock(chunk.startMs)
        case .knowledge(let chunk): chunk.locator
        }
    }

    var text: String {
        switch self {
        case .transcript(let chunk): chunk.text
        case .knowledge(let chunk): chunk.text
        }
    }

    func source(number: Int) -> ChatSource {
        switch self {
        case .transcript(let chunk): chunk.source(number: number)
        case .knowledge(let chunk): chunk.source(number: number)
        }
    }

    static func interleave(
        transcripts: [TranscriptChunk],
        knowledge: [KnowledgeChunk],
        limit: Int,
        characterBudget: Int
    ) -> [RetrievedContext] {
        var output: [RetrievedContext] = []
        var transcriptIndex = 0
        var knowledgeIndex = 0
        var characters = 0
        while output.count < limit
            && (transcriptIndex < transcripts.count || knowledgeIndex < knowledge.count) {
            let next: RetrievedContext
            if knowledgeIndex < knowledge.count
                && (output.count.isMultiple(of: 2) || transcriptIndex >= transcripts.count) {
                next = .knowledge(knowledge[knowledgeIndex])
                knowledgeIndex += 1
            } else if transcriptIndex < transcripts.count {
                next = .transcript(transcripts[transcriptIndex])
                transcriptIndex += 1
            } else {
                next = .knowledge(knowledge[knowledgeIndex])
                knowledgeIndex += 1
            }
            let nextSize = next.text.count + next.title.count + next.locator.count
            if characters + nextSize > characterBudget { break }
            output.append(next)
            characters += nextSize
        }
        return output
    }
}

enum KnowledgeRetriever {
    private static let stopWords: Set<String> = [
        "about", "after", "again", "also", "and", "are", "been", "before",
        "but", "can", "could", "did", "does", "for", "from", "had", "has",
        "have", "how", "into", "its", "just", "more", "not", "our", "out",
        "said", "that", "the", "their", "them", "then", "there", "they", "this",
        "those", "was", "were", "what", "when", "where", "which", "who", "why",
        "will", "with", "would", "you", "your",
    ]

    static func retrieve(
        query: String,
        items: [KnowledgeItem],
        limit: Int = 10,
        characterBudget: Int = 16_000
    ) -> [KnowledgeChunk] {
        let chunks = items.flatMap(chunks(from:))
        guard !chunks.isEmpty else { return [] }

        let terms = tokenize(query)
        var documentFrequency: [String: Int] = [:]
        let tokens = chunks.map { chunk -> [String] in
            let value = tokenize(chunk.itemTitle + " " + chunk.text)
            for term in Set(value) {
                documentFrequency[term, default: 0] += 1
            }
            return value
        }
        let count = Double(chunks.count)
        let ranked = zip(chunks.indices, chunks).map { index, chunk in
            let frequencies = Dictionary(tokens[index].map { ($0, 1) }, uniquingKeysWith: +)
            let relevance = terms.reduce(0.0) { partial, term in
                let frequency = Double(frequencies[term, default: 0])
                let documents = Double(documentFrequency[term, default: 0])
                return partial + frequency * (log((count + 1) / (documents + 1)) + 1)
            }
            let recency = max(
                0,
                1 - Date().timeIntervalSince(chunk.createdAt) / (86_400 * 365)
            )
            return (chunk, relevance + recency * 0.05)
        }
        .sorted { $0.1 > $1.1 }

        let candidates = (ranked.first?.1 ?? 0) > 0.1
            ? ranked.map(\.0)
            : chunks.sorted { $0.createdAt > $1.createdAt }
        var output: [KnowledgeChunk] = []
        var characters = 0
        for chunk in candidates {
            let size = chunk.text.count + chunk.itemTitle.count + chunk.locator.count
            guard output.count < limit, characters + size <= characterBudget else { break }
            output.append(chunk)
            characters += size
        }
        return output
    }

    private static func chunks(from item: KnowledgeItem) -> [KnowledgeChunk] {
        var output: [KnowledgeChunk] = []
        if let summary = item.summary {
            output.append(
                KnowledgeChunk(
                    itemID: item.id,
                    itemTitle: item.title,
                    kind: item.kind,
                    createdAt: item.createdAt,
                    text: summaryText(summary),
                    locator: "Summary",
                    page: nil
                )
            )
        }
        var blocks = item.blocks
        if item.kind == .note {
            blocks = textBlocks(item.content, locator: "Note")
        }
        if !item.additionalNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks += textBlocks(item.additionalNotes, locator: "Notes")
        }
        output += blocks.map {
            KnowledgeChunk(
                itemID: item.id,
                itemTitle: item.title,
                kind: item.kind,
                createdAt: item.createdAt,
                text: $0.text,
                locator: $0.locator,
                page: $0.page
            )
        }
        return output
    }

    private static func summaryText(_ summary: RecordingSummary) -> String {
        var sections = [summary.overview]
        if !summary.topics.isEmpty {
            sections.append("Topics: " + summary.topics.joined(separator: "; "))
        }
        if !summary.decisions.isEmpty {
            sections.append(
                "Conclusions and decisions: "
                    + summary.decisions.joined(separator: "; ")
            )
        }
        if !summary.actionItems.isEmpty {
            sections.append(
                "Action items: " + summary.actionItems.joined(separator: "; ")
            )
        }
        return sections.joined(separator: "\n")
    }

    private static func textBlocks(_ text: String, locator: String) -> [KnowledgeBlock] {
        var output: [KnowledgeBlock] = []
        var remaining = text[...]
        var part = 1
        while !remaining.isEmpty {
            let end = remaining.index(
                remaining.startIndex,
                offsetBy: min(3_500, remaining.count)
            )
            let value = String(remaining[..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                output.append(
                    KnowledgeBlock(
                        text: value,
                        locator: part == 1 ? locator : "\(locator) · Part \(part)"
                    )
                )
            }
            remaining = remaining[end...]
            part += 1
        }
        return output
    }

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) }
    }
}
