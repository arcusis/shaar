// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

/// Offscreen view layout only: no NSWindow, application launch, or physical input.
@MainActor
final class ProfilePrivacyLayoutTests: XCTestCase {
  func testPrivacyPaneFitsWithExpandedEnginePermissionsAndUnavailableOrSupportedCookiePolicy() async
  {
    let id = UUID()
    let backend = ProfileSettingsStub()
    let origin = "https://permissions.example.test"
    let names = [
      "camera", "microphone", "location", "notifications", "popups", "sound", "autoplay",
      "javascript", "images", "clipboard", "automaticDownloads", "cookies", "midi", "sensors",
      "windowManagement", "localFonts", "idleDetection", "storageAccess", "fileSystem",
      "keyboardLock", "pointerLock", "cameraPanTiltZoom",
    ]
    backend.exceptions[id] = [
      origin: Dictionary(
        uniqueKeysWithValues: names.map {
          ($0, ["value": "allow", "isDefault": false] as NSDictionary)
        })
    ]
    for policy in [nil, false, true] as [Bool?] {
      backend.cookiePolicies[id] = policy
      let model = ProfilePrivacyModel(profileID: id, backend: backend)
      await model.load()
      XCTAssertEqual(model.sites.first?.permissions.count, names.count)
      let view = Form {
        ProfilePrivacySections(model: model, expandedSites: [origin])
      }.formStyle(.grouped)
      assertFits(view, size: NSSize(width: 600, height: 760))
      XCTAssertEqual(model.cookiesBlocked, policy)
      XCTAssertTrue(backend.calls.allSatisfy { $0.1 == id })
      XCTAssertFalse(
        backend.calls.contains { ["data", "cache", "reset", "cookies", "delete"].contains($0.0) })
    }
  }

  func testPrivacyPaneFitsEmptySuccessAndFailureStates() async {
    let backend = ProfileSettingsStub()
    let model = ProfilePrivacyModel(profileID: UUID(), backend: backend)
    await model.load()
    await model.clear(siteData: false)
    XCTAssertNotNil(model.message)
    assertFits(
      Form { ProfilePrivacySections(model: model) }.formStyle(.grouped),
      size: NSSize(width: 600, height: 760))
    backend.failureAction = "origins"
    await model.load()
    XCTAssertNotNil(model.failure)
    assertFits(
      Form { ProfilePrivacySections(model: model) }.formStyle(.grouped),
      size: NSSize(width: 600, height: 760))
  }

  func testDeletionConfirmationFitsBothSpaceDispositions() {
    let profiles = [
      BrowserSettingsProfile(id: UUID(), name: "Personal", spaces: []),
      BrowserSettingsProfile(id: UUID(), name: "Work", spaces: []),
    ]
    for remove in [false, true] {
      let view = ProfileDeletionConfirmation(
        profile: profiles[0], profiles: profiles, removeSpaces: remove,
        onDeleteProfile: { _, _ in XCTFail("Rendering must not delete a profile") },
        onDismiss: { XCTFail("Rendering must not dismiss confirmation") })
      let host = assertFits(view, size: NSSize(width: 420, height: 500))
      XCTAssertEqual(host.fittingSize.width, 420)
      XCTAssertLessThanOrEqual(host.fittingSize.height, 500)
    }
  }

  @discardableResult
  private func assertFits<V: View>(_ view: V, size: NSSize) -> NSHostingView<V> {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(host.bounds.size, size)
    // Form's ideal width is larger than its actual viewport on macOS. Check the laid-out
    // native children rather than treating that unconstrained ideal as overflow.
    for child in host.subviews {
      XCTAssertGreaterThanOrEqual(child.frame.minX, -1)
      XCTAssertLessThanOrEqual(child.frame.maxX, size.width + 1)
    }
    return host
  }
}
