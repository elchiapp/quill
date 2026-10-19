import AppKit
import DropsiftShared
import SwiftUI
import Testing
@testable import dropsift

@Test @MainActor func desktopAppearanceUpdatesNativeControlsAndRestoresSystemFollowing() {
    let app = NSApplication.shared
    let original = app.appearance
    defer { app.appearance = original }
    DesktopAppearance.apply(.dark)
    #expect(app.appearance?.name == .darkAqua)
    DesktopAppearance.apply(.light)
    #expect(app.appearance?.name == .aqua)
    DesktopAppearance.apply(.system)
    #expect(app.appearance == nil)
}

@Test @MainActor func markdownTextRemainsReadableInLightAndDarkAppearances() throws {
    let attributed = MarkdownRichTextCodec.attributedString(from: "# Meeting\nReview **offline** notes and `code`.")
    let label = try #require(attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        let appearance = try #require(NSAppearance(named: name))
        appearance.performAsCurrentDrawingAppearance {
            let foreground = label.usingColorSpace(.deviceRGB)!
            let background = NSColor.textBackgroundColor.usingColorSpace(.deviceRGB)!
            #expect(abs(foreground.redComponent - background.redComponent) > 0.6)
        }
    }
}

@Test("Render the real appearance controls in both themes", .enabled(if: ProcessInfo.processInfo.environment["DROPSIFT_THEME_PREVIEW"] != nil))
@MainActor func renderAppearanceControlsInBothThemes() throws {
    let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DROPSIFT_THEME_PREVIEW"]))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for appearance in [AppAppearance.light, .dark] {
        let view = VStack(alignment: .leading, spacing: 22) {
            Text("DropSift").font(.title.weight(.semibold))
            DesktopAppearanceSettings()
            Divider()
            MarkdownNoteEditor(text: .constant("# Meeting notes\nCapture a conversation. Find what matters.\n\n- Review the transcript\n- [ ] Follow up on Friday"))
        }
        .padding(24)
        .frame(width: 650, height: 430)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, appearance.colorScheme!)
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        hosting.frame = NSRect(x: 0, y: 0, width: 650, height: 430)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent("appearance-\(appearance.rawValue).png"))
    }
}
