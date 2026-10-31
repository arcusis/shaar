import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor
final class SettingsVisualTests: XCTestCase {
  func testSections() async throws {
    try XCTSkipUnless(SidebarVisualCaptureSupport.enabled, "Visual capture requires opt-in")
    let profileID = UUID()
    let size = NSSize(width: 720, height: 560)
    for scheme in [ColorScheme.light, .dark] {
      for section in [
        BrowserSettingsSection.general, .appearance, .search, .profiles, .shortcuts, .about,
        .privacy,
      ] {
        let view = BrowserSettingsView(
          profiles: [
            BrowserSettingsProfile(
              id: profileID, name: "Personal",
              spaces: [
                BrowserSettingsSpace(id: UUID(), name: "Personal", symbol: "square.stack.3d.up")
              ],
              accounts: [
                ConnectedAccount(provider: .google, email: "alex@example.com", name: "Alex Example")
              ])
          ],
          searchEngines: [BrowserSettingsChoice(id: "google", title: "Google")],
          selectedProfileID: .constant(profileID), sidebarInitiallyVisible: .constant(true),
          selectedSearchEngine: .constant("google"), initialSection: section
        )
        .environment(\.colorScheme, scheme)
        .frame(width: size.width, height: size.height)
        let mounted = try MountedChromeSidebar(
          view: view, size: size, appearance: scheme == .dark ? .darkAqua : .aqua)
        defer { mounted.close() }
        let name = "settings-\(section.rawValue)-\(scheme == .dark ? "dark" : "light").png"
        _ = try await mounted.capture(
          to: URL(fileURLWithPath: "/tmp/\(name)"),
          requiredText: section == .profiles ? ["Personal", "Spaces"] : [section.title])
      }
    }
  }
}
