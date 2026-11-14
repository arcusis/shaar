// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor
final class SettingsVisualTests: XCTestCase {
  func testProfileDeletionTitleIsVoiceOverHeading() {
    XCTAssertEqual(ProfileDeletionConfirmation.headingTraits, .isHeader)
  }

  func testPrivacyControls() async throws {
    try XCTSkipUnless(SidebarVisualCaptureSupport.enabled, "Visual capture requires opt-in")
    let output = try SidebarVisualCaptureSupport.prepare()
    let id = UUID()
    let backend = ProfileSettingsStub()
    backend.exceptions[id] = [
      "https://example.test": ["camera": ["value": "allow", "isDefault": false]]
    ]
    let model = ProfilePrivacyModel(profileID: id, backend: backend)
    await model.load()
    for scheme in [ColorScheme.light, .dark] {
      let view = Form {
        ProfilePrivacySections(model: model, expandedSites: ["https://example.test"])
      }
      .formStyle(.grouped)
      .environment(\.colorScheme, scheme)
      let mounted = try MountedChromeSidebar(
        view: view, size: NSSize(width: 600, height: 760),
        appearance: scheme == .dark ? .darkAqua : .aqua)
      defer { mounted.close() }
      _ = try await mounted.capture(
        to: output.appending(
          path: "settings-privacy-controls-\(scheme == .dark ? "dark" : "light").png"),
        requiredText: ["Website Data", "Site Permissions", "https://example.test", "Camera"])
    }
  }

  func testProfileDeletionConfirmation() async throws {
    try XCTSkipUnless(SidebarVisualCaptureSupport.enabled, "Visual capture requires opt-in")
    let output = try SidebarVisualCaptureSupport.prepare()
    let profiles = [
      BrowserSettingsProfile(id: UUID(), name: "Personal", spaces: []),
      BrowserSettingsProfile(id: UUID(), name: "Work", spaces: []),
    ]
    for scheme in [ColorScheme.light, .dark] {
      for remove in [false, true] {
        let view = ProfileDeletionConfirmation(
          profile: profiles[0], profiles: profiles, removeSpaces: remove,
          onDeleteProfile: { _, _ in XCTFail("Capture must not delete a profile") }, onDismiss: {}
        )
        .environment(\.colorScheme, scheme)
        .frame(width: 420, height: 500)
        let mounted = try MountedChromeSidebar(
          view: view, size: NSSize(width: 420, height: 500),
          appearance: scheme == .dark ? .darkAqua : .aqua)
        defer { mounted.close() }
        _ = try await mounted.capture(
          to: output.appending(
            path:
              "settings-delete-\(remove ? "remove" : "move")-\(scheme == .dark ? "dark" : "light").png"
          ),
          requiredText: ["Delete Personal?", "Chromium"])
      }
    }
  }

  func testSections() async throws {
    try XCTSkipUnless(SidebarVisualCaptureSupport.enabled, "Visual capture requires opt-in")
    let output = try SidebarVisualCaptureSupport.prepare()
    let profileID = UUID()
    for scheme in [ColorScheme.light, .dark] {
      for section in [
        BrowserSettingsSection.general, .appearance, .profiles, .shortcuts, .about,
        .privacy,
      ] {
        let size = NSSize(width: 720, height: section == .profiles ? 900 : 560)
        let view = BrowserSettingsView(
          profiles: [
            BrowserSettingsProfile(
              id: profileID, name: "Personal",
              spaces: [
                BrowserSettingsSpace(id: UUID(), name: "Personal", symbol: "square.stack.3d.up")
              ],
              accounts: [
                ConnectedAccount(provider: .google, email: "alex@example.com", name: "Alex Example")
              ],
              canChooseDownloadDirectory: section == .profiles)
          ],
          searchEngines: [BrowserSettingsChoice(id: "google", title: "Google")],
          selectedProfileID: .constant(profileID), sidebarInitiallyVisible: .constant(true),
          selectedSearchEngine: .constant("google"), profileBackend: ProfileSettingsStub(),
          httpsOnlyModeEnabled: { _ in true },
          onSetHttpsOnlyMode: { _, _ in true },
          initialSection: section
        )
        .environment(\.colorScheme, scheme)
        .frame(width: size.width, height: size.height)
        let mounted = try MountedChromeSidebar(
          view: view, size: size, appearance: scheme == .dark ? .darkAqua : .aqua)
        defer { mounted.close() }
        let name = "settings-\(section.rawValue)-\(scheme == .dark ? "dark" : "light").png"
        _ = try await mounted.capture(
          to: output.appending(path: name),
          requiredText: section == .profiles
            ? ["Personal", "Download folder", "Spaces"] : [section.title])
      }
    }
  }
}
