// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import ObjectiveC
import XCTest

@testable import ArcusisBrowser

final class BrowserBackendSelectionTests: XCTestCase {
  func testArdiaRemainsDefault() {
    XCTAssertEqual(BrowserBackendSelection.choose(environment: [:], arguments: []), .ardia)
  }

  func testShaarRequiresExplicitEnvironmentOrFlag() {
    XCTAssertEqual(
      BrowserBackendSelection.choose(
        environment: ["SHAAR_ENGINE_BACKEND": "shaar"], arguments: []), .shaar)
    XCTAssertEqual(
      BrowserBackendSelection.choose(
        environment: [:], arguments: ["--shaar-engine-backend=shaar"]), .shaar)
    XCTAssertEqual(
      BrowserBackendSelection.choose(
        environment: ["SHAAR_ENGINE_BACKEND": "unknown"], arguments: []), .ardia)
  }

  func testPreviewBundleSelectsShaar() {
    XCTAssertEqual(
      BrowserBackendSelection.choose(
        environment: [:], arguments: [], bundleBackend: "shaar"), .shaar)
    XCTAssertEqual(
      BrowserBackendSelection.choose(
        environment: [:], arguments: [], bundleBackend: "unknown"), .ardia)
  }

  func testExplicitShaarSelectionDoesNotFallBackWhenABIMissing() {
    XCTAssertThrowsError(
      try ARCShaarRuntime(frameworkURL: URL(fileURLWithPath: "/nonexistent-shaar-framework")))
  }

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

  func testShaarOverridesNavigation() {
    for selector in [
      "navigateTabID:profileID:windowID:url:",
      "goBackInTabID:", "goForwardInTabID:",
      "reloadTabID:profileID:mode:",
    ] {
      assertShaarOverrides(selector)
    }
  }

  func testShaarOverridesPrivateBrowsingAndPrivacy() {
    for selector in [
      "privatePrivacyAvailable", "privateContextEnabled", "isPrivateIdentity:",
      "privateIdentityOccupied:",
      "createPrivateContextID:sourceProfileID:completion:",
      "createPrivateWindowID:contextID:tabID:url:error:",
      "openPrivateTabID:windowID:contextID:url:error:",
      "selectPrivateTabID:windowID:contextID:",
      "focusPrivateTabID:windowID:contextID:",
      "closePrivateTabID:windowID:contextID:completion:",
      "navigatePrivateTabID:windowID:contextID:url:",
      "reloadPrivateTabID:windowID:contextID:",
      "goBackPrivateTabID:windowID:contextID:",
      "goForwardPrivateTabID:windowID:contextID:",
      "windowForPrivateWindowID:contextID:",
      "hostViewForPrivateWindowID:contextID:",
      "viewForPrivateTabID:windowID:contextID:",
      "closePrivateWindowID:contextID:completion:",
      "releasePrivateContextID:",
      "privatePrivacyStatusForContextID:completion:",
      "setPrivateCookieSettingForContextID:origin:value:completion:",
      "setPrivateTrackerAllowanceForContextID:origin:allow:completion:",
      "privateCookiesForTabID:windowID:contextID:origin:completion:",
      "setPrivateCookiesAllowed:tabID:windowID:contextID:origin:completion:",
    ] {
      assertShaarOverrides(selector)
    }
  }

  func testShaarOverridesExtensionOperations() {
    for selector in [
      "extensionsForProfileID:", "extensionActionTitleForID:tabID:",
      "showPopupForExtension:tabID:error:",
      "executeExtensionID:tabID:error:",
      "manageExtensionsForProfileID:operation:extensionID:enabled:completion:",
      "extensionsDirectoryForProfileID:", "viewForExtensionPopupID:",
      "closeExtensionPopup", "closeExtensionPopupForWindowID:",
    ] {
      assertShaarOverrides(selector)
    }
  }

  func testShaarOverridesRemainingCoreRoutes() {
    for selector in [
      "faviconForTabID:profileID:windowID:",
      "chromeWindowIDForProfileID:windowID:",
      "findInTabID:profileID:requestID:text:forward:",
      "stopFindingInTabID:",
      "evaluateInTabID:script:completion:",
      "bookmarksForProfileID:completion:",
      "applyBookmarkOperation:profileID:completion:",
      "historyForProfileID:limit:completion:",
      "deleteHistoryURL:profileID:completion:",
      "importHistoryRows:source:profileID:completion:",
      "nativeTabIDForID:",
      "resolveExternalAppRequestID:accepted:",
    ] {
      assertShaarOverrides(selector)
    }
  }

  func testShaarOverridesDevToolsAndInspector() {
    for selector in [
      "devToolsViewForTabID:", "showDevToolsForTabID:", "closeDevToolsForTabID:",
      "beginInspectorForTabID:profileID:windowID:", "endInspectorForTabID:",
      "inspectorCall:params:tabID:profileID:windowID:completion:",
      "beginDeveloperSessionForTabID:profileID:windowID:",
      "endDeveloperSessionForTabID:profileID:windowID:",
      "developerCall:params:tabID:profileID:windowID:completion:",
    ] {
      assertShaarOverrides(selector)
    }
    for field in [
      "_shaarEngine", "_nextRequestID", "_shaarProfiles", "_shaarWindows",
      "_shaarTabs", "_shaarTabProfiles", "_shaarTabWindows",
    ] {
      XCTAssertNotNil(class_getInstanceVariable(ARCShaarRuntime.self, field), field)
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
