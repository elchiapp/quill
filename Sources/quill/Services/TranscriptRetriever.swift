import Foundation

struct TranscriptChunk: Sendable {
    let recordingID: String
    let recordingTitle: String
    let startedAt: Date?
    let startMs: Int
    let endMs: Int
    let text: String

    var citation: String {
        "[\(recordingTitle) @ \(TranscriptDocument.clock(startMs))]"
    }

    func source(number: Int) -> ChatSource {
        ChatSource(
            number: number,
            recordingID: recordingID,
            recordingTitle: recordingTitle,
            startMs: startMs,
            endMs: endMs,
            excerpt: text
        )
    }
}

enum TranscriptRetriever {
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
        recordings: [RecordingItem],
        scope: ChatScope,
        limit: Int = 10,
        characterBudget: Int = 16_000
    ) -> [TranscriptChunk] {
        let scoped = recordings.filter { recording in
            scope.kind == .allRecordings || scope.recordingID == recording.id
        }
        let allChunks = scoped.flatMap(chunks(from:))
        guard !allChunks.isEmpty else { return [] }

        let terms = tokenize(query)
        var documentFrequency: [String: Int] = [:]
        let chunkTokens = allChunks.map { chunk -> [String] in
            let tokens = tokenize(chunk.recordingTitle + " " + chunk.text)
            for term in Set(tokens) {
                documentFrequency[term, default: 0] += 1
            }
            return tokens
        }

        let count = Double(allChunks.count)
        let ranked = zip(allChunks.indices, allChunks).map { index, chunk in
            let tokens = chunkTokens[index]
            let frequencies = Dictionary(tokens.map { ($0, 1) }, uniquingKeysWith: +)
            let score = terms.reduce(0.0) { partial, term in
                let frequency = Double(frequencies[term, default: 0])
                let documents = Double(documentFrequency[term, default: 0])
                let inverseFrequency = log((count + 1) / (documents + 1)) + 1
                return partial + frequency * inverseFrequency
            }
            let recency = chunk.startedAt.map {
                max(0, 1 - Date().timeIntervalSince($0) / (86400 * 365))
            } ?? 0
            return (chunk: chunk, score: score + recency * 0.05)
        }
        .sorted { $0.score > $1.score }

        let hasRelevantMatch = ranked.first.map { $0.score > 0.1 } ?? false
        let candidates = hasRelevantMatch
            ? ranked.map(\.chunk)
            : allChunks.sorted {
                ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast)
            }

        var result: [TranscriptChunk] = []
        var characters = 0
        for chunk in candidates {
            let nextSize = chunk.text.count + chunk.citation.count
            guard result.count < limit, characters + nextSize <= characterBudget else { break }
            result.append(chunk)
            characters += nextSize
        }
        return result
    }

    private static func chunks(from recording: RecordingItem) -> [TranscriptChunk] {
        guard let segments = recording.transcript?.segments, !segments.isEmpty else {
            return []
        }

        let groupSize = 8
        let overlap = 2
        var output: [TranscriptChunk] = []
        var index = 0
        while index < segments.count {
            let end = min(index + groupSize, segments.count)
            let slice = Array(segments[index..<end])
            let text = slice.map { segment in
                "\(segment.speaker): \(segment.text)"
            }.joined(separator: "\n")
            output.append(
                TranscriptChunk(
                    recordingID: recording.id,
                    recordingTitle: recording.title,
                    startedAt: recording.startedAt,
                    startMs: slice.first?.startMs ?? 0,
                    endMs: slice.last?.endMs ?? 0,
                    text: text
                )
            )
            if end == segments.count { break }
            index += groupSize - overlap
        }
        return output
    }

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) }
    }
}
