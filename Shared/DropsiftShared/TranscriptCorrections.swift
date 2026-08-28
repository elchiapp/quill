import Foundation

/// Recording-scoped terminology aliases. The source transcript remains
/// untouched; every consumer gets the corrected view through this store.
public enum SharedTranscriptCorrectionStore {
    public static let filename = "terminology.json"

    public static func load(from directory: URL) -> [String: String] {
        guard let data = try? Data(
            contentsOf: directory.appendingPathComponent(filename)
        ), let mappings = try? JSONDecoder().decode(
            [String: String].self,
            from: data
        ) else { return [:] }
        return normalized(mappings)
    }

    public static func save(
        _ mappings: [String: String],
        to directory: URL
    ) throws {
        let cleaned = normalized(mappings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(cleaned).write(
            to: directory.appendingPathComponent(filename),
            options: .atomic
        )
    }

    public static func setting(
        source: String,
        replacement: String,
        in mappings: [String: String]
    ) -> [String: String] {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !replacement.isEmpty else { return normalized(mappings) }

        var updated = mappings.filter {
            $0.key.localizedCaseInsensitiveCompare(source) != .orderedSame
        }
        if source.localizedCaseInsensitiveCompare(replacement) != .orderedSame {
            updated[source] = replacement
        }
        return normalized(updated)
    }

    public static func apply(
        to text: String,
        mappings: [String: String]
    ) -> String {
        let mappings = normalized(mappings)
        guard !text.isEmpty, !mappings.isEmpty else { return text }

        let sources = mappings.keys.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }
        let alternatives = sources
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        let pattern = "(?<![\\p{L}\\p{N}_])(?:\(alternatives))(?![\\p{L}\\p{N}_])"
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return text }

        let lookup = Dictionary(
            mappings.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        let original = text as NSString
        let matches = expression.matches(
            in: text,
            range: NSRange(location: 0, length: original.length)
        )
        guard !matches.isEmpty else { return text }

        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            let source = original.substring(with: match.range).lowercased()
            guard let replacement = lookup[source] else { continue }
            result.replaceCharacters(in: match.range, with: replacement)
        }
        return result as String
    }

    public static func correctionReference(
        _ mappings: [String: String]
    ) -> String {
        let mappings = normalized(mappings)
        guard !mappings.isEmpty else { return "" }
        return mappings.keys.sorted(by: localizedSort).map {
            "\($0) = \(mappings[$0] ?? "")"
        }.joined(separator: "; ")
    }

    public static func apply(
        to summary: RecordingSummary,
        mappings: [String: String]
    ) -> RecordingSummary {
        RecordingSummary(
            overview: apply(to: summary.overview, mappings: mappings),
            participantCount: summary.participantCount,
            participants: summary.participants.map { apply(to: $0, mappings: mappings) },
            topics: summary.topics.map { apply(to: $0, mappings: mappings) },
            decisions: summary.decisions.map { apply(to: $0, mappings: mappings) },
            actionItems: summary.actionItems.map { apply(to: $0, mappings: mappings) },
            sourceRevision: summary.sourceRevision,
            generatedAt: summary.generatedAt,
            model: summary.model
        )
    }

    private static func normalized(
        _ mappings: [String: String]
    ) -> [String: String] {
        var output: [String: String] = [:]
        for (rawSource, rawReplacement) in mappings {
            let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = rawReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty, !replacement.isEmpty,
                  source.localizedCaseInsensitiveCompare(replacement) != .orderedSame
            else { continue }
            if let existing = output.keys.first(where: {
                $0.localizedCaseInsensitiveCompare(source) == .orderedSame
            }) {
                output.removeValue(forKey: existing)
            }
            output[source] = replacement
        }
        return output
    }

    private static func localizedSort(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}
