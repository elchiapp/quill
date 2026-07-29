import Foundation
import NaturalLanguage

/// FluidAudio's Parakeet v3 automatically recognizes supported languages but
/// does not expose the chosen language in its batch result. Record a
/// best-effort dominant language from the finished transcript so the UI and
/// exported transcript can show what Quill heard.
enum TranscriptLanguageDetector {
    private static let supportedCodes: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de",
        "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "ru",
        "sk", "sl", "es", "sv", "uk",
    ]

    static func detect(in segments: [TranscriptDocument.Segment]) -> String? {
        let text = segments.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 20 else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard
            let language = recognizer.dominantLanguage,
            supportedCodes.contains(language.rawValue),
            (recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0) >= 0.5
        else {
            return nil
        }
        return language.rawValue
    }
}
