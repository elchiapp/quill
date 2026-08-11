import Foundation

/// Removes speaker playback that leaks into the microphone track and is then
/// transcribed a second time as `me`. System-track segments always win because
/// they are the clean source and retain remote-speaker diarization.
enum TranscriptEchoDeduplicator {
    private static let timingToleranceMs = 2_200

    static func removeEchoes(
        from segments: [TranscriptDocument.Segment]
    ) -> [TranscriptDocument.Segment] {
        let remoteSegments = segments.filter { $0.speaker != "me" }
        guard !remoteSegments.isEmpty else { return segments }

        return segments.filter { segment in
            guard segment.speaker == "me" else { return true }
            let candidates = remoteSegments.filter {
                isNearInTime(segment, $0)
            }
            guard !candidates.isEmpty else { return true }
            return !isLikelyEcho(segment, candidates: candidates)
        }
    }

    private static func isNearInTime(
        _ microphone: TranscriptDocument.Segment,
        _ remote: TranscriptDocument.Segment
    ) -> Bool {
        let gap = max(
            0,
            max(microphone.startMs, remote.startMs)
                - min(microphone.endMs, remote.endMs)
        )
        return gap <= timingToleranceMs
    }

    private static func isLikelyEcho(
        _ microphone: TranscriptDocument.Segment,
        candidates: [TranscriptDocument.Segment]
    ) -> Bool {
        let microphoneCharacters = normalizedCharacters(microphone.text)
        guard microphoneCharacters.count >= 2 else { return false }

        let candidateCharacters = candidates.map {
            normalizedCharacters($0.text)
        }
        if candidateCharacters.contains(where: { $0 == microphoneCharacters }) {
            return true
        }

        let bestIndividualSimilarity = candidateCharacters
            .map { editSimilarity(microphoneCharacters, $0) }
            .max() ?? 0
        if microphoneCharacters.count < 12 {
            return bestIndividualSimilarity >= 0.9
        }
        if bestIndividualSimilarity >= 0.76 {
            return true
        }

        let combinedText = candidates
            .sorted { $0.startMs < $1.startMs }
            .map(\.text)
            .joined(separator: " ")
        let combinedCharacters = normalizedCharacters(combinedText)
        let characterCoverage = ngramCoverage(
            needle: microphoneCharacters,
            haystack: combinedCharacters,
            size: 3
        )
        let wordCoverage = multisetCoverage(
            needle: normalizedWords(microphone.text),
            haystack: normalizedWords(combinedText)
        )
        return characterCoverage >= 0.72 && wordCoverage >= 0.72
    }

    private static func normalizedCharacters(_ text: String) -> [Character] {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let scalars = folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        return Array(String(String.UnicodeScalarView(scalars)))
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
    }

    private static func editSimilarity(
        _ lhs: [Character],
        _ rhs: [Character]
    ) -> Double {
        let maximumCount = max(lhs.count, rhs.count)
        guard maximumCount > 0 else { return 1 }
        var previous = Array(0...rhs.count)
        for (leftIndex, left) in lhs.enumerated() {
            var current = Array(repeating: 0, count: rhs.count + 1)
            current[0] = leftIndex + 1
            for (rightIndex, right) in rhs.enumerated() {
                current[rightIndex + 1] = min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (left == right ? 0 : 1)
                )
            }
            previous = current
        }
        return 1 - Double(previous[rhs.count]) / Double(maximumCount)
    }

    private static func ngramCoverage(
        needle: [Character],
        haystack: [Character],
        size: Int
    ) -> Double {
        guard needle.count >= size, haystack.count >= size else { return 0 }
        let needleNgrams = ngrams(in: needle, size: size)
        let haystackNgrams = Set(ngrams(in: haystack, size: size))
        let matched = needleNgrams.reduce(into: 0) {
            if haystackNgrams.contains($1) { $0 += 1 }
        }
        return Double(matched) / Double(needleNgrams.count)
    }

    private static func ngrams(
        in characters: [Character],
        size: Int
    ) -> [String] {
        guard characters.count >= size else { return [] }
        return (0...(characters.count - size)).map {
            String(characters[$0..<($0 + size)])
        }
    }

    private static func multisetCoverage(
        needle: [String],
        haystack: [String]
    ) -> Double {
        guard !needle.isEmpty else { return 0 }
        var frequencies = Dictionary(
            haystack.map { ($0, 1) },
            uniquingKeysWith: +
        )
        var matched = 0
        for word in needle where frequencies[word, default: 0] > 0 {
            matched += 1
            frequencies[word, default: 0] -= 1
        }
        return Double(matched) / Double(needle.count)
    }
}
