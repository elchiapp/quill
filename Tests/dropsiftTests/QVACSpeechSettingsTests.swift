import Foundation
import Testing
@testable import dropsift

@Test func qvacSpeechDefaultsPreserveSDKParakeetMetal() {
    let settings = QVACSpeechSettings()
    #expect(settings.route == .sdk)
    #expect(settings.model == .parakeet)
    #expect(settings.acceleration == .metal)
}

@Test func qvacSpeechPreferencesRoundTripWithoutChangingOtherDefaults() throws {
    let name = "dropsift-speech-test-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let value = QVACSpeechSettings(route: .fabricDirect, model: .transcribepsy, acceleration: .cpu)
    defaults.set(try JSONEncoder().encode(value), forKey: QVACSpeechSettings.defaultsKey)
    #expect(QVACSpeechSettings.load(from: defaults) == value)
    #expect(defaults.string(forKey: "dropsift.localAI.backend") == nil)
    defaults.set(Data("invalid".utf8), forKey: QVACSpeechSettings.defaultsKey)
    #expect(QVACSpeechSettings.load(from: defaults) == QVACSpeechSettings())
}

@Test func unsupportedTranscribePsyCoreMLIsNotPersistedAsAWorkingNPUPath() {
    let settings = QVACSpeechSettings(route: .fabricDirect, model: .transcribepsy, acceleration: .coreml)
    #expect(settings.validated.acceleration == .metal)
}

@Test func qvacSpeechParametersIdentifyTheActualRouteAndModel() throws {
    let value = QVACSpeechSettings(route: .fabricDirect, model: .transcribepsy, acceleration: .cpu)
    let data = try JSONEncoder().encode(value.bridgeParams)
    let decoded = try JSONDecoder().decode(QVACBridgeParams.self, from: data)
    #expect(decoded.speechRoute == "fabricDirect")
    #expect(decoded.speechModel == "transcribepsy")
    #expect(decoded.speechAcceleration == "cpu")
}
