import AppKit
import SwiftUI

@MainActor
final class DropsiftWindowController: NSWindowController {
    init(model: AppModel) {
        let rootView = DropsiftRootView(model: model)
        let hostingController = NSHostingController(rootView: rootView)
        let visibleFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_720, height: 1_050)
        let preferredFrame = Self.preferredFrame(in: visibleFrame)
        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: preferredFrame.size
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Dropsift"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(
            width: min(1_400, visibleFrame.width),
            height: min(760, visibleFrame.height)
        )
        window.contentViewController = hostingController
        window.setFrameAutosaveName("DropsiftMainWindow")
        if Self.shouldExpand(window.frame, to: preferredFrame) {
            window.setFrame(preferredFrame, display: false)
        }
        super.init(window: window)
    }

    nonisolated static func preferredFrame(in visibleFrame: NSRect) -> NSRect {
        let width = min(1_720, visibleFrame.width)
        let height = min(1_050, visibleFrame.height)
        return NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        )
    }

    nonisolated static func shouldExpand(
        _ currentFrame: NSRect,
        to preferredFrame: NSRect
    ) -> Bool {
        currentFrame.width < preferredFrame.width
            || currentFrame.height < preferredFrame.height
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
