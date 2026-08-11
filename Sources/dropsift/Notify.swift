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
    static let detectedCategoryID = "DROPSIFT_MEETING_DETECTED"
    static let startActionID = "DROPSIFT_START_RECORDING"
    static let dismissActionID = "DROPSIFT_NOT_NOW"

    @MainActor var onStartRecording: ((DetectedMeeting) -> Void)?

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
                identifier: Self.detectedCategoryID,
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
        content.categoryIdentifier = Self.detectedCategoryID
        content.userInfo = [
            "bundleID": meeting.bundleID,
            "appName": meeting.appName,
            "isBrowser": meeting.isBrowser,
        ]
        let request = UNNotificationRequest(
            identifier: "meeting-\(meeting.bundleID)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    @MainActor
    func reportAutomaticallyStopped(for meeting: DetectedMeeting) {
        let content = UNMutableNotificationContent()
        content.title = "Recording stopped"
        content.body = "\(meeting.appName) stopped using the microphone, so Dropsift ended the meeting recording."
        let request = UNNotificationRequest(
            identifier: "meeting-stopped-\(meeting.bundleID)-\(Date().timeIntervalSince1970)",
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
        switch response.actionIdentifier {
        case Self.startActionID:
            guard let meeting = Self.meeting(
                from: response.notification.request.content.userInfo
            ) else { return }
            await MainActor.run { onStartRecording?(meeting) }
        default:
            break
        }
    }

    private static func meeting(
        from userInfo: [AnyHashable: Any]
    ) -> DetectedMeeting? {
        guard let bundleID = userInfo["bundleID"] as? String,
              let appName = userInfo["appName"] as? String,
              let isBrowser = userInfo["isBrowser"] as? Bool
        else { return nil }
        return DetectedMeeting(
            bundleID: bundleID,
            appName: appName,
            isBrowser: isBrowser
        )
    }
}
