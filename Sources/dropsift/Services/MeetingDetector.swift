import AppKit
import CoreAudio
import Foundation

struct DetectedMeeting: Sendable, Equatable {
    let bundleID: String
    let appName: String
    let isBrowser: Bool
}

actor MeetingDetector {
    private var monitorTask: Task<Void, Never>?
    private var candidate: DetectedMeeting?
    private var candidateSince: Date?
    private var alreadySuggested = false

    func start(
        onDetected: @escaping @MainActor @Sendable (DetectedMeeting) -> Void
    ) {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll(onDetected: onDetected)
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        candidate = nil
        candidateSince = nil
        alreadySuggested = false
    }

    private func poll(
        onDetected: @escaping @MainActor @Sendable (DetectedMeeting) -> Void
    ) async {
        let current = Self.activeMeetingCandidate()
        guard let current else {
            candidate = nil
            candidateSince = nil
            alreadySuggested = false
            return
        }

        if candidate?.bundleID != current.bundleID {
            candidate = current
            candidateSince = Date()
            alreadySuggested = false
            return
        }
        guard !alreadySuggested, let candidateSince else { return }
        let requiredSeconds: TimeInterval = current.isBrowser ? 12 : 4
        guard Date().timeIntervalSince(candidateSince) >= requiredSeconds else { return }
        alreadySuggested = true
        await onDetected(current)
    }

    private nonisolated static func activeMeetingCandidate() -> DetectedMeeting? {
        let processes = audioProcessObjects()
        var browserCandidate: DetectedMeeting?
        for objectID in processes {
            guard readUInt32(
                objectID,
                selector: kAudioProcessPropertyIsRunningInput
            ) == 1 else { continue }
            guard let pid = readPID(objectID), pid != getpid() else { continue }
            let bundleID = readBundleID(objectID)
                ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                ?? ""
            guard !bundleID.isEmpty else { continue }
            let appName = NSRunningApplication(processIdentifier: pid)?.localizedName
                ?? friendlyName(for: bundleID)
            let normalized = bundleID.lowercased()
            if knownMeetingBundleFragments.contains(where: normalized.contains) {
                return DetectedMeeting(
                    bundleID: bundleID,
                    appName: appName,
                    isBrowser: false
                )
            }
            if browserBundleFragments.contains(where: normalized.contains) {
                browserCandidate = DetectedMeeting(
                    bundleID: bundleID,
                    appName: appName,
                    isBrowser: true
                )
            }
        }
        return browserCandidate
    }

    private nonisolated static let knownMeetingBundleFragments = [
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.cisco.webex",
        "com.apple.facetime",
        "com.tinyspeck.slackmacgap",
        "com.discord",
        "com.skype",
        "com.lark",
    ]

    private nonisolated static let browserBundleFragments = [
        "com.google.chrome",
        "com.apple.safari",
        "company.thebrowser.browser",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.brave.browser",
    ]

    private nonisolated static func friendlyName(for bundleID: String) -> String {
        let normalized = bundleID.lowercased()
        if normalized.contains("zoom") { return "Zoom" }
        if normalized.contains("teams") { return "Microsoft Teams" }
        if normalized.contains("webex") { return "Webex" }
        if normalized.contains("facetime") { return "FaceTime" }
        if normalized.contains("slack") { return "Slack" }
        if normalized.contains("chrome") { return "Google Chrome" }
        if normalized.contains("safari") { return "Safari" }
        return "another app"
    }

    private nonisolated static func audioProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr, size > 0 else { return [] }
        var values = [AudioObjectID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &values
        ) == noErr else { return [] }
        return values
    }

    private nonisolated static func readUInt32(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return value
    }

    private nonisolated static func readPID(_ objectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = pid_t()
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return value
    }

    private nonisolated static func readBundleID(_ objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
