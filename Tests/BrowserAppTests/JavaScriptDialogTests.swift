// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct JavaScriptDialogTests {
  @Test func dialogTitleIsVoiceOverHeading() {
    #expect(JavaScriptDialogSheet.titleAccessibilityTraits == .isHeader)
  }

  private func openedStore() -> BrowserStore {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://example.com/dialog")!))
    return store
  }

  private func request(_ store: BrowserStore, kind: JavaScriptDialogKind = .prompt)
    throws -> JavaScriptDialogRequest
  {
    let tab = try #require(store.session.selectedSpace.selectedTab)
    return try #require(JavaScriptDialogRequest(payload: [
      "schemaVersion": 1,
      "id": "request-1",
      "profileID": store.session.selectedSpace.profileID.uuidString,
      "tabID": tab.id.uuidString,
      "pageURL": tab.url.absoluteString,
      "origin": "https://example.com",
      "dialogType": kind.rawValue,
      "message": "Enter a value",
      "defaultPrompt": "initial",
    ]))
  }

  @Test func parsesAndPresentsDialogForSelectedTab() throws {
    let store = openedStore()
    let request = try request(store)
    #expect(request.kind == .prompt)
    #expect(request.matches(store.session))
    #expect(store.requestJavaScriptDialog(request))
    #expect(store.sheet?.id == request.sheetID)
    #expect(store.sheet?.matches(store.session) == true)
    _ = JavaScriptDialogSheet(request: request, store: store).body
  }

  @Test func beforeUnloadDialogMatchesItsOutgoingTabDuringNavigation() throws {
    let store = openedStore()
    let request = try request(store, kind: .beforeUnload)
    let destination = URL(string: "https://destination.example/next")!
    var session = store.session
    let didUpdate = session.updateTab(request.tabID, url: destination, title: "Next")
    #expect(didUpdate)
    store.session = session
    #expect(request.matches(store.session))

    var decision: (String, Bool, String?)?
    store.onJavaScriptDialogDecision = { decision = ($0, $1, $2) }
    #expect(store.requestJavaScriptDialog(request))
    #expect(store.sheet?.id == request.sheetID)
    store.resolveJavaScriptDialog(request.id, accepted: true, input: nil)
    #expect(decision?.0 == request.id)
    #expect(decision?.1 == true)
  }

  @Test func beforeUnloadDialogStillMatchesWhenClosingChangesTheSelectedTab() throws {
    let store = openedStore()
    let request = try request(store, kind: .beforeUnload)
    store.perform(.open(URL(string: "https://destination.example/next")!))

    #expect(store.session.selectedPage?.tab.id != request.tabID)
    #expect(request.matches(store.session))
    #expect(store.requestJavaScriptDialog(request))
    #expect(store.sheet?.id == request.sheetID)
  }

  @Test func cancellingBeforeUnloadAllowsAnotherCloseAttempt() throws {
    let store = openedStore()
    let request = try request(store, kind: .beforeUnload)
    var closeAttempts = 0
    store.onCloseTab = { _ in closeAttempts += 1 }

    store.closeTab(request.tabID)
    #expect(closeAttempts == 1)
    #expect(store.requestJavaScriptDialog(request))
    store.resolveJavaScriptDialog(request.id, accepted: false, input: nil)
    store.closeTab(request.tabID)
    #expect(closeAttempts == 2)
  }

  @Test func engineDismissedBeforeUnloadAllowsAnotherCloseAttempt() throws {
    let store = openedStore()
    let request = try request(store, kind: .beforeUnload)
    var closeAttempts = 0
    store.onCloseTab = { _ in closeAttempts += 1 }

    store.closeTab(request.tabID)
    #expect(store.requestJavaScriptDialog(request))
    store.dismissJavaScriptDialog(request.id)
    store.closeTab(request.tabID)
    #expect(closeAttempts == 2)
  }

  @Test func rejectsMalformedDialogPayload() throws {
    let store = openedStore()
    let request = try request(store)
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let valid: [String: Any] = [
      "schemaVersion": 1, "id": request.id,
      "profileID": request.profileID.uuidString, "tabID": request.tabID.uuidString,
      "pageURL": request.pageURL.absoluteString, "origin": request.origin,
      "dialogType": request.kind.rawValue, "message": request.message,
      "defaultPrompt": request.defaultPrompt,
    ]
    for (key, value) in [
      ("id", "" as Any), ("pageURL", "file:///tmp/page" as Any),
      ("dialogType", "unknown" as Any), ("message", String(repeating: "a", count: 4097) as Any),
    ] {
      var malformed = valid
      malformed[key] = value
      #expect(JavaScriptDialogRequest(payload: malformed) == nil)
    }
    #expect(tab.id == request.tabID)
  }

  @Test func onlyPresentedCurrentDialogCanResolve() throws {
    let store = openedStore()
    let request = try request(store)
    var decisions: [(String, Bool, String?)] = []
    store.onJavaScriptDialogDecision = { decisions.append(($0, $1, $2)) }
    #expect(store.requestJavaScriptDialog(request))
    store.resolveJavaScriptDialog(request.id, accepted: true, input: "answer")
    #expect(decisions.count == 1)
    #expect(decisions[0].0 == request.id)
    #expect(decisions[0].1)
    #expect(decisions[0].2 == "answer")
    #expect(store.sheet == nil)
  }

  @Test func engineDismissalClosesTheSheetWithoutSendingASecondReply() throws {
    let store = openedStore()
    let request = try request(store, kind: .confirm)
    var replies = 0
    store.onJavaScriptDialogDecision = { _, _, _ in replies += 1 }
    #expect(store.requestJavaScriptDialog(request))
    store.dismissJavaScriptDialog(request.id)
    #expect(store.sheet == nil)
    #expect(replies == 0)
  }
}
