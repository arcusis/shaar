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
        .save(.password), .dismiss(.password),
        .save(.card), .dismiss(.card),
        .save(.address), .dismiss(.address),
        .neverPassword,
      ])
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
}
