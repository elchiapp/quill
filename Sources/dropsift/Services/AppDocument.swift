import AppKit
import Foundation

enum AppDocument: String, CaseIterable {
  case betaGuide = "BetaGuide"
  case privacy = "Privacy"
  case notices = "ThirdPartyNotices"

  func url(in bundle: Bundle = .main) -> URL? {
    bundle.url(forResource: rawValue, withExtension: "html")
  }

  @MainActor
  func open() {
    guard let url = url() else { return }
    NSWorkspace.shared.open(url)
  }
}
