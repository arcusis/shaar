// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct ProfileAccountSignInTests {
  @Test func missingSignInPageLoadingLabelIsLocalized() {
    #expect(ProfileAccountSignInAccessibility.loadingLabel == SettingsL10n.string("Loading sign-in…"))
  }

  @Test func loadingPageAccessibilityLabelIsLocalized() {
    #expect(
      ProfileAccountSignInAccessibility.loadingPageLabel(language: .english)
        == "Loading sign-in page…")
    #expect(
      ProfileAccountSignInAccessibility.loadingPageLabel(language: .hebrew)
        == "טעינת דף ההתחברות…")
  }

  @Test func hiddenSignInOwnsItsWindowUntilCancellationAndFinishesOnce() throws {
    let runtime = SignInWindowTestRuntime()
    let profile = BrowserProfile(id: UUID(), name: "Work")
    let flow = try ProfileAccountSignIn(
      events: BrowserRuntimeEvents(runtime: runtime), profile: profile,
      provider: .google, purpose: .signIn, visible: false)
    let windowID = try #require(flow.windowIDs.first)
    var finishCount = 0
    flow.onFinished = { account in
      #expect(account == nil)
      finishCount += 1
    }

    #expect(flow.ownsWindow(windowID))
    #expect(flow.windowIDs == [windowID])
    #expect(!flow.window.isVisible)

    flow.cancel()
    flow.cancel()
    #expect(finishCount == 1)
    #expect(runtime.closedIDs == [windowID])
  }
}

private final class SignInWindowTestRuntime: ARCChromiumRuntime, @unchecked Sendable {
  var windows: [String: NSWindow] = [:]
  var closedIDs: [String] = []

  override func createWindowID(_ windowID: String) throws {
    MainActor.assumeIsolated {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      windows[windowID] = window
    }
  }

  override func closeWindowID(_ windowID: String) -> Bool {
    MainActor.assumeIsolated {
      closedIDs.append(windowID)
      windows.removeValue(forKey: windowID)?.close()
      return true
    }
  }

  override func window(forID windowID: String) -> NSWindow? {
    MainActor.assumeIsolated { windows[windowID] }
  }

  override func hostView(forWindowID windowID: String) -> NSView? {
    MainActor.assumeIsolated { windows[windowID]?.contentView }
  }
}
