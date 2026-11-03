// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct DesktopCaptureConsentTests {
  private func store() -> BrowserStore {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://meet.google.com/example")!))
    return store
  }

  private func request(_ store: BrowserStore, id: String = UUID().uuidString)
    throws -> DesktopCaptureRequest
  {
    let tab = try #require(store.session.selectedSpace.selectedTab)
    return try #require(
      DesktopCaptureRequest(payload: [
        "id": id,
        "profileID": store.session.selectedSpace.profileID.uuidString,
        "tabID": tab.id.uuidString,
        "pageURL": tab.url.absoluteString,
        "origin": "https://meet.google.com",
        "frameID": "main-frame",
      ]))
  }

  @Test func parsesSecureDesktopCaptureRequestAndBuildsConsentIdentity() throws {
    let store = store()
    let capture = try request(store, id: UUID().uuidString)

    #expect(capture.pageURL == URL(string: "https://meet.google.com/example"))
    #expect(capture.requestingOrigin == URL(string: "https://meet.google.com"))
    #expect(capture.frameID == "main-frame")
    #expect(capture.sheetID == "desktop-capture-\(capture.id)")
    #expect(capture.matches(store.session))

    let sheet = BrowserSheet.desktopCapture(capture)
    #expect(sheet.id == capture.sheetID)
    #expect(sheet.isConsent)
    #expect(sheet.tabID == capture.tabID)
    #expect(sheet.matches(store.session))
  }

  @Test func pickerStartsInItsLoadingState() throws {
    let store = store()
    let capture = try request(store)
    let picker = DesktopCapturePicker(request: capture, store: store)
    _ = picker.body
  }

  @Test func rejectsMalformedOrInsecureDesktopCapturePayloads() throws {
    let original = try request(store(), id: UUID().uuidString)
    let valid: [String: Any] = [
      "id": original.id,
      "profileID": original.profileID.uuidString,
      "tabID": original.tabID.uuidString,
      "pageURL": original.pageURL.absoluteString,
      "origin": original.requestingOrigin.absoluteString,
      "frameID": original.frameID,
    ]
    #expect(DesktopCaptureRequest(payload: valid) != nil)

    for (key, value) in [
      ("id", "not-a-uuid" as Any),
      ("profileID", "not-a-uuid" as Any),
      ("tabID", "not-a-uuid" as Any),
      ("pageURL", "file:///tmp/page" as Any),
      ("origin", "http://meet.google.com" as Any),
      ("origin", "https://meet.google.com/path" as Any),
      ("frameID", 4 as Any),
    ] {
      var malformed = valid
      malformed[key] = value
      #expect(DesktopCaptureRequest(payload: malformed) == nil)
    }

    for key in valid.keys {
      var missing = valid
      missing.removeValue(forKey: key)
      #expect(DesktopCaptureRequest(payload: missing) == nil)
    }

    var localHTTP = valid
    localHTTP["origin"] = "http://localhost:3000"
    #expect(DesktopCaptureRequest(payload: localHTTP) != nil)
  }

  @Test func resolvesOnlyPresentedCurrentRequestAndCancelsDismissedRequest() throws {
    let store = store()
    let first = try request(store, id: UUID().uuidString)
    let second = try request(store, id: UUID().uuidString)
    var decisions: [String] = []
    store.onDesktopCaptureDecision = { id, sourceID in
      decisions.append("\(id):\(sourceID ?? "cancel")")
    }

    #expect(store.requestDesktopCapture(first))
    #expect(store.requestDesktopCapture(second))
    #expect(store.sheet?.id == first.sheetID)
    store.resolveDesktopCapture(second.id, sourceID: "screen:1:0")
    #expect(decisions == ["\(second.id):cancel"])

    store.resolveDesktopCapture(first.id, sourceID: "screen:1:0")
    #expect(decisions == ["\(second.id):cancel", "\(first.id):screen:1:0"])
    #expect(store.sheet?.id == second.sheetID)

    store.dismissDesktopCapture(second.id)
    store.resolveDesktopCapture(second.id, sourceID: "window:1:0")
    #expect(
      decisions == [
        "\(second.id):cancel", "\(first.id):screen:1:0", "\(second.id):cancel",
      ])
    #expect(store.sheet == nil)
  }

  @Test func stalePageAndRendererFailureDenyDesktopCapture() throws {
    let store = store()
    let stale = try request(store, id: UUID().uuidString)
    let failed = try request(store, id: UUID().uuidString)
    var decisions: [String] = []
    store.onDesktopCaptureDecision = { id, sourceID in
      decisions.append("\(id):\(sourceID ?? "cancel")")
    }

    #expect(store.requestDesktopCapture(stale))
    store.perform(.open(URL(string: "https://meet.google.com/another")!))
    store.resolveDesktopCapture(stale.id, sourceID: "screen:1:0")
    #expect(decisions == ["\(stale.id):cancel"])

    #expect(store.requestDesktopCapture(failed))
    store.nativeRendererGone(
      failed.tabID, profileID: failed.profileID, status: "crashed", exitCode: 1)
    store.resolveDesktopCapture(failed.id, sourceID: "window:1:0")
    #expect(decisions == ["\(stale.id):cancel", "\(failed.id):cancel"])
  }
}
