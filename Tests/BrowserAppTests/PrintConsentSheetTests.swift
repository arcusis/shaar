// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct PrintConsentSheetTests {
  private let frameID = "0123456789abcdef0123456789abcdef"

  private func presentedSheet() throws -> (PrintConsentSheet, BrowserStore, String) {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://example.com/article")!))
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let id = UUID().uuidString
    let request = try #require(
      PrintRequest(payload: [
        "schemaVersion": 1,
        "id": id,
        "profileID": store.session.selectedSpace.profileID.uuidString,
        "tabID": tab.id.uuidString,
        "pageURL": tab.url.absoluteString,
        "origin": "https://example.com",
        "frameID": frameID,
        "title": "Article title",
      ]))
    store.rememberPermissionFrame(tab.id, frameID: frameID, origin: request.requestingOrigin)
    #expect(store.requestPrint(request))
    return (PrintConsentSheet(request: request, store: store), store, id)
  }

  @Test func cancelResolvesThePresentedRequestAsDenied() throws {
    let (sheet, store, id) = try presentedSheet()
    var decisions: [(String, Bool)] = []
    store.onPrintDecision = { decisions.append(($0, $1)) }

    sheet.cancel()

    #expect(decisions.map(\.0) == [id])
    #expect(decisions.map(\.1) == [false])
    #expect(store.sheet == nil)
  }

  @Test func continueToPrintAcceptsThePresentedCurrentRequest() throws {
    let (sheet, store, id) = try presentedSheet()
    var decisions: [(String, Bool)] = []
    store.onPrintDecision = { decisions.append(($0, $1)) }

    sheet.continueToPrint()

    #expect(decisions.map(\.0) == [id])
    #expect(decisions.map(\.1) == [true])
    #expect(store.sheet == nil)
  }
}
