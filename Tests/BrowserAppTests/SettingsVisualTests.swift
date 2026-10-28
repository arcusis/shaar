import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor
final class SettingsVisualTests: XCTestCase {
  func testSections() async throws {
    try XCTSkipUnless(SidebarVisualCaptureSupport.enabled, "Visual capture requires opt-in")
    let profileID = UUID()
    let size = NSSize(width: 720, height: 650)
    for scheme in [ColorScheme.light, .dark] {
      for section in BrowserSettingsSection.allCases {
        let view = BrowserSettingsView(
          profiles: [BrowserSettingsProfile(id: profileID, name: "Personal", spaceCount: 1)],
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
          to: URL(fileURLWithPath: "/tmp/\(name)"), requiredText: [section.title])
      }
    }
  }
}
