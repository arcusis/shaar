// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser
@testable import ShaarVerification

@MainActor struct ProfileProviderPageTests {
  @Test func cancellationProofAllowsNavigationButRejectsOwnershipChanges() throws {
    var session = BrowserSession.fresh()
    let opened = session.open(URL(string: "https://example.test/before")!)
    let tabID = try #require(opened)
    let before = try BrowserWorkspace(session: session)
    let window = try #require(before.windows.first)
    var navigating = before
    var updated = window.session
    let didUpdate = updated.updateTab(
      tabID, url: URL(string: "https://example.test/after")!, title: "Loaded page")
    #expect(didUpdate)
    try navigating.updateWindow(window.id, session: updated)
    #expect(navigating != before)
    #expect(ProfileOnboardingProbe.preservesProfileOwnership(before: before, after: navigating))

    var reassigned = before
    let other = try #require(session.profiles.first { $0.id != session.selectedSpace.profileID })
    let didReassign = try reassigned.setSpaceProfile(session.selectedSpaceID, to: other.id)
    #expect(didReassign)
    #expect(!ProfileOnboardingProbe.preservesProfileOwnership(before: before, after: reassigned))

    var added = before
    _ = try added.createProfile(name: "Unexpected draft")
    #expect(!ProfileOnboardingProbe.preservesProfileOwnership(before: before, after: added))

    var extraWindow = before
    _ = try extraWindow.addWindow(from: window.id)
    #expect(!ProfileOnboardingProbe.preservesProfileOwnership(before: before, after: extraWindow))
    let twoWindows = extraWindow
    let otherWindow = try #require(
      extraWindow.windows.first { $0.id != extraWindow.focusedWindowID })
    try extraWindow.focusWindow(otherWindow.id)
    #expect(
      !ProfileOnboardingProbe.preservesProfileOwnership(before: twoWindows, after: extraWindow))
  }

  @Test func readinessRequiresActualSecureProviderFormOrAppleAuthFrame() {
    func page(_ url: String, email: Bool = true, frames: [String] = []) -> [String: Any] {
      ["url": url, "email": email, "frames": frames, "ready": "complete"]
    }
    let valid: [(AccountProvider, String)] = [
      (.google, "https://accounts.google.com/v3/signin"),
      (.microsoft, "https://login.live.com/login.srf"),
      (.microsoft, "https://login.microsoftonline.com/common/login"),
      (.apple, "https://account.apple.com/"),
      (.apple, "https://idmsa.apple.com/appleauth/auth/authorize"),
    ]
    for (provider, url) in valid {
      #expect(ProfileOnboardingProbe.providerPageIsReady(page(url), provider: provider))
      #expect(
        !ProfileOnboardingProbe.providerPageIsReady(page(url, email: false), provider: provider))
      #expect(
        !ProfileOnboardingProbe.providerPageIsReady(
          page(url.replacingOccurrences(of: "https:", with: "http:")), provider: provider))
    }
    let apple = "https://idmsa.apple.com/appleauth/auth/authorize"
    #expect(
      ProfileOnboardingProbe.providerPageIsReady(
        page("https://www.icloud.com/", email: false, frames: [apple]), provider: .apple))
    #expect(
      !ProfileOnboardingProbe.providerPageIsReady(
        page("https://evil.test/", frames: [apple]), provider: .apple))
    #expect(
      !ProfileOnboardingProbe.providerPageIsReady(
        page(
          "https://www.icloud.com/", email: false, frames: ["https://idmsa.apple.com.evil.test/"]),
        provider: .apple))
    #expect(
      !ProfileOnboardingProbe.providerPageIsReady(
        page("https://accounts.google.com.evil.test/"), provider: .google))
    #expect(!ProfileOnboardingProbe.providerPageIsReady([:], provider: .microsoft))
  }
}
