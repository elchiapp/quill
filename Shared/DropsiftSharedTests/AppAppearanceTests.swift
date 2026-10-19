import SwiftUI
import Testing
@testable import DropsiftShared

@Test func appearanceHasThreeStableChoices() {
    #expect(AppAppearance.allCases.map(\.rawValue) == ["system", "light", "dark"])
    #expect(AppAppearance.allCases.map(\.title) == ["System", "Light", "Dark"])
}

@Test func systemAppearanceDoesNotForceAColorScheme() {
    #expect(AppAppearance.system.colorScheme == nil)
    #expect(AppAppearance.light.colorScheme == .light)
    #expect(AppAppearance.dark.colorScheme == .dark)
}

@Test func missingOrUnknownAppearanceFollowsTheSystem() {
    #expect(AppAppearance.resolve(nil) == .system)
    #expect(AppAppearance.resolve("") == .system)
    #expect(AppAppearance.resolve("obsolete") == .system)
    #expect(AppAppearance.resolve("dark") == .dark)
    #expect(AppAppearance.resolve("light") == .light)
}
