import Foundation

/// Creates useful titles immediately, without requiring a model download or
/// sending library contents anywhere. The marker files let titles evolve as
/// more notes/transcript text arrive while preserving anything renamed by a
/// person.
public enum ContentTitleGenerator {
    public static let manualMarkerFilename = ".title-manual"
    public static let generatedMarkerFilename = ".title-generated"

    public static func title(
        from sources: [String],
        fallback: String
    ) -> String {
        for source in sources where !source.isEmpty {
            let lines = source
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: .newlines)

            if let heading = lines.first(where: isMarkdownHeading),
               let candidate = candidate(from: heading, allowShort: true) {
                return candidate
            }
            let candidates = lines.enumerated().compactMap { index, line in
                candidate(from: line, allowShort: false).map {
                    (
                        value: $0,
                        score: candidateScore(
                            raw: line,
                            value: $0,
                            lineIndex: index
                        )
                    )
                }
            }
            if let best = candidates.max(by: { $0.score < $1.score }) {
                return best.value
            }
        }

        let cleanedFallback = clean(fallback)
        return cleanedFallback.isEmpty ? "Untitled item" : limit(cleanedFallback)
    }

    public static func mayReplaceTitle(
        _ existingTitle: String?,
        in directory: URL
    ) -> Bool {
        let fileManager = FileManager.default
        if fileManager.fileExists(
            atPath: directory.appendingPathComponent(manualMarkerFilename).path
        ) {
            return false
        }
        if fileManager.fileExists(
            atPath: directory.appendingPathComponent(generatedMarkerFilename).path
        ) {
            return true
        }
        guard let existingTitle else { return true }
        return isAutomaticPlaceholder(existingTitle)
    }

    public static func markGenerated(in directory: URL) throws {
        let marker = directory.appendingPathComponent(generatedMarkerFilename)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        try Data("Generated locally from item contents.\n".utf8)
            .write(to: marker, options: .atomic)
    }

    public static func markManual(in directory: URL) throws {
        let marker = directory.appendingPathComponent(manualMarkerFilename)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        try Data("User-edited title.\n".utf8).write(to: marker, options: .atomic)
    }

    public static func isAutomaticPlaceholder(_ title: String) -> Bool {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return true }

        let exact = [
            "recording", "meeting", "voice message", "watch voice message",
            "apple watch voice message", "note", "document", "image", "audio",
            "untitled item", "untitled note", "untitled document", "untitled image",
        ]
        if exact.contains(normalized) { return true }

        let prefixes = [
            "meeting ·", "voice message ·", "watch voice ·", "recording ",
            "untitled ",
        ]
        if prefixes.contains(where: normalized.hasPrefix) { return true }

        return normalized.range(
            of: #"^\d{4}\.\d{2}\.\d{2}-\d{4,6}(?:-.+)?$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isMarkdownHeading(_ line: String) -> Bool {
        line.range(
            of: #"^\s{0,3}#{1,6}\s+\S"#,
            options: .regularExpression
        ) != nil
    }

    private static func candidate(
        from line: String,
        allowShort: Bool
    ) -> String? {
        let value = clean(line)
        guard !value.isEmpty, !isAutomaticPlaceholder(value) else { return nil }

        let lowercased = value.lowercased()
        let conversationalFillers: Set<String> = [
            "yeah", "yes", "no", "okay", "ok", "right", "thanks",
            "thank you", "hello", "hi", "hey", "tutto bene", "va bene",
            "sì", "si", "ciao", "grazie", "perfetto", "buongiorno",
        ]
        guard !conversationalFillers.contains(lowercased) else { return nil }

        let meaningfulCharacters = value.unicodeScalars.reduce(into: 0) {
            if CharacterSet.alphanumerics.contains($1) { $0 += 1 }
        }
        guard meaningfulCharacters >= (allowShort ? 3 : 5) else { return nil }
        return limit(value)
    }

    private static func candidateScore(
        raw: String,
        value: String,
        lineIndex: Int
    ) -> Int {
        let words = value.split(whereSeparator: \.isWhitespace)
        let lowercased = value.lowercased()
        let containsIdentifier = value.range(
            of: #"\b(?=[A-Za-z0-9]*[A-Za-z])(?=[A-Za-z0-9]*\d)[A-Za-z0-9]{3,}\b"#,
            options: .regularExpression
        ) != nil
        let containsAcronym = value.range(
            of: #"\b[A-Z]{2,8}\b"#,
            options: .regularExpression
        ) != nil
        let genericOpeners = [
            "i ", "we ", "you ", "it ", "this ", "that ", "there ",
            "things ", "maybe ", "so ", "well ", "okay ", "ok ",
            "yeah ", "yes ", "no ", "um ", "uh ", "allora ",
            "quindi ", "diciamo ", "praticamente ", "basically ",
        ]

        var score = min(words.count, 14) * 3
        score += min(value.count, 72) / 8
        if (4 ... 12).contains(words.count) { score += 8 }
        if words.count <= 2 { score -= 16 }
        if containsIdentifier { score += 18 }
        if containsAcronym { score += 12 }
        score += min(
            words.filter { $0.count >= 7 }.count * 2,
            10
        )
        if genericOpeners.contains(where: lowercased.hasPrefix),
           !containsIdentifier,
           !containsAcronym {
            score -= 18
        }
        if raw.contains("?") { score -= 3 }
        score -= min(lineIndex, 24)
        return score
    }

    private static func clean(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacements: [(String, String)] = [
            (#"!\[([^\]]*)\]\([^)]+\)"#, "$1"),
            (#"\[([^\]]+)\]\([^)]+\)"#, "$1"),
            (#"<[^>]+>"#, " "),
            (#"^\s{0,3}#{1,6}\s+"#, ""),
            (#"^\s*(?:[-*+]|\d+[.)])\s+"#, ""),
            (#"^\s*\[[ xX]\]\s+"#, ""),
            (#"^\s*>\s*"#, ""),
            (#"^\s*\[(?:\d+:)?\d{1,2}:\d{2}\]\s*"#, ""),
            (#"^[\p{L}\p{N}][\p{L}\p{N} _-]{0,24}:\s+"#, ""),
            (#"(?i)^(?:(?:okay|ok|well|so|um+|uh+|yeah|thanks|thank\s+you|hey|hello|hi|right)[\s,.:;-]+)+"#, ""),
            (#"`{1,3}"#, ""),
            (#"[*_~]+"#, ""),
            (#"\s+"#, " "),
        ]
        for (pattern, replacement) in replacements {
            value = value.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        if let sentenceEnd = value.range(
            of: #"[.!?…。！？](?:\s|$)"#,
            options: .regularExpression
        ) {
            value = String(value[..<sentenceEnd.lowerBound])
        }
        return value.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "—–-:;,.!?…"))
        )
    }

    private static func limit(_ value: String) -> String {
        let words = value.split(whereSeparator: \.isWhitespace)
        var result = words.prefix(10).joined(separator: " ")
        if result.count > 72 {
            result = String(result.prefix(72))
            if let lastSpace = result.lastIndex(of: " "), lastSpace != result.startIndex {
                result = String(result[..<lastSpace])
            }
        }
        return result.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "—–-:;,.!?…"))
        )
    }
}
