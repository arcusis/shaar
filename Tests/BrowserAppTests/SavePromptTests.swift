// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct SavePromptTests {
  private func store() -> BrowserStore {
    let store = BrowserStore()
    store.perform(.open(URL(string: "http://127.0.0.1:9/password")!))
    return store
  }

  private func request(
    _ store: BrowserStore, id: String = "1", kind: SavePromptRequest.Kind = .password,
    update: Bool = false, detail: String = "parity-user", profileID: UUID? = nil,
    tabID: UUID? = nil
  ) throws -> SavePromptRequest {
    let tab = try #require(store.session.selectedSpace.selectedTab)
    return try #require(
      SavePromptRequest(payload: [
        "schemaVersion": 1,
        "kind": "savePromptRequested",
        "id": id,
        "prompt": kind.rawValue,
        "origin": "http://127.0.0.1:9",
        "pageURL": "http://127.0.0.1:9/password",
        "detail": detail,
        "update": update,
        "profileID": (profileID ?? store.session.selectedSpace.profileID).uuidString,
        "tabID": (tabID ?? tab.id).uuidString,
        "windowID": "window-1",
      ]))
  }

  @Test func onePromptIsShownAndASecondIsRejected() throws {
    let store = store()
    let first = try request(store)
    let second = try request(store, id: "2", kind: .card, detail: "Visa •••• 1111")
    var decisions: [String] = []
    store.onSavePromptDecision = { id, decision in decisions.append("\(id):\(decision.rawValue)") }
    #expect(store.requestSavePrompt(first))
    #expect(store.savePrompt == first)
    #expect(store.requestSavePrompt(first))
    #expect(!store.requestSavePrompt(second))
    #expect(store.savePrompt == first)
    store.resolveSavePrompt(first.id, decision: .save)
    #expect(decisions == ["1:save"])
    #expect(store.savePrompt == nil)
    store.resolveSavePrompt(first.id, decision: .save)
    #expect(decisions == ["1:save"])
  }

  @Test func duplicateIDWithDifferentDetailsIsRejected() throws {
    let store = store()
    let original = try request(store)
    let changed = try request(store, detail: "attacker-controlled")
    #expect(store.requestSavePrompt(original))
    #expect(!store.requestSavePrompt(changed))
    #expect(store.savePrompt == original)
  }

  @Test func leavingTheOriginTurnsSaveIntoDismiss() throws {
    let store = store()
    let request = try request(store)
    var decisions: [SavePromptRequest.Decision] = []
    store.onSavePromptDecision = { _, decision in decisions.append(decision) }
    #expect(store.requestSavePrompt(request))
    let tab = try #require(store.session.selectedSpace.selectedTab)
    store.nativeTabChanged(tab.id, url: URL(string: "https://example.com/")!, title: "Other")
    #expect(store.savePrompt == nil)
    #expect(decisions == [.dismiss])
  }

  @Test func navigatingToAnotherPathDismissesTheOfferImmediately() throws {
    let store = store()
    let request = try request(store)
    var decisions: [SavePromptRequest.Decision] = []
    store.onSavePromptDecision = { _, decision in decisions.append(decision) }
    #expect(store.requestSavePrompt(request))
    let tab = try #require(store.session.selectedSpace.selectedTab)
    store.nativeTabChanged(tab.id, url: URL(string: "http://127.0.0.1:9/account")!, title: "Account")
    #expect(store.savePrompt == nil)
    #expect(decisions == [.dismiss])
  }

  @Test func queryAndFragmentChangesKeepTheSameOfferCurrent() throws {
    let store = store()
    let request = try request(store)
    var decisions: [SavePromptRequest.Decision] = []
    store.onSavePromptDecision = { _, decision in decisions.append(decision) }
    #expect(store.requestSavePrompt(request))
    let tab = try #require(store.session.selectedSpace.selectedTab)
    store.nativeTabChanged(
      tab.id, url: URL(string: "http://127.0.0.1:9/password?next=/account#continue")!,
      title: "Password")
    #expect(store.savePrompt == request)
    store.resolveSavePrompt(request.id, decision: .save)
    #expect(decisions == [.save])
  }

  @Test func switchingTabsDismissesTheOffer() throws {
    let store = store()
    let request = try request(store)
    var decisions: [SavePromptRequest.Decision] = []
    store.onSavePromptDecision = { _, decision in decisions.append(decision) }
    #expect(store.requestSavePrompt(request))
    store.perform(.open(URL(string: "http://127.0.0.1:9/login")!))
    #expect(store.savePrompt == nil)
    #expect(decisions == [.dismiss])
  }

  @Test func requestMustMatchTheActiveProfileAndTab() throws {
    let store = store()
    #expect(try request(store).matches(store.session))
    #expect(!(try request(store, profileID: UUID()).matches(store.session)))
    #expect(!(try request(store, tabID: UUID()).matches(store.session)))
  }

  @Test func aPrivateWindowRejectsTheOffer() throws {
    let session = try BrowserSession.privateWindow(sourceProfileID: UUID(), firstTabID: UUID())
    let store = BrowserStore(privateSession: session)
    store.perform(.open(URL(string: "http://127.0.0.1:9/password")!))
    let request = try request(store)
    #expect(!request.matches(store.session, inPrivateWindow: true))
    #expect(!store.requestSavePrompt(request))
    #expect(store.savePrompt == nil)
  }

  @Test func neverForACardIsDismissed() throws {
    let store = store()
    let card = try request(store, kind: .card, detail: "Visa •••• 1111")
    var decisions: [SavePromptRequest.Decision] = []
    store.onSavePromptDecision = { _, decision in decisions.append(decision) }
    #expect(store.requestSavePrompt(card))
    store.resolveSavePrompt(card.id, decision: .never)
    #expect(decisions == [.dismiss])
  }

  @Test func promptShowsTheFullOriginIncludingNonDefaultPort() throws {
    let store = store()
    let request = try request(store)
    let panel = ShaarSavePromptPanel()
    panel.show(request) { _ in }
    let labels = SavePromptButtons.textFields(panel.contentView).map(\.stringValue)
    #expect(labels.contains("http://127.0.0.1:9"))
  }

  @Test func saveButtonsSendTheMatchingDecisionAndStayOffscreen() throws {
    let store = store()
    let password = try request(store)
    let panel = ShaarSavePromptPanel()
    panel.setFrameOrigin(SavePromptPlacement.offscreen)
    var decision: SavePromptRequest.Decision?
    panel.show(password) { decision = $0 }
    let save = try #require(
      SavePromptButtons.find(panel.contentView, identifier: ShaarSavePromptPanel.saveIdentifier))
    let never = try #require(
      SavePromptButtons.find(panel.contentView, identifier: ShaarSavePromptPanel.neverIdentifier))
    #expect(save.title == "Save")
    #expect(never.title == "Never for this site")
    #expect(!panel.isVisible)
    #expect(!SavePromptPlacement.browserIsOnScreen(panel))
    save.performClick(nil)
    #expect(decision == .save)
    panel.orderOut(nil)

    let card = try request(store, id: "3", kind: .card, detail: "Visa •••• 1111")
    panel.show(card) { _ in }
    #expect(
      SavePromptButtons.find(panel.contentView, identifier: ShaarSavePromptPanel.neverIdentifier)
        == nil)
    #expect(
      SavePromptButtons.find(panel.contentView, identifier: ShaarSavePromptPanel.saveIdentifier)
        != nil)
  }

  @Test func promptViewsRenderOffscreen() throws {
    let store = store()
    let offers: [(String, SavePromptRequest)] = [
      ("password", try request(store)),
      ("password-update", try request(store, id: "4", update: true)),
      ("card", try request(store, id: "5", kind: .card, detail: "Visa •••• 1111")),
      (
        "address",
        try request(
          store, id: "6", kind: .address, detail: "Parity Probe, 1 Loopback Road, Local")
      ),
    ]
    let directory = ProcessInfo.processInfo.environment["SHAAR_SAVE_PROMPT_EVIDENCE"]
      .map { URL(fileURLWithPath: $0, isDirectory: true) }
    if let directory {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    for (name, request) in offers {
      let panel = ShaarSavePromptPanel()
      panel.show(request) { _ in }
      panel.setFrameOrigin(SavePromptPlacement.offscreen)
      let view = try #require(panel.contentView)
      flattenLayers(view)
      view.layoutSubtreeIfNeeded()
      panel.orderFront(nil)
      panel.displayIfNeeded()
      #expect(panel.isVisible)
      #expect(!NSScreen.screens.contains { $0.frame.intersects(panel.frame) })
      let bitmap = try VisualCapture.render(
        view, to: FileManager.default.temporaryDirectory.appending(path: "save-prompt-\(name).png"))
      panel.orderOut(nil)
      #expect(bitmap.pixelsWide == 360)
      #expect(bitmap.pixelsHigh == 196)
      #expect(!panel.isVisible)
      #expect(!SavePromptPlacement.browserIsOnScreen(panel))
      if let directory, let data = bitmap.representation(using: .png, properties: [:]) {
        try data.write(to: directory.appending(path: "after-\(name).png"))
      }
    }
  }

  private func flattenLayers(_ view: NSView) {
    view.wantsLayer = false
    for child in view.subviews { flattenLayers(child) }
  }
}
