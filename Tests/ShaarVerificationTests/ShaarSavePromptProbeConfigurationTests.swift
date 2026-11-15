// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import Testing

@testable import ShaarVerification

@Suite @MainActor struct ShaarSavePromptProbeConfigurationTests {
  @Test func actionMatrixCoversSaveAndDismissForEachPromptAndNeverForPasswordsOnly() {
    #expect(
      ShaarSavePromptProbeScenario.all == [
        .dismiss(.password), .save(.password),
        .dismiss(.card), .save(.card),
        .dismiss(.address), .save(.address),
        .neverPassword,
      ])
  }

  @Test func cardFixtureExpiryRemainsInTheFuture() {
    let currentYear = Calendar.current.component(.year, from: .now)
    let fixtureYear = Int(ShaarSavePromptProbe.cardExpiryYear(relativeTo: .now))

    #expect(fixtureYear == currentYear + 4)
  }

  @Test func normalSavePreferencesAreSeededForTheWorkspaceProfiles() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let profileID = UUID()
    let preferences = try ShaarSavePromptProbe.seedNormalProfileSavePreferences(
      profileIDs: [profileID], dataRoot: root)
    let values = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: preferences[0])) as? [String: Any])
    let autofill = try #require(values["autofill"] as? [String: Any])

    #expect(preferences[0].deletingLastPathComponent().lastPathComponent
      == "Profile \(profileID.uuidString.lowercased())")
    #expect(values["credentials_enable_service"] as? Bool == true)
    #expect(autofill["profile_enabled"] as? Bool == true)
    #expect(autofill["credit_card_enabled"] as? Bool == true)
  }

  @Test func fixtureMustUseHTTPOnTheIPv4LoopbackAddress() {
    let invalid: [URL?] = [
      nil,
      URL(string: "https://127.0.0.1:8080/password"),
      URL(string: "http://localhost:8080/password"),
      URL(string: "http://example.invalid:8080/password"),
    ]
    for pageURL in invalid {
      #expect(
        ShaarSavePromptProbe.run(
          frameworkURL: URL(filePath: "/missing/Chromium Framework.framework"),
          outputURL: FileManager.default.temporaryDirectory.appending(path: "save-prompt.json"),
          pageURL: pageURL,
          neverPageURL: URL(string: "http://127.0.0.1:8080/password")) == 2)
    }
  }

  @Test func neverFixtureMustAlsoUseHTTPOnIPv4LoopbackWithPort() {
    for neverPageURL in [
      URL(string: "https://127.0.0.1:8080/password"),
      URL(string: "http://localhost:8080/password"),
      URL(string: "http://example.invalid:8080/password"),
      URL(string: "http://127.0.0.1/password"),
    ] {
      #expect(
        ShaarSavePromptProbe.run(
          frameworkURL: URL(filePath: "/missing/Chromium Framework.framework"),
          outputURL: FileManager.default.temporaryDirectory.appending(path: "save-prompt.json"),
          pageURL: URL(string: "http://127.0.0.1:8080/password"),
          neverPageURL: neverPageURL) == 2)
    }
  }

  @Test func renderSurfaceIsTransparentClickThroughNeverKeyAndOrderedOutAfterward() {
    let window = NSWindow(
      contentRect: NSRect(x: -32_000, y: -32_000, width: 120, height: 80),
      styleMask: [.titled], backing: .buffered, defer: false)
    var focusedProbeTab = false
    let surface = ShaarSavePromptRenderSurface(window: window) {
      focusedProbeTab = true
    }

    #expect(focusedProbeTab)
    #expect(surface.isPresentingFramesWithoutInputOrFocus)
    #expect(!window.isKeyWindow)
    #expect(surface.orderOutAndRestore())
    #expect(!window.isVisible)
    #expect(window.alphaValue == 1)
    #expect(!window.ignoresMouseEvents)
  }

  @Test func promptPanelFrameMovesOutsideEveryDisplay() {
    let screens = [
      NSRect(x: 0, y: 0, width: 1_440, height: 900),
      NSRect(x: 1_440, y: 0, width: 1_920, height: 1_080),
    ]
    let frame = NSRect(x: 1_200, y: 600, width: 320, height: 180)

    let offscreen = ShaarSavePromptProbe.offscreenPanelFrame(
      frame, visibleScreenFrames: screens)

    #expect(!screens.contains { $0.intersects(offscreen) })
    #expect(offscreen.size == frame.size)
    #expect(offscreen.origin.y == frame.origin.y)
  }

}
