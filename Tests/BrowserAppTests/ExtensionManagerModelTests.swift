// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct ExtensionManagerModelTests {
  @Test func siteAccessRequiresAnExactOriginAndReportsEngineRefusal() {
    let runtime = SiteAccessRuntime()
    let profileID = UUID()
    let preferences = BrowserPreferencesStore(
      fileURL: FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json"))
    let model = ExtensionManagerModel.shared(
      runtime: runtime, preferences: preferences, profileID: profileID)
    let extensionID = String(repeating: "a", count: 32)

    model.setSiteAccess(
      .onSite, extensionID: extensionID, origin: "https://example.test/path", tabID: nil)
    #expect(runtime.payloads.isEmpty)
    #expect(model.status == ExtensionInstallNotice.siteAccessRefused)

    model.setSiteAccess(
      .onSite, extensionID: extensionID, origin: "https://example.test", tabID: nil)
    #expect(runtime.payloads.count == 1)
    #expect(runtime.payloads[0]["action"] as? String == "setSiteAccess")
    #expect(runtime.payloads[0]["access"] as? String == ExtensionSiteAccess.onSite.rawValue)
    #expect(runtime.payloads[0]["origin"] as? String == "https://example.test")
    #expect(model.status == ExtensionInstallNotice.siteAccessRefused)
  }

  @Test func olderIncognitoFailureCannotReplaceNewerSiteAccessSuccess() {
    let runtime = DelayedSiteAccessRuntime()
    let model = ExtensionManagerModel.shared(
      runtime: runtime,
      preferences: BrowserPreferencesStore(
        fileURL: FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json")),
      profileID: UUID())
    let extensionID = String(repeating: "a", count: 32)
    model.setIncognitoEnabled(extensionID, enabled: true)
    model.setSiteAccess(.onClick, extensionID: extensionID, origin: "https://example.test", tabID: nil)
    runtime.complete(1, json: #"{"schemaVersion":1,"updated":true}"#, code: 0)
    runtime.complete(0, json: nil, code: 1)
    #expect(model.status == nil)
  }

  @Test func staleExtensionActionReplyCannotReplaceLatestNotice() {
    let runtime = SiteAccessRuntime()
    runtime.holdReplies = true
    let profileID = UUID()
    let preferences = BrowserPreferencesStore(
      fileURL: FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json"))
    let model = ExtensionManagerModel.shared(
      runtime: runtime, preferences: preferences, profileID: profileID)
    let extensionID = String(repeating: "a", count: 32)
    model.setSiteAccess(
      .onSite, extensionID: extensionID, origin: "https://example.test", tabID: nil)
    model.setIncognitoEnabled(extensionID, enabled: true)
    #expect(runtime.replies.count == 2)
    runtime.replies[1](nil, 1)
    #expect(model.status == ExtensionInstallNotice.privateAccessRefused)
    runtime.replies[0](nil, 1)
    #expect(model.status == ExtensionInstallNotice.privateAccessRefused)
  }

  @Test func staleSettingsReplyCannotReplaceDeveloperModeNotice() {
    let runtime = SiteAccessRuntime()
    runtime.holdReplies = true
    let profileID = UUID()
    let preferences = BrowserPreferencesStore(
      fileURL: FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json"))
    let model = ExtensionManagerModel.shared(
      runtime: runtime, preferences: preferences, profileID: profileID)
    let extensionID = String(repeating: "a", count: 32)

    model.setSiteAccess(
      .onSite, extensionID: extensionID, origin: "https://example.test", tabID: nil)
    model.setDeveloperMode(true)
    #expect(runtime.replies.count == 2)

    runtime.replies[1](nil, 0)
    #expect(model.status == ExtensionInstallNotice.developerModeFailed)
    runtime.replies[0](nil, 1)
    #expect(model.status == ExtensionInstallNotice.developerModeFailed)
  }
}

@MainActor
private final class SiteAccessRuntime: ARCShaarRuntime {
  nonisolated(unsafe) var payloads: [[String: Any]] = []
  nonisolated(unsafe) var replies: [(String?, Int) -> Void] = []
  nonisolated(unsafe) var holdReplies = false

  override func submitExtensionManage(
    forProfileID profileID: String, tabID: String?, payload: [String: Any],
    completion: @escaping (String?, Int) -> Void
  ) {
    payloads.append(payload)
    if holdReplies {
      replies.append(completion)
    } else {
      completion(nil, 1)
    }
  }
}

@MainActor
private final class DelayedSiteAccessRuntime: ARCShaarRuntime {
  nonisolated(unsafe) private var replies: [(String?, Int) -> Void] = []

  override func submitExtensionManage(
    forProfileID profileID: String, tabID: String?, payload: [String: Any],
    completion: @escaping (String?, Int) -> Void
  ) {
    replies.append(completion)
  }

  func complete(_ index: Int, json: String?, code: Int) {
    replies[index](json, code)
  }
}
