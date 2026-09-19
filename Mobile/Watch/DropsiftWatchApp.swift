import SwiftUI

@main
struct DropsiftWatchApp: App {
    @StateObject private var recorder = WatchVoiceRecorder()
    @StateObject private var bridge = WatchPhoneBridge()

    var body: some Scene {
        WindowGroup {
            WatchRootView(recorder: recorder, bridge: bridge)
        }
    }
}
