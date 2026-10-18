import AppKit
import CoreAudio
import Foundation

struct DetectedMeeting: Sendable, Equatable {
    let bundleID: String
    let appName: String
    let isBrowser: Bool
}

enum MeetingDetectionEvent: Sendable, Equatable {
    case detected(DetectedMeeting)
    case ended(DetectedMeeting)
}

struct MeetingDetectionTracker: Sendable {
    static let endDelay: TimeInterval = 10

    private var candidate: DetectedMeeting?
    private var candidateSince: Date?
    private var missingSince: Date?
    private var alreadySuggested = false

    var nextCheckDate: Date? {
        if let missingSince { return missingSince.addingTimeInterval(Self.endDelay) }
        guard !alreadySuggested, let candidate, let candidateSince else { return nil }
        return candidateSince.addingTimeInterval(candidate.isBrowser ? 12 : 4)
    }

    mutating func update(
        current: DetectedMeeting?,
        now: Date = Date()
    ) -> MeetingDetectionEvent? {
        guard let current else {
            guard let candidate else { return nil }

            // A microphone blip that ended before it met the detection threshold
            // was never considered a meeting, so it must not produce an end event.
            guard alreadySuggested else {
                reset()
                return nil
            }

            if missingSince == nil {
                missingSince = now
                return nil
            }
            guard let missingSince,
                now.timeIntervalSince(missingSince) >= Self.endDelay
            else { return nil }

            reset()
            return .ended(candidate)
        }

        missingSince = nil
        if candidate?.bundleID != current.bundleID {
            candidate = current
            candidateSince = now
            alreadySuggested = false
            return nil
        }

        candidate = current
        guard !alreadySuggested, let candidateSince else { return nil }
        let requiredSeconds: TimeInterval = current.isBrowser ? 12 : 4
        guard now.timeIntervalSince(candidateSince) >= requiredSeconds else { return nil }
        alreadySuggested = true
        return .detected(current)
    }

    mutating func reset() {
        candidate = nil
        candidateSince = nil
        missingSince = nil
        alreadySuggested = false
    }
}

actor MeetingDetector {
    private var confirmationTask: Task<Void, Never>?
    private var tracker = MeetingDetectionTracker()
    private var running = false
    private var processListListener: AudioObjectPropertyListenerBlock?
    private var inputListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private let listenerQueue = DispatchQueue(label: "dropsift.meeting-audio-events", qos: .utility)
    private var onDetected: (@MainActor @Sendable (DetectedMeeting) -> Void)?
    private var onEnded: (@MainActor @Sendable (DetectedMeeting) -> Void)?

    func start(
        onDetected: @escaping @MainActor @Sendable (DetectedMeeting) -> Void,
        onEnded: @escaping @MainActor @Sendable (DetectedMeeting) -> Void
    ) async {
        guard !running else { return }
        running = true
        self.onDetected = onDetected
        self.onEnded = onEnded
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { await self?.audioChanged() }
        }
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, listener
        ) == noErr {
            processListListener = listener
        }
        await audioChanged()
    }

    func stop() {
        running = false
        confirmationTask?.cancel()
        confirmationTask = nil
        if let processListListener {
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address,
                listenerQueue, processListListener
            )
        }
        processListListener = nil
        for (objectID, listener) in inputListeners {
            var address = Self.address(kAudioProcessPropertyIsRunningInput)
            AudioObjectRemovePropertyListenerBlock(objectID, &address, listenerQueue, listener)
        }
        inputListeners.removeAll()
        onDetected = nil
        onEnded = nil
        tracker.reset()
    }

    private func audioChanged() async {
        guard running else { return }
        updateInputListeners()
        let event = tracker.update(current: Self.activeMeetingCandidate())
        confirmationTask?.cancel()
        confirmationTask = nil
        // A single deadline confirms a meeting start or its ten-second end delay.
        // A stable meeting or no candidate leaves no scheduled work.
        if let deadline = tracker.nextCheckDate {
            let delay = max(0.01, deadline.timeIntervalSinceNow)
            confirmationTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
                await self?.audioChanged()
            }
        }
        switch event {
        case .detected(let meeting):
            await onDetected?(meeting)
        case .ended(let meeting):
            await onEnded?(meeting)
        case nil:
            break
        }
    }

    private func updateInputListeners() {
        let objects = Set(Self.audioProcessObjects().filter { Self.readPID($0) != getpid() })
        for objectID in inputListeners.keys where !objects.contains(objectID) {
            if let listener = inputListeners.removeValue(forKey: objectID) {
                var address = Self.address(kAudioProcessPropertyIsRunningInput)
                AudioObjectRemovePropertyListenerBlock(
                    objectID, &address, listenerQueue, listener
                )
            }
        }
        for objectID in objects where inputListeners[objectID] == nil {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { await self?.audioChanged() }
            }
            var address = Self.address(kAudioProcessPropertyIsRunningInput)
            if AudioObjectAddPropertyListenerBlock(
                objectID, &address, listenerQueue, listener
            ) == noErr {
                inputListeners[objectID] = listener
            }
        }
    }

    private nonisolated static func address(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
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
