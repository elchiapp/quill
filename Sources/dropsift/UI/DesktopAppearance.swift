import AppKit
import DropsiftShared
import SwiftUI

enum DesktopAppearance {
    @MainActor
    static func apply(_ preference: AppAppearance) {
        // Match native menus, title bars and editors to SwiftUI. nil follows OS.
        switch preference {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

struct DesktopAppearanceModifier: ViewModifier {
    @AppStorage(AppAppearance.preferenceKey) private var storedAppearance = AppAppearance.system.rawValue

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(AppAppearance.resolve(storedAppearance).colorScheme)
            .onAppear { DesktopAppearance.apply(AppAppearance.resolve(storedAppearance)) }
            .onChange(of: storedAppearance) { _, value in
                DesktopAppearance.apply(AppAppearance.resolve(value))
            }
    }
}

struct DesktopAppearanceSettings: View {
    @AppStorage(AppAppearance.preferenceKey) private var storedAppearance = AppAppearance.system.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Appearance").font(.headline)
            Picker("Appearance", selection: $storedAppearance) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.title).tag(appearance.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("appearance-picker")
            Text("System follows your Mac. Light and Dark apply only to DropSift.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
