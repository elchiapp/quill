import AppKit
import SwiftUI

@MainActor
final class DropsiftWindowController: NSWindowController {
    nonisolated static let styleMask: NSWindow.StyleMask = [
        .titled,
        .closable,
        .miniaturizable,
        .resizable,
    ]

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
            styleMask: Self.styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "DropSift"
        // Keep content below the unified toolbar. A full-size transparent
        // title bar can intermittently drop SwiftUI's safe-area inset when
        // child toolbars (such as Timeline search) are recomposed.
        window.titlebarAppearsTransparent = false
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
