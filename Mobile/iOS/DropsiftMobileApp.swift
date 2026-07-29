import SwiftUI

@main
struct DropsiftMobileApp: App {
    @StateObject private var model = MobileAppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MobileRootView(model: model)
                .onAppear { model.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        model.start()
                        model.reload()
                        model.processWatchInbox()
                    } else {
                        model.stop()
                    }
                }
        }
    }
}
