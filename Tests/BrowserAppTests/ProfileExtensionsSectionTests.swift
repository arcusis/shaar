import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor
final class ProfileExtensionsSectionTests: XCTestCase {
  func testPinnedExtensionsOnlyIncludesEnabledItems() {
    let enabled = sample("Enabled", enabled: true)
    let disabled = sample("Disabled", enabled: false)
    let model = ExtensionManagerModel(
      profileID: UUID(), extensions: [enabled, disabled], pinnedIDs: [enabled.id, disabled.id])

    XCTAssertEqual(model.pinnedExtensions.map(\.id), [enabled.id])
  }

  func testSectionCapturesLightAndDarkAppearances() async throws {
    try XCTSkipUnless(SidebarVisualCaptureSupport.enabled, "Visual capture requires opt-in")
    let root = try SidebarVisualCaptureSupport.prepare()
    let model = ExtensionManagerModel(
      profileID: UUID(),
      extensions: [
        sample("Bitwarden Password Manager", enabled: true),
        sample("Grammarly", enabled: false),
      ])
    let view = VStack(alignment: .leading, spacing: 8) {
      Text("Extensions").font(.headline)
      ProfileExtensionsSection(model: model, onAddExtensions: {})
    }
    .padding(16)
    .frame(width: 440, height: 230, alignment: .topLeading)
    .background(Color(nsColor: .windowBackgroundColor))

    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      let mounted = try MountedChromeSidebar(
        view: view, size: NSSize(width: 440, height: 230), appearance: appearance)
      defer { mounted.close() }
      _ = try await mounted.capture(
        to: root.appendingPathComponent("profile-extensions-\(name).png"),
        requiredText: ["Extensions", "Bitwarden", "Grammarly", "Add Extensions"])
    }
  }

  private func sample(_ name: String, enabled: Bool) -> ManagedExtension {
    ManagedExtension(
      id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        .padding(toLength: 32, withPad: "a", startingAt: 0),
      name: name, version: "1.0", description: "", enabled: enabled, mayDisable: true,
      permissions: [], hostPermissions: [])
  }
}
