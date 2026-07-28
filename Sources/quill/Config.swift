import Foundation

/// Optional user config at ~/.config/quill/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": { "enabled": true, "engine": "parakeet" },
///       "diarization": { "enabled": true, "engine": "offline-vbx" },
///       "mic_voice_processing": true,
///       "on_stop": "my-hook"
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// iCloud Drive when available > ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the transcript is written, or right
/// after recording when transcription is disabled.
enum Config {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill/config.json")

    static let localRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    static let iCloudDriveRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)

    /// Completed recordings live in a normal iCloud Drive folder. This keeps
    /// the storage transparent in Finder and works without App Store
    /// container entitlements. Macs without iCloud Drive fall back locally.
    static var defaultRoot: URL {
        if FileManager.default.fileExists(atPath: iCloudDriveRoot.path) {
            return iCloudDriveRoot
                .appendingPathComponent("Quill", isDirectory: true)
                .appendingPathComponent("Recordings", isDirectory: true)
        }
        return localRoot
    }

    static var appDataRoot: URL {
        defaultRoot.deletingLastPathComponent()
    }

    /// Large inference weights stay local and disposable rather than syncing
    /// through iCloud with the user's recordings and chat history.
    static let modelCacheRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/Quill/Models", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        transcription()?["enabled"] as? Bool ?? true
    }

    /// Configured engine name. Only "parakeet" ships today; the coordinator
    /// warns and falls back for anything else.
    static func transcriptionEngine() -> String {
        transcription()?["engine"] as? String ?? "parakeet"
    }

    private static func transcription() -> [String: Any]? {
        load()?["transcription"] as? [String: Any]
    }

    /// Remote/system audio is diarized by default. The microphone remains a
    /// separate, trusted "me" channel and does not need speaker detection.
    static func diarizationEnabled() -> Bool {
        diarization()?["enabled"] as? Bool ?? true
    }

    static func diarizationEngine() -> String {
        diarization()?["engine"] as? String ?? "offline-vbx"
    }

    private static func diarization() -> [String: Any]? {
        load()?["diarization"] as? [String: Any]
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? false
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
            ))
            return nil
        }
        return json
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}
