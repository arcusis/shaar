// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct PrintConsentTests {
  @Test func printConsentTitleIsVoiceOverHeading() {
    #expect(PrintConsentContent.headingTraits == .isHeader)
  }

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

  @Test func printConsentOriginKeepsNonDefaultPort() throws {
    let store = openedStore()
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let print = try #require(
      PrintRequest(payload: [
        "schemaVersion": 1,
        "id": UUID().uuidString,
        "profileID": store.session.selectedSpace.profileID.uuidString,
        "tabID": tab.id.uuidString,
        "pageURL": "https://example.com:8443/article",
        "origin": "https://example.com:8443",
        "frameID": frameID,
        "title": "Article title",
      ]))

    #expect(print.hostLabel == "example.com:8443")
  }

  @Test func printConsentOriginBracketsIPv6AndKeepsItsPort() throws {
    let store = openedStore()
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let print = try #require(
      PrintRequest(payload: [
        "schemaVersion": 1,
        "id": UUID().uuidString,
        "profileID": store.session.selectedSpace.profileID.uuidString,
        "tabID": tab.id.uuidString,
        "pageURL": "https://[2001:db8::1]:8443/article",
        "origin": "https://[2001:db8::1]:8443",
        "frameID": frameID,
        "title": "Article title",
      ]))

    #expect(print.hostLabel == "[2001:db8::1]:8443")
  }

  @Test func sanitizesPageTitleBeforeShowingPrintConsent() throws {
    let store = openedStore()
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let payload: [String: Any] = [
      "schemaVersion": 1,
      "id": UUID().uuidString,
      "profileID": store.session.selectedSpace.profileID.uuidString,
      "tabID": tab.id.uuidString,
      "pageURL": tab.url.absoluteString,
      "origin": "https://example.com",
      "frameID": frameID,
      "title": "Report\u{202E}\nNext",
    ]

    #expect(try #require(PrintRequest(payload: payload)).title == "Report Next")
    var emojiPayload = payload
    emojiPayload["title"] = "Family 👨‍👩‍👧‍👦"
    #expect(try #require(PrintRequest(payload: emojiPayload)).title == "Family 👨‍👩‍👧‍👦")
    var longTitlePayload = payload
    longTitlePayload["title"] = String(repeating: "A", count: 512)
    #expect(try #require(PrintRequest(payload: longTitlePayload)).title.count == 256)
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
    var withoutTitle = valid
    withoutTitle.removeValue(forKey: "title")
    #expect(try #require(PrintRequest(payload: withoutTitle)).title.isEmpty)
    let oversizedOrigin = "https://" + String(repeating: "a.", count: 1020) + "com"
    #expect(oversizedOrigin.utf8.count > 2048)
    #expect(URL(string: oversizedOrigin)?.host != nil)
    var oversizedOriginPayload = valid
    oversizedOriginPayload["origin"] = oversizedOrigin
    #expect(PrintRequest(payload: oversizedOriginPayload) == nil)

    for unsupportedVersion: Any in [2, "1", true, NSNumber(value: 1.0), NSNull()] {
      var unsupported = valid
      unsupported["schemaVersion"] = unsupportedVersion
      #expect(PrintRequest(payload: unsupported) == nil)
    }
    var missingVersion = valid
    missingVersion.removeValue(forKey: "schemaVersion")
    #expect(PrintRequest(payload: missingVersion) == nil)

    for (key, value) in [
      ("id", "not-a-uuid" as Any),
      ("pageURL", "file:///tmp/page" as Any),
      ("pageURL", ("https://example.com/" + String(repeating: "a", count: 4096)) as Any),
      ("origin", "file:///tmp/page" as Any),
      ("origin", "https://example.com/path" as Any),
      ("origin", "https://example.com?unexpected=query" as Any),
      ("origin", "https://example.com#unexpected-fragment" as Any),
      ("origin", "https://user:password@example.com" as Any),
      ("frameID", "short" as Any),
      ("title", NSNull() as Any),
      ("title", String(repeating: "a", count: 2049) as Any),
    ] {
      var malformed = valid
      malformed[key] = value
      #expect(PrintRequest(payload: malformed) == nil)
    }
    #expect(tab.id == print.tabID)

    var httpOrigin = valid
    httpOrigin["origin"] = "http://example.com"
    #expect(PrintRequest(payload: httpOrigin) != nil)
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

    let cleared = try request(store)
    store.rememberPermissionFrame(
      cleared.tabID, frameID: cleared.frameID, origin: cleared.requestingOrigin)
    #expect(store.requestPrint(cleared))
    store.nativeDocumentCommitted(cleared.tabID, profileID: cleared.profileID)
    store.resolvePrint(cleared.id, accepted: true)
    #expect(decisions.map(\.1) == [true, false, false])
    #expect(store.sheet == nil)
  }

  @Test func rejectingQueueOverflowPreservesEarlierPrintConsent() throws {
    let store = openedStore()
    var firstRequest: PrintRequest?
    for _ in 0..<10 {
      let print = try request(store)
      if firstRequest == nil { firstRequest = print }
      store.rememberPermissionFrame(
        print.tabID, frameID: print.frameID, origin: print.requestingOrigin)
      #expect(store.requestPrint(print))
    }
    let first = try #require(firstRequest)

    let overflow = try request(store)
    store.rememberPermissionFrame(
      overflow.tabID, frameID: overflow.frameID, origin: overflow.requestingOrigin)
    #expect(!store.requestPrint(overflow))
    #expect(store.sheet?.id != overflow.sheetID)
    store.forgetPermissionFrame(overflow.tabID, matching: overflow.frameID)

    var decision: Bool?
    store.onPrintDecision = { id, accepted in
      if id == first.id { decision = accepted }
    }
    store.resolvePrint(first.id, accepted: true)
    #expect(decision == true)
  }

  @Test func duplicatePrintRequestIDIsRejectedWhileTheFirstIsQueued() throws {
    let store = openedStore()
    let print = try request(store)
    store.rememberPermissionFrame(
      print.tabID, frameID: print.frameID, origin: print.requestingOrigin)
    var decisions: [(String, Bool)] = []
    store.onPrintDecision = { id, accepted in decisions.append((id, accepted)) }

    #expect(store.requestPrint(print))
    #expect(!store.requestPrint(print))
    #expect(store.sheet?.id == print.sheetID)

    store.resolvePrint(print.id, accepted: true)
    #expect(decisions.map(\.0) == [print.id])
    #expect(decisions.map(\.1) == [true])
  }

  @Test func rendererCrashCancelsPendingPrintConsent() throws {
    let store = openedStore()
    let print = try request(store)
    store.rememberPermissionFrame(
      print.tabID, frameID: print.frameID, origin: print.requestingOrigin)
    var decisions: [(String, Bool)] = []
    store.onPrintDecision = { id, accepted in decisions.append((id, accepted)) }

    #expect(store.requestPrint(print))
    #expect(store.sheet?.id == print.sheetID)

    store.nativeRendererGone(
      print.tabID, profileID: print.profileID, status: "crashed", exitCode: 1)

    #expect(decisions.map(\.0) == [print.id])
    #expect(decisions.map(\.1) == [false])
    #expect(store.sheet == nil)
  }

  @Test func closingRequestingTabCancelsPendingPrintConsent() throws {
    let store = openedStore()
    let print = try request(store)
    store.rememberPermissionFrame(
      print.tabID, frameID: print.frameID, origin: print.requestingOrigin)
    var decision: Bool?
    store.onPrintDecision = { _, accepted in decision = accepted }

    #expect(store.requestPrint(print))
    store.closeTab(print.tabID)

    #expect(decision == false)
    #expect(store.sheet == nil)
  }

  @Test func navigationMakesPendingPrintConsentStale() throws {
    let store = openedStore()
    let print = try request(store)
    store.rememberPermissionFrame(
      print.tabID, frameID: print.frameID, origin: print.requestingOrigin)
    var decision: Bool?
    store.onPrintDecision = { _, accepted in decision = accepted }
    #expect(store.requestPrint(print))
    store.perform(.open(URL(string: "https://example.com/another-page")!))
    store.resolvePrint(print.id, accepted: true)
    #expect(decision == false)
    #expect(store.sheet == nil)
  }

  @Test func cancellingPrintConsentDeniesTheRequest() throws {
    let store = openedStore()
    let print = try request(store)
    store.rememberPermissionFrame(
      print.tabID, frameID: print.frameID, origin: print.requestingOrigin)
    var decision: Bool?
    store.onPrintDecision = { _, accepted in decision = accepted }
    #expect(store.requestPrint(print))
    store.resolvePrint(print.id, accepted: false)
    #expect(decision == false)
    #expect(store.sheet == nil)
  }

  @Test func printConsentRequestsArePresentedInOrder() throws {
    let store = openedStore()
    let first = try request(store)
    let second = try request(store)
    store.rememberPermissionFrame(
      first.tabID, frameID: first.frameID, origin: first.requestingOrigin)
    var decisions: [(String, Bool)] = []
    store.onPrintDecision = { id, accepted in decisions.append((id, accepted)) }
    #expect(store.requestPrint(first))
    #expect(store.requestPrint(second))
    #expect(store.sheet?.id == first.sheetID)
    store.resolvePrint(first.id, accepted: false)
    #expect(store.sheet?.id == second.sheetID)
    store.resolvePrint(second.id, accepted: true)
    #expect(decisions.map(\.0) == [first.id, second.id])
    #expect(decisions.map(\.1) == [false, true])
    #expect(store.sheet == nil)
  }

  @Test func navigationCommitCancelsPrintConsentBeforeFrameCanBeRebound() throws {
    let store = openedStore()
    let print = try request(store)
    let queuedPrint = try request(store)
    store.rememberPermissionFrame(
      print.tabID, frameID: print.frameID, origin: print.requestingOrigin)
    var decisions: [(String, Bool)] = []
    store.onPrintDecision = { id, accepted in decisions.append((id, accepted)) }

    #expect(store.requestPrint(print))
    #expect(store.requestPrint(queuedPrint))
    store.nativeDocumentCommitted(print.tabID, profileID: print.profileID)

    #expect(decisions.map(\.0) == [print.id, queuedPrint.id])
    #expect(decisions.map(\.1) == [false, false])
    #expect(store.sheet == nil)

    store.rememberPermissionFrame(
      print.tabID, frameID: print.frameID, origin: print.requestingOrigin)
    store.resolvePrint(print.id, accepted: true)
    store.resolvePrint(queuedPrint.id, accepted: true)
    #expect(decisions.map(\.1) == [false, false])
  }

  @Test func changedFrameBindingCancelsPendingPrintConsent() throws {
    let store = openedStore()
    let print = try request(store)
    store.rememberPermissionFrame(
      print.tabID, frameID: print.frameID, origin: print.requestingOrigin)
    var decisions: [(String, Bool)] = []
    store.onPrintDecision = { id, accepted in decisions.append((id, accepted)) }

    #expect(store.requestPrint(print))
    store.rememberPermissionFrame(
      print.tabID, frameID: "fedcba9876543210fedcba9876543210",
      origin: URL(string: "https://other.example"))

    #expect(decisions.map(\.0) == [print.id])
    #expect(decisions.map(\.1) == [false])
    #expect(store.sheet == nil)
  }

  @Test func changedOriginBindingCancelsPendingPrintConsent() throws {
    let store = openedStore()
    let print = try request(store)
    store.rememberPermissionFrame(
      print.tabID, frameID: print.frameID, origin: print.requestingOrigin)
    var decision: Bool?
    store.onPrintDecision = { _, accepted in decision = accepted }

    #expect(store.requestPrint(print))
    store.rememberPermissionFrame(
      print.tabID, frameID: print.frameID, origin: URL(string: "https://other.example"))

    #expect(decision == false)
    #expect(store.sheet == nil)
  }

  @Test func privatePrintRequestsAreBoundAndUnboundRequestsAreDenied() throws {
    let privateStore = BrowserStore(privateSession: .fresh())
    privateStore.perform(.open(URL(string: "https://example.com/article")!))
    let privateRequest = try request(privateStore)
    privateStore.rememberPermissionFrame(
      privateRequest.tabID, frameID: privateRequest.frameID,
      origin: privateRequest.requestingOrigin)
    var privateDecision: Bool?
    privateStore.onPrintDecision = { _, accepted in privateDecision = accepted }
    #expect(privateStore.requestPrint(privateRequest))
    privateStore.resolvePrint(privateRequest.id, accepted: true)
    #expect(privateDecision == true)

    let store = openedStore()
    let unbound = try request(store)
    #expect(!store.requestPrint(unbound))
    #expect(store.sheet == nil)
  }

  @Test func closingPrivatePrintTabCancelsItsPendingConsent() throws {
    let store = BrowserStore(privateSession: .fresh())
    store.perform(.open(URL(string: "https://example.com/article")!))
    let print = try request(store)
    store.rememberPermissionFrame(
      print.tabID, frameID: print.frameID, origin: print.requestingOrigin)
    var decision: Bool?
    store.onPrintDecision = { _, accepted in decision = accepted }

    #expect(store.requestPrint(print))
    store.closeTab(print.tabID)

    #expect(decision == false)
    #expect(store.sheet == nil)
  }
}
