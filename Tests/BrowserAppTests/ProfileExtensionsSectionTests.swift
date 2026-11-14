// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor
final class ProfileExtensionsSectionTests: XCTestCase {
  func testExtensionRowNamesAreVoiceOverHeadings() {
    XCTAssertEqual(ProfileExtensionsSection.extensionRowHeadingTraits, .isHeader)
  }

  func testExtensionToolbarButtonNamesItsProfileInBothLanguages() {
    XCTAssertEqual(
      ExtensionToolbar.accessibilityLabel(profileName: "Work", language: .english),
      "Extensions for Work")
    XCTAssertEqual(
      ExtensionToolbar.accessibilityLabel(profileName: "Work", language: .hebrew),
      "תוספים עבור \u{2068}Work\u{2069}")
  }

  func testExtensionManagerTitleIsVoiceOverHeading() {
    XCTAssertEqual(ExtensionManagerPanel.headingTraits, .isHeader)
  }

  func testExtensionDetailsSectionsAreVoiceOverHeadings() {
    XCTAssertEqual(ExtensionDetails.detailsHeadingTraits, .isHeader)
  }

  func testExtensionPopupNameIsVoiceOverHeading() {
    XCTAssertTrue(ExtensionToolbar.popupTitleTraits.contains(.isHeader))
  }

  func testProfileNamesFollowShaarsSelectedLanguageOrder() {
    let english = UUID()
    let hebrew = UUID()
    let row = SharedExtensionSettingsRow(
      id: "example", name: "Example", version: "1",
      profiles: [
        english: .init(name: "A", enabled: true, pending: false, failed: false),
        hebrew: .init(name: "אב", enabled: true, pending: false, failed: false),
      ])
    XCTAssertEqual(
      ProfileExtensionsSection.sortedProfileIDs(for: row, language: .hebrew),
      [hebrew, english])
    XCTAssertEqual(
      ProfileExtensionsSection.sortedProfileIDs(for: row, language: .english),
      [english, hebrew])
  }

  func testSharedExtensionRetryLabelNamesTheExtensionAndProfile() {
    XCTAssertEqual(
      ProfileExtensionsSection.installRetryLabel(
        extensionName: "Notes", profileName: "Work", language: .english),
      "Retry installing Notes for Work")
    XCTAssertEqual(
      ProfileExtensionsSection.installRetryLabel(
        extensionName: "Notes", profileName: "Work", language: .hebrew),
      "ניסיון חוזר להתקנת התוסף \u{2068}Notes\u{2069} בפרופיל \u{2068}Work\u{2069}")
  }

  func testSharedExtensionToggleLabelsNameTheActionExtensionAndProfile() {
    XCTAssertEqual(
      ProfileExtensionsSection.toggleLabel(
        extensionName: "Notes", profileName: "Work", enabled: false, language: .english),
      "Enable Notes for Work")
    XCTAssertEqual(
      ProfileExtensionsSection.toggleLabel(
        extensionName: "Notes", profileName: "Work", enabled: true, language: .hebrew),
      "השבתת התוסף \u{2068}Notes\u{2069} בפרופיל \u{2068}Work\u{2069}")
  }

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
    .frame(width: 440, height: 320, alignment: .topLeading)
    .background(Color(nsColor: .windowBackgroundColor))

    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      let mounted = try MountedChromeSidebar(
        view: view, size: NSSize(width: 440, height: 320), appearance: appearance)
      defer { mounted.close() }
      _ = try await mounted.capture(
        to: root.appendingPathComponent("profile-extensions-\(name).png"),
        requiredText: ["Extensions", "Bitwarden", "Grammarly", "Add Extensions"])
    }
  }

  func testDeveloperModeRefusalRendersInLightAndDark() throws {
    let runtime = RefusingDeveloperModeRuntime()
    let profileID = UUID()
    let preferences = BrowserPreferencesStore(
      fileURL: FileManager.default.temporaryDirectory.appending(
        path: "extension-refusal-\(UUID()).json"))
    let model = ExtensionManagerModel.shared(
      runtime: runtime, preferences: preferences, profileID: profileID)
    let output = URL(fileURLWithPath: "build/ci/extension-section-refusal", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let view = ProfileExtensionsSection(model: model, onAddExtensions: {})
      .padding(16)
      .frame(width: 440, height: 220, alignment: .topLeading)
      .background(Color(nsColor: .windowBackgroundColor))

    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      let image = output.appending(path: "profile-extensions-before-\(name).png")
      let bitmap = try VisualCapture.renderOffscreen(
        view, size: NSSize(width: 440, height: 220), appearance: appearance, to: image)
      XCTAssertGreaterThan(bitmap.pixelsWide, 0)
      let visibleText = try VisualTextRecognition.lines(in: image).joined(separator: " ")
      XCTAssertTrue(visibleText.localizedCaseInsensitiveContains("Developer mode"))
      XCTAssertFalse(
        visibleText.localizedCaseInsensitiveContains(ExtensionInstallNotice.needsNewerEngine))
    }

    model.setDeveloperMode(true)
    XCTAssertFalse(model.developerMode)
    XCTAssertFalse(preferences.extensionDeveloperMode(for: profileID))
    XCTAssertEqual(model.status, ExtensionInstallNotice.needsNewerEngine)
    XCTAssertEqual(runtime.actions, ["setDeveloperMode"])

    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      let image = output.appending(path: "profile-extensions-after-\(name).png")
      let bitmap = try VisualCapture.renderOffscreen(
        view, size: NSSize(width: 440, height: 220), appearance: appearance, to: image)
      XCTAssertGreaterThan(bitmap.pixelsWide, 0)
      let visibleText = try VisualTextRecognition.lines(in: image).joined(separator: " ")
      XCTAssertTrue(
        visibleText.localizedCaseInsensitiveContains(ExtensionInstallNotice.needsNewerEngine),
        "The refusal was not visible in the \(name) render: \(visibleText)")
      XCTAssertTrue(visibleText.localizedCaseInsensitiveContains("Developer mode"))
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

@MainActor
private final class RefusingDeveloperModeRuntime: ARCShaarRuntime {
  nonisolated(unsafe) var actions: [String] = []

  override func submitExtensionManage(
    forProfileID profileID: String, tabID: String?, payload: [String: Any],
    completion: @escaping (String?, Int) -> Void
  ) {
    actions.append(payload["action"] as? String ?? "")
    completion(nil, 1)
  }
}
