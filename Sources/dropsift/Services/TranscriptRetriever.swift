import Foundation

struct TranscriptChunk: Sendable {
    let recordingID: String
    let recordingTitle: String
    let startedAt: Date?
    let startMs: Int
    let endMs: Int
    let text: String
    let locator: String?

    var citation: String {
        "[\(recordingTitle) @ \(locator ?? TranscriptDocument.clock(startMs))]"
    }

    func source(number: Int) -> ChatSource {
        ChatSource(
            number: number,
            recordingID: recordingID,
            recordingTitle: recordingTitle,
            startMs: startMs,
            endMs: endMs,
            excerpt: text,
            knowledgeItemID: nil,
            locator: locator,
            page: nil
        )
    }
}

enum TranscriptRetriever {
    private static let stopWords: Set<String> = [
        "about", "after", "again", "also", "and", "are", "been", "before",
        "but", "can", "could", "did", "does", "for", "from", "had", "has",
        "have", "how", "into", "its", "just", "more", "not", "our", "out",
        "one", "said", "that", "the", "their", "them", "then", "there", "they", "this",
        "those", "was", "were", "what", "when", "where", "which", "who", "why",
        "will", "with", "would", "you", "your",
    ]
    private static let scopeRoutingWords: Set<String> = [
        "audio", "call", "conversation", "latest", "meeting", "newest", "recent",
        "recording", "summary", "summarize",
    ]

    /// A recording-scoped chat should not silently exclude an item that the user
    /// names in their question. Follow-up context is included in `query`, so a
    /// message such as “the latest one” still retains the original item name.
    static func resolvedScope(
        query: String,
        recordings: [RecordingItem],
        requestedScope: ChatScope
    ) -> ChatScope {
        guard requestedScope.kind == .recording,
              let recordingID = requestedScope.recordingID,
              let selected = recordings.first(where: { $0.id == recordingID })
        else {
            return requestedScope
        }

        let queryTerms = Set(tokenize(query)).subtracting(scopeRoutingWords)
        guard !queryTerms.isEmpty else { return requestedScope }

        func matches(in text: String) -> Set<String> {
            Set(tokenize(text)).intersection(queryTerms)
        }

        let selectedTitleMatches = matches(in: selected.title)
        let otherTitleMatches = recordings
            .filter { $0.id != recordingID }
            .map { matches(in: $0.title) }
            .max { $0.count < $1.count } ?? []

        if !otherTitleMatches.isEmpty,
           otherTitleMatches.count > selectedTitleMatches.count {
            return .all
        }

        // If the selected recording has no evidence for the question but another
        // recording does, search the library instead of feeding unrelated recent
        // excerpts to the model.
        func contentMatches(in recording: RecordingItem) -> Set<String> {
            let namedSpeakers = recording.speakerNames.values.joined(separator: " ")
            var found = matches(
                in: recording.title + " " + recording.notes + " " + namedSpeakers
            )
            guard found.count < queryTerms.count else { return found }
            for segment in recording.transcript?.segments ?? [] {
                found.formUnion(matches(in: segment.text))
                if found.count == queryTerms.count { break }
            }
            return found
        }

        let selectedMatches = contentMatches(in: selected)
        guard selectedMatches.isEmpty else { return requestedScope }
        let anotherRecordingMatches = recordings.lazy
            .filter { $0.id != recordingID }
            .contains { !contentMatches(in: $0).isEmpty }
        return anotherRecordingMatches ? .all : requestedScope
    }

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
        let segments = recording.transcript?.segments ?? []
        let groupSize = 8
        let overlap = 2
        var output: [TranscriptChunk] = []
        var index = 0
        while index < segments.count {
            let end = min(index + groupSize, segments.count)
            let slice = Array(segments[index..<end])
            let text = slice.map { segment in
                "\(recording.speakerName(for: segment.speaker)): \(segment.text)"
            }.joined(separator: "\n")
            output.append(
                TranscriptChunk(
                    recordingID: recording.id,
                    recordingTitle: recording.title,
                    startedAt: recording.startedAt,
                    startMs: slice.first?.startMs ?? 0,
                    endMs: slice.last?.endMs ?? 0,
                    text: text,
                    locator: nil
                )
            )
            if end == segments.count { break }
            index += groupSize - overlap
        }

        let notes = recording.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            output.append(
                TranscriptChunk(
                    recordingID: recording.id,
                    recordingTitle: recording.title,
                    startedAt: recording.startedAt,
                    startMs: 0,
                    endMs: 0,
                    text: "User notes:\n\(notes)",
                    locator: "Recording notes"
                )
            )
        }
        return output
    }

    private static func tokenize(_ text: String) -> [String] {
        let components = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        var expanded = components
        for index in 0..<(max(0, components.count - 1)) {
            let left = components[index]
            let right = components[index + 1]
            let leftIsLetters = left.unicodeScalars.allSatisfy(CharacterSet.letters.contains)
            let leftIsDigits = left.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains)
            let rightIsLetters = right.unicodeScalars.allSatisfy(CharacterSet.letters.contains)
            let rightIsDigits = right.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains)
            if (leftIsLetters && rightIsDigits) || (leftIsDigits && rightIsLetters) {
                expanded.append(left + right)
            }
        }
        return expanded.filter { $0.count > 2 && !stopWords.contains($0) }
    }
}
