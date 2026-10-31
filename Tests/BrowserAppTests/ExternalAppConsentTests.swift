// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct ExternalAppConsentTests {
  private func store() -> BrowserStore {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://example.com/path?secret=hidden")!))
    return store
  }

  private func request(
    _ store: BrowserStore, id: String = "x1", app: String? = "Example App"
  ) throws -> ExternalAppRequest {
    let tab = try #require(store.session.selectedSpace.selectedTab)
    return try #require(
      ExternalAppRequest(
        id: id, profileID: store.session.selectedSpace.profileID, tabID: tab.id,
        pageURL: tab.url, scheme: "sample", requestingOrigin: URL(string: "https://example.com"),
        applicationName: app, windowID: "window"))
  }

  @Test func acceptsSelectedRequestOnceAfterPresentation() throws {
    let store = store()
    let request = try request(store)
    var decisions: [Bool] = []
    store.onExternalAppDecision = { _, accepted in decisions.append(accepted) }
    #expect(store.requestExternalApp(request))
    #expect(store.sheet?.id == "external-x1")
    store.resolveExternalApp(request.id, accepted: true)
    store.resolveExternalApp(request.id, accepted: true)
    #expect(decisions == [true])
  }

  @Test func parsesExactRedactedNativeWirePayload() throws {
    let original = try request(store())
    let wire: [String: Any] = [
      "id": original.id,
      "profileID": original.profileID.uuidString,
      "tabID": original.tabID.uuidString,
      "windowID": original.windowID,
      "pageURL": original.pageURL.absoluteString,
      "scheme": original.scheme,
      "origin": "https://example.com",
      "app": "Example App",
    ]

    let parsed = try #require(BrowserEngine.externalAppRequest(from: wire, windowID: "window"))
    #expect(parsed.applicationName == "Example App")
    #expect(parsed.requestingOrigin == URL(string: "https://example.com"))
    #expect(parsed.tabID == original.tabID)
    #expect(parsed.profileID == original.profileID)
    #expect(parsed.windowID == "window")

    var noHandler = wire
    noHandler["app"] = NSNull()
    let unavailable = try #require(
      BrowserEngine.externalAppRequest(from: noHandler, windowID: "window"))
    #expect(unavailable.applicationName == nil)
    #expect(!unavailable.canOpen)
  }

  @Test func rejectsMalformedOrAliasedNativeWirePayload() throws {
    let original = try request(store())
    let valid: [String: Any] = [
      "id": original.id,
      "profileID": original.profileID.uuidString,
      "tabID": original.tabID.uuidString,
      "windowID": original.windowID,
      "pageURL": original.pageURL.absoluteString,
      "scheme": original.scheme,
      "origin": "https://example.com",
      "app": "Example App",
    ]
    #expect(BrowserEngine.externalAppRequest(from: valid, windowID: "other") == nil)

    var alias = valid
    alias.removeValue(forKey: "app")
    alias["applicationName"] = "Example App"
    #expect(BrowserEngine.externalAppRequest(from: alias, windowID: "window") == nil)

    var extraMetadata = valid
    extraMetadata["targetURL"] = "tel:+15555550123"
    #expect(BrowserEngine.externalAppRequest(from: extraMetadata, windowID: "window") == nil)

    for (key, value) in [
      ("origin", "https://example.com/path?private=true" as Any),
      ("app", 12 as Any),
      ("profileID", "not-a-uuid" as Any),
      ("tabID", "not-a-uuid" as Any),
      ("id", "media-1" as Any),
      ("scheme", "https" as Any),
    ] {
      var malformed = valid
      malformed[key] = value
      #expect(BrowserEngine.externalAppRequest(from: malformed, windowID: "window") == nil)
    }

    var missingOrigin = valid
    missingOrigin.removeValue(forKey: "origin")
    #expect(BrowserEngine.externalAppRequest(from: missingOrigin, windowID: "window") == nil)
  }

  @Test func cannotApproveMissingHandlerOrUnseenQueuedRequest() throws {
    let store = store()
    let unavailable = try request(store, app: nil)
    let queued = try request(store, id: "x2")
    var decisions: [String] = []
    store.onExternalAppDecision = { id, accepted in decisions.append("\(id):\(accepted)") }
    #expect(store.requestExternalApp(unavailable))
    #expect(!unavailable.canOpen)
    #expect(store.requestExternalApp(queued))
    store.resolveExternalApp(queued.id, accepted: true)
    #expect(decisions == ["x2:false"])
    store.resolveExternalApp(unavailable.id, accepted: true)
    #expect(decisions == ["x2:false", "x1:false"])
  }

  @Test func stalePageAndRendererFailureDenyAndModalDismissKeepsNextRequest() throws {
    let store = store()
    let first = try request(store)
    let second = try request(store, id: "x2")
    var decisions: [String] = []
    store.onExternalAppDecision = { id, accepted in decisions.append("\(id):\(accepted)") }
    #expect(store.requestExternalApp(first))
    #expect(store.requestExternalApp(second))
    store.sheet = nil
    store.sheetDidDismiss()
    #expect(store.sheet?.id == "external-x2")
    store.nativeRendererGone(
      first.tabID, profileID: first.profileID, status: "crashed", exitCode: 1)
    store.resolveExternalApp(first.id, accepted: true)
    store.resolveExternalApp(second.id, accepted: true)
    #expect(decisions == ["x1:false", "x2:false"])
  }

  @Test func changingSelectedPageDeniesRequestAndLaterAnswerDoesNothing() throws {
    let store = store()
    let request = try request(store)
    var decisions: [Bool] = []
    store.onExternalAppDecision = { _, accepted in decisions.append(accepted) }
    #expect(store.requestExternalApp(request))
    store.perform(.open(URL(string: "https://other.example/changed")!))
    store.resolveExternalApp(request.id, accepted: true)
    #expect(decisions == [false])
    #expect(store.externalAppRequests.isEmpty)
  }

  @Test func profileSwitchDeniesPendingRequestAndLateAnswerCannotReviveIt() throws {
    let store = store()
    let request = try request(store)
    var decisions: [Bool] = []
    store.onExternalAppDecision = { _, accepted in decisions.append(accepted) }
    #expect(store.requestExternalApp(request))
    store.cycleSpace(by: 1)
    store.resolveExternalApp(request.id, accepted: true)
    store.resolveExternalApp(request.id, accepted: true)
    #expect(decisions == [false])
  }

  @Test func otherSharedProfileSpaceAndTabCannotApprovePendingRequest() throws {
    let store = store()
    let request = try request(store)
    var decisions: [Bool] = []
    store.onExternalAppDecision = { _, accepted in decisions.append(accepted) }
    #expect(store.requestExternalApp(request))
    #expect(
      store.createSpace(
        name: "Shared profile space", sharingProfile: request.profileID, tint: .ocean))
    store.perform(.open(URL(string: "https://shared.example/new-tab")!))
    store.resolveExternalApp(request.id, accepted: true)
    store.resolveExternalApp(request.id, accepted: true)
    #expect(decisions == [false])
  }

  @Test func consentNamespacesRemainDistinctAndRendererFailureDrainsExternalRequest() throws {
    let store = store()
    let external = try request(store)
    let media = try #require(
      WebsitePermissionRequest(
        id: external.id, profileID: external.profileID, tabID: external.tabID,
        pageURL: external.pageURL, requestingOrigin: URL(string: "https://example.com")!,
        kinds: [.microphone]))
    let extensionInfo = try #require(
      BrowserExtension(id: String(repeating: "a", count: 32), name: "Example", version: "1"))
    let install = try #require(
      ExtensionInstallRequest(
        id: external.id, profileID: external.profileID, tabID: external.tabID,
        sourceURL: external.pageURL, browserExtension: extensionInfo, kind: .install,
        permissions: []))
    var accepted: [String] = []
    store.onExternalAppDecision = { id, allow in accepted.append("external:\(id):\(allow)") }
    store.onWebsitePermissionDecision = { id, allow in accepted.append("media:\(id):\(allow)") }
    store.onInstallDecision = { id, allow in accepted.append("install:\(id):\(allow)") }
    #expect(store.requestExternalApp(external))
    #expect(store.requestWebsitePermission(media))
    #expect(store.requestInstallation(install))
    store.nativeRendererGone(
      external.tabID, profileID: external.profileID, status: "crashed", exitCode: 1)
    #expect(accepted == ["external:x1:false", "media:x1:false", "install:x1:false"])
    store.resolveExternalApp(external.id, accepted: true)
    #expect(accepted.count == 3)
  }
}
