import Foundation
import Testing

@testable import dropsift

@Test
func deniedMicrophoneDoesNotPreventOpeningTheDesktopLibrary() {
  let checks = [
    Check(name: "microphone", status: .fail("denied"), remediation: nil),
    Check(name: "recordings folder", status: .ok, remediation: nil),
  ]
  #expect(!DoctorReport.allOK(checks))
  #expect(DoctorReport.canLaunchInterface(checks))
}

@Test
func anUnwritableLibraryStillBlocksStartup() {
  let checks = [Check(name: "recordings folder", status: .fail("not writable"), remediation: nil)]
  #expect(!DoctorReport.canLaunchInterface(checks))
}

@Test
func firstLaunchPermissionAndModelWarningsDoNotBlockTheInterface() {
  let checks = [
    Check(name: "microphone", status: .warn("not requested"), remediation: nil),
    Check(name: "transcription", status: .warn("not downloaded"), remediation: nil),
  ]
  #expect(DoctorReport.canLaunchInterface(checks))
}

@Test
func distributionDocumentsHaveStableBundledResourceNames() {
  #expect(
    Set(AppDocument.allCases.map(\.rawValue)) == ["BetaGuide", "Privacy", "ThirdPartyNotices"])
}

@Test
func settingsLeaveRoomForTheHeaderOnLaptopScreens() {
  #expect(SettingsView.scrollHeight(screenHeight: 650) == 480)
  #expect(SettingsView.scrollHeight(screenHeight: 900) == 660)
  #expect(SettingsView.scrollHeight(screenHeight: 500) == 330)
}
