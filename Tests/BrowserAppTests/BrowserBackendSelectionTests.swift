// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import ObjectiveC
import XCTest

final class BrowserBackendSelectionTests: XCTestCase {
  func testShaarOverridesProfileLoading() {
    assertShaarOverrides("loadProfileID:completion:")
  }

  func testShaarOverridesWindowAndTabHosting() {
    for selector in [
      "createWindowID:error:", "closeWindowID:",
      "openTabID:profileID:windowID:url:error:", "closeTabID:",
      "hostViewForWindowID:", "viewForTabID:", "activateTabID:",
    ] {
      assertShaarOverrides(selector)
    }
  }

  func testShaarOverridesSiteControls() {
    for selector in [
      "clearProfileSiteDataForProfileID:completion:",
      "sitePermissionOriginsForProfileID:completion:",
      "resetSitePermissionsForOrigin:profileID:completion:",
      "thirdPartyCookiesBlockedForProfileID:",
      "setThirdPartyCookiesBlocked:profileID:completion:",
      "deleteEngineProfileID:completion:",
      "securityInfoForTabID:profileID:",
      "siteSettingsForOrigin:profileID:completion:",
      "setSiteSetting:value:origin:profileID:completion:",
      "clearSiteDataForOrigin:profileID:completion:",
      "clearCacheForProfileID:completion:",
      "clearCookiesForTabID:profileID:completion:",
    ] { assertShaarOverrides(selector) }
  }

  func testShaarOverridesMediaAndPictureInPicture() {
    for selector in [
      "mediaSessionStateForTabID:", "sendMediaSessionAction:seconds:tabID:",
      "setMuted:tabID:", "setMediaVolume:tabID:",
      "enterPictureInPictureInTabID:completion:", "exitPictureInPictureInTabID:",
      "engineHandlesAutoPictureInPictureForTabID:",
      "setAutoPictureInPictureAllowed:tabID:",
      "pictureInPictureVideoWindowForTabID:",
      "sendPictureInPictureCommand:seconds:tabID:",
    ] { assertShaarOverrides(selector) }
  }

  func testShaarOverridesDownloadServices() {
    for selector in [
      "downloadCommand:downloadID:profileID:completion:",
      "refreshDownloadsForProfileID:",
      "downloadsDirectoryForProfileID:",
    ] { assertShaarOverrides(selector) }
  }

  @MainActor func testShaarFeatureCallsRejectWithoutEngineHandles() {
    let runtime = ARCShaarRuntime()
    let profile = UUID().uuidString
    let tab = UUID().uuidString
    XCTAssertNil(runtime.mediaSessionState(forTabID: tab))
    XCTAssertFalse(runtime.setMuted(true, tabID: tab))
    XCTAssertNil(runtime.securityInfo(forTabID: tab, profileID: profile))
    let site = expectation(description: "site operation rejects absent profile")
    runtime.clearCache(forProfileID: profile) { error in
      XCTAssertNotNil(error)
      site.fulfill()
    }
    let picture = expectation(description: "picture in picture rejects absent tab")
    runtime.enterPictureInPicture(inTabID: tab) { requested in
      XCTAssertFalse(requested)
      picture.fulfill()
    }
    wait(for: [site, picture], timeout: 1)
  }

  private func assertShaarOverrides(_ name: String) {
    let selector = NSSelectorFromString(name)
    let ardia = class_getInstanceMethod(ARCChromiumRuntime.self, selector)
    let shaar = class_getInstanceMethod(ARCShaarRuntime.self, selector)
    XCTAssertNotNil(ardia)
    XCTAssertNotNil(shaar)
    XCTAssertNotEqual(ardia, shaar, "Shaar must override \(name)")
  }
}
