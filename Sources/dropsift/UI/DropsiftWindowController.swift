import AppKit
import SwiftUI

@MainActor
final class DropsiftWindowController: NSWindowController {
    init(model: AppModel) {
        let rootView = DropsiftRootView(model: model)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Dropsift"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 1_050, height: 650)
        window.contentViewController = hostingController
        window.center()
        window.setFrameAutosaveName("DropsiftMainWindow")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
