import Foundation
import UserNotifications

/// Best-effort user-visible notification. osascript keeps us free of
/// UserNotifications entitlement requirements (which need an app bundle).
func notifyUser(title: String, body: String) {
    func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    let script = "display notification \(quoted(body)) with title \(quoted(title))"
    let task = Process()
    task.launchPath = "/usr/bin/osascript"
    task.arguments = ["-e", script]
    try? task.run()
}

final class MeetingNotificationController: NSObject, UNUserNotificationCenterDelegate,
    @unchecked Sendable {
    static let categoryID = "DROPSIFT_MEETING_DETECTED"
    static let startActionID = "DROPSIFT_START_RECORDING"
    static let dismissActionID = "DROPSIFT_NOT_NOW"

    @MainActor var onStartRecording: (() -> Void)?

    @MainActor
    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let start = UNNotificationAction(
            identifier: Self.startActionID,
            title: "Start Recording",
            options: [.foreground]
        )
        let dismiss = UNNotificationAction(
            identifier: Self.dismissActionID,
            title: "Not Now",
            options: []
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryID,
                actions: [start, dismiss],
                intentIdentifiers: [],
                options: []
            )
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @MainActor
    func proposeRecording(for meeting: DetectedMeeting) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting detected in \(meeting.appName)"
        content.body = meeting.isBrowser
            ? "This browser is using your microphone. Start a Dropsift recording?"
            : "\(meeting.appName) is using your microphone. Start a Dropsift recording?"
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        let request = UNNotificationRequest(
            identifier: "meeting-\(meeting.bundleID)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == Self.startActionID else { return }
        await MainActor.run { onStartRecording?() }
    }
}
