// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct PrintConsentTests {
  private let frameID = "0123456789abcdef0123456789abcdef"

  private func openedStore() -> BrowserStore {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://example.com/article")!))
    return store
  }

  private func request(_ store: BrowserStore) throws -> PrintRequest {
    let tab = try #require(store.session.selectedSpace.selectedTab)
    return try #require(
      PrintRequest(payload: [
        "schemaVersion": 1,
        "id": UUID().uuidString,
        "profileID": store.session.selectedSpace.profileID.uuidString,
        "tabID": tab.id.uuidString,
        "pageURL": tab.url.absoluteString,
        "origin": "https://example.com",
        "frameID": frameID,
        "title": "Article title",
      ]))
  }

  @Test func parsesAnOwnedPrintRequestAndBuildsItsConsentSheet() throws {
    let store = openedStore()
    let print = try request(store)
    store.rememberPermissionFrame(
      print.tabID, frameID: print.frameID, origin: print.requestingOrigin)

    #expect(print.sheetID == "print-\(print.id)")
    #expect(print.hostLabel == "example.com")
    #expect(print.matches(store.session))
    #expect(print.matches(store.session, frameID: frameID, origin: print.requestingOrigin))
    #expect(!print.matches(store.session, frameID: "fedcba9876543210fedcba9876543210"))
    #expect(
      !print.matches(store.session, frameID: frameID, origin: URL(string: "https://other.example")))

    let sheet = BrowserSheet.print(print)
    #expect(sheet.id == print.sheetID)
    #expect(sheet.isConsent)
    #expect(sheet.tabID == print.tabID)
    #expect(sheet.matches(store.session))
    _ = PrintConsentContent(request: print, onCancel: {}, onPrint: {}).body
  }

  @Test func rejectsMalformedPrintPayloads() throws {
    let store = openedStore()
    let print = try request(store)
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let valid: [String: Any] = [
      "schemaVersion": 1,
      "id": print.id,
      "profileID": print.profileID.uuidString,
      "tabID": print.tabID.uuidString,
      "pageURL": print.pageURL.absoluteString,
      "origin": print.requestingOrigin.absoluteString,
      "frameID": print.frameID,
      "title": print.title,
    ]
    #expect(PrintRequest(payload: valid) != nil)

    for (key, value) in [
      ("id", "not-a-uuid" as Any),
      ("pageURL", "file:///tmp/page" as Any),
      ("pageURL", ("https://example.com/" + String(repeating: "a", count: 4096)) as Any),
      ("origin", "http://example.com" as Any),
      ("origin", "https://example.com/path" as Any),
      ("frameID", "short" as Any),
      ("title", String(repeating: "a", count: 2049) as Any),
    ] {
      var malformed = valid
      malformed[key] = value
      #expect(PrintRequest(payload: malformed) == nil)
    }
    #expect(tab.id == print.tabID)
  }

  @Test func onlyThePresentedCurrentRequestCanContinueToPrint() throws {
    let store = openedStore()
    let print = try request(store)
    store.rememberPermissionFrame(
      print.tabID, frameID: print.frameID, origin: print.requestingOrigin)
    var decisions: [(String, Bool)] = []
    store.onPrintDecision = { id, accepted in decisions.append((id, accepted)) }

    #expect(store.requestPrint(print))
    #expect(store.sheet?.id == print.sheetID)
    store.resolvePrint(print.id, accepted: true)
    #expect(decisions.map(\.1) == [true])
    #expect(store.sheet == nil)

    let stale = try request(store)
    store.rememberPermissionFrame(
      stale.tabID, frameID: stale.frameID, origin: stale.requestingOrigin)
    #expect(store.requestPrint(stale))
    store.rememberPermissionFrame(
      stale.tabID, frameID: "fedcba9876543210fedcba9876543210",
      origin: URL(string: "https://other.example"))
    store.resolvePrint(stale.id, accepted: true)
    #expect(decisions.map(\.1) == [true, false])
    #expect(store.sheet == nil)
  }

  @Test func privateAndUnboundPrintRequestsAreDenied() throws {
    let privateStore = BrowserStore(privateSession: .fresh())
    privateStore.perform(.open(URL(string: "https://example.com/article")!))
    let privateRequest = try request(privateStore)
    privateStore.rememberPermissionFrame(
      privateRequest.tabID, frameID: privateRequest.frameID,
      origin: privateRequest.requestingOrigin)
    #expect(!privateStore.requestPrint(privateRequest))

    let store = openedStore()
    let unbound = try request(store)
    #expect(!store.requestPrint(unbound))
    #expect(store.sheet == nil)
  }
}
