import Foundation

/// Per-recording display names for stable transcript speaker identifiers.
/// Keeping this separate from `transcript.json` means a later transcription or
/// resumed recording cannot overwrite names the user assigned.
public enum SharedSpeakerNameStore {
    public static let filename = "speakers.json"

    public static func load(from recordingDirectory: URL) -> [String: String] {
        let url = recordingDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let names = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return sanitized(names)
    }

    public static func save(
        _ names: [String: String],
        to recordingDirectory: URL
    ) throws {
        let cleaned = sanitized(names)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(cleaned).write(
            to: recordingDirectory.appendingPathComponent(filename),
            options: .atomic
        )
    }

    public static func displayName(
        for speakerID: String,
        names: [String: String]
    ) -> String {
        if let name = names[speakerID]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        if speakerID == "me" { return "You" }
        if speakerID == "them" { return "Them" }
        if speakerID.hasPrefix("speaker_"),
           let number = speakerID.split(separator: "_").last {
            return "Speaker \(number)"
        }
        return speakerID.replacingOccurrences(of: "_", with: " ").capitalized
    }

    public static func sanitized(_ names: [String: String]) -> [String: String] {
        names.reduce(into: [:]) { output, entry in
            let speakerID = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !speakerID.isEmpty, !name.isEmpty else { return }
            output[speakerID] = name
        }
    }
}
