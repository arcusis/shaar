// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct WebShareConsentTests {
  private func openedStore() -> BrowserStore {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://example.com/article")!))
    return store
  }

  private func request(
    _ store: BrowserStore, id: String = UUID().uuidString, title: String = "A page",
    text: String = "Read this", url: String? = "https://example.com/article"
  ) throws -> WebShareRequest {
    let tab = try #require(store.session.selectedSpace.selectedTab)
    var payload: [String: Any] = [
      "id": id,
      "profileID": store.session.selectedSpace.profileID.uuidString,
      "tabID": tab.id.uuidString,
      "pageURL": tab.url.absoluteString,
      "origin": "https://example.com",
      "frameID": "main-frame",
      "title": title,
      "text": text,
    ]
    if let url { payload["url"] = url }
    return try #require(WebShareRequest(payload: payload))
  }

  @Test func parsesABoundShareAndBuildsTheSheetIdentity() throws {
    let store = openedStore()
    let share = try request(store)
    #expect(share.pageURL == URL(string: "https://example.com/article"))
    #expect(share.requestingOrigin == URL(string: "https://example.com"))
    #expect(share.sheetID == "web-share-\(share.id)")
    #expect(share.hostLabel == "example.com")
    #expect(share.matches(store.session))
    let items = share.sharingItems
    #expect((items[0] as? URL) == URL(string: "https://example.com/article"))
    #expect(items[1] as? String == "A page")
    #expect(items[2] as? String == "Read this")

    let sheet = BrowserSheet.webShare(share)
    #expect(sheet.id == share.sheetID)
    #expect(sheet.isConsent)
    #expect(sheet.tabID == share.tabID)
    #expect(sheet.matches(store.session))
    _ = WebShareSheetContent(request: share, onCancel: {}, onShare: {}).body
  }

  @Test func rejectsMalformedSharePayloads() throws {
    let store = openedStore()
    let original = try request(store)
    let valid: [String: Any] = [
      "id": original.id,
      "profileID": original.profileID.uuidString,
      "tabID": original.tabID.uuidString,
      "pageURL": original.pageURL.absoluteString,
      "origin": original.requestingOrigin.absoluteString,
      "frameID": original.frameID,
      "title": original.title,
      "text": original.text,
      "url": "https://example.com/article",
    ]
    #expect(WebShareRequest(payload: valid) != nil)

    for (key, value) in [
      ("id", "not-a-uuid" as Any),
      ("pageURL", "file:///tmp/page" as Any),
      ("origin", "http://example.com" as Any),
      ("origin", "https://example.com/path" as Any),
      ("frameID", "" as Any),
      ("url", "file:///tmp/secret" as Any),
      ("url", 4 as Any),
      ("title", String(repeating: "a", count: 2049) as Any),
      ("files", ["notes.txt"] as Any),
      ("files", "notes.txt" as Any),
    ] {
      var malformed = valid
      malformed[key] = value
      #expect(WebShareRequest(payload: malformed) == nil)
    }

    var empty = valid
    empty["title"] = ""
    empty["text"] = ""
    empty["url"] = ""
    #expect(WebShareRequest(payload: empty) == nil)

    var titleOnly = valid
    titleOnly.removeValue(forKey: "text")
    titleOnly.removeValue(forKey: "url")
    #expect(WebShareRequest(payload: titleOnly)?.url == nil)

    var local = valid
    local["origin"] = "http://localhost:3000"
    local["files"] = [Any]()
    #expect(WebShareRequest(payload: local) != nil)
  }

  @Test func aPageTitleCannotOpenTheShareSheet() throws {
    let store = openedStore()
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let marker = "\u{2060}shaar-prompt\u{2060}share\u{2060}\(UUID().uuidString)"
    store.nativeTabChanged(tab.id, url: tab.url, title: marker)
    #expect(store.sheet == nil)
    #expect(store.session.selectedSpace.selectedTab?.title == marker)
  }

  @Test func rejectsAnUnsolicitedShareAndRecordsPresentedOutcomes() throws {
    let store = openedStore()
    let share = try request(store)
    let payload: [String: Any] = [
      "id": UUID().uuidString,
      "profileID": share.profileID.uuidString,
      "tabID": UUID().uuidString,
      "pageURL": share.pageURL.absoluteString,
      "origin": share.requestingOrigin.absoluteString,
      "frameID": "other-frame",
      "title": "Other",
    ]
    let foreign = try #require(WebShareRequest(payload: payload))
    #expect(!store.requestWebShare(foreign))
    #expect(store.sheet == nil)

    var outcomes: [WebShareOutcome] = []
    store.onWebShareDecision = { _, outcome in outcomes.append(outcome) }
    #expect(store.requestWebShare(share))
    #expect(store.sheet?.id == share.sheetID)
    store.resolveWebShare(share.id, outcome: .shared)
    #expect(outcomes == [.shared])
    #expect(store.sheet == nil)

    let queued = try request(store, id: UUID().uuidString, title: "Queued", text: "", url: nil)
    let waiting = try request(store, id: UUID().uuidString, title: "Waiting", text: "", url: nil)
    #expect(store.requestWebShare(queued))
    #expect(store.requestWebShare(waiting))
    store.resolveWebShare(waiting.id, outcome: .shared)
    #expect(outcomes == [.shared, .cancelled])
    #expect(store.sheet?.id == queued.sheetID)
    store.sheetDidDismiss()
    #expect(outcomes == [.shared, .cancelled, .cancelled])
    #expect(store.sheet == nil)
  }

  @Test func hiddenFinishCancelsWithoutTheSystemPicker() throws {
    let store = openedStore()
    let share = try request(store)
    var outcome: WebShareOutcome?
    store.onWebShareDecision = { _, value in outcome = value }
    #expect(store.requestWebShare(share))
    WebShareSheet.finish(share, store: store, anchor: WebShareAnchor())
    #expect(outcome == .cancelled)
    #expect(store.sheet == nil)
  }

  @Test func stalePageAndRendererFailureCancelTheShare() throws {
    let store = openedStore()
    let stale = try request(store)
    var outcome: WebShareOutcome?
    store.onWebShareDecision = { _, value in outcome = value }
    #expect(store.requestWebShare(stale))
    store.perform(.open(URL(string: "https://example.com/other")!))
    store.resolveWebShare(stale.id, outcome: .shared)
    #expect(outcome == .cancelled)

    let failedStore = openedStore()
    let failed = try request(failedStore)
    var failedOutcome: WebShareOutcome?
    failedStore.onWebShareDecision = { _, value in failedOutcome = value }
    #expect(failedStore.requestWebShare(failed))
    failedStore.nativeRendererGone(
      failed.tabID, profileID: failed.profileID, status: "crashed", exitCode: 1)
    failedStore.resolveWebShare(failed.id, outcome: .shared)
    #expect(failedOutcome == .cancelled)
  }
}
