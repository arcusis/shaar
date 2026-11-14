// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Foundation
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct WebShareConsentTests {
  @Test func webShareSheetTitleIsVoiceOverHeading() {
    #expect(WebShareSheetContent.headingTraits == .isHeader)
  }

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
      "frameID": "0123456789abcdef0123456789abcdef",
      "userActivated": true,
      "title": title,
      "text": text,
    ]
    if let url { payload["url"] = url }
    let share = try #require(WebShareRequest(payload: payload))
    store.rememberPermissionFrame(
      share.tabID, frameID: share.frameID, origin: share.requestingOrigin)
    return share
  }

  @Test func parsesABoundShareAndBuildsTheSheetIdentity() throws {
    let store = openedStore()
    let share = try request(store)
    #expect(share.pageURL == URL(string: "https://example.com/article"))
    #expect(share.requestingOrigin == URL(string: "https://example.com"))
    #expect(share.sheetID == "web-share-\(share.id)")
    #expect(share.originLabel == "https://example.com")
    #expect(share.matches(store.session))
    #expect(
      !share.matches(
        store.session, frameID: "fedcba9876543210fedcba9876543210",
        origin: share.requestingOrigin))
    #expect(
      !share.matches(
        store.session, frameID: share.frameID, origin: URL(string: "https://other.example")))
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
      "userActivated": true,
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
      ("url", ("https://example.com/" + String(repeating: "a", count: 4096)) as Any),
      ("title", String(repeating: "a", count: 2049) as Any),
      ("files", ["notes.txt"] as Any),
      ("files", "notes.txt" as Any),
    ] {
      var malformed = valid
      malformed[key] = value
      #expect(WebShareRequest(payload: malformed) == nil)
    }

    for activation in [nil, false, 1] as [Any?] {
      var unactivated = valid
      unactivated["userActivated"] = activation
      #expect(WebShareRequest(payload: unactivated) == nil)
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

    for origin in [
      "http://127.0.0.2:3000",
      "http://dev.localhost:3000",
      "http://localhost.:3000",
      "http://[::1]:3000",
    ] {
      var loopback = valid
      loopback["origin"] = origin
      #expect(WebShareRequest(payload: loopback) != nil)
    }

    for origin in ["http://192.168.0.1", "http://localhost.example", "http://127.0.0.256"] {
      var remote = valid
      remote["origin"] = origin
      #expect(WebShareRequest(payload: remote) == nil)
    }
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
      "userActivated": true,
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

  @Test func dismissingTheShareSheetCancelsAnOutstandingPicker() {
    let anchor = WebShareAnchor()
    let picker = WebShareSystemPicker(items: ["Shared item"])
    var outcomes: [Bool] = []
    picker.outcome.onFinish = { outcomes.append($0) }
    anchor.picker = picker
    #expect(anchor.presentationGate.begin())

    anchor.cancel()

    #expect(outcomes == [false])
    #expect(anchor.picker == nil)
    #expect(picker.isClosed)
    #expect(!anchor.presentationGate.isActive)
  }

  @Test func sharingOutcomeWaitsForServiceCompletionAndFinishesOnce() {
    let gate = WebShareOutcomeGate()
    var outcomes: [Bool] = []
    gate.onFinish = { outcomes.append($0) }

    // Choosing a sharing service is not proof that the service succeeded.
    gate.chooseService(available: true)
    #expect(outcomes.isEmpty)
    gate.finish(true)
    gate.finish(false)
    #expect(outcomes == [true])
  }

  @Test func choosingASharingServiceWaitsForItsCompletionCallback() {
    let systemPicker = WebShareSystemPicker(items: ["Shared item"])
    let service = NSSharingService(
      title: "Test", image: NSImage(size: NSSize(width: 1, height: 1)),
      alternateImage: nil, handler: {})
    var outcomes: [Bool] = []
    systemPicker.outcome.onFinish = { outcomes.append($0) }

    systemPicker.sharingServicePicker(systemPicker.picker, didChoose: service)
    #expect(outcomes.isEmpty)

    systemPicker.sharingService(service, didShareItems: ["Shared item"])
    #expect(outcomes == [true])
  }

  @Test func serviceFailureCancelsAndFinishesTheShareOnce() {
    let systemPicker = WebShareSystemPicker(items: ["Shared item"])
    let service = NSSharingService(
      title: "Test", image: NSImage(size: NSSize(width: 1, height: 1)),
      alternateImage: nil, handler: {})
    var outcomes: [Bool] = []
    systemPicker.outcome.onFinish = { outcomes.append($0) }

    systemPicker.sharingService(
      service, didFailToShareItems: ["Shared item"],
      error: NSError(domain: "WebShareConsentTests", code: 1))
    systemPicker.sharingService(service, didShareItems: ["Shared item"])
    #expect(outcomes == [false])
  }

  @Test func cloudSharingCompletionResolvesTheShareAndTreatsErrorsAsCancellation() {
    let service = NSSharingService(
      title: "Test", image: NSImage(size: NSSize(width: 1, height: 1)),
      alternateImage: nil, handler: {})
    let successfulPicker = WebShareSystemPicker(items: ["Shared item"])
    var successfulOutcomes: [Bool] = []
    successfulPicker.outcome.onFinish = { successfulOutcomes.append($0) }

    successfulPicker.sharingService(service, didCompleteForItems: ["Shared item"], error: nil)

    #expect(successfulOutcomes == [true])

    let failedPicker = WebShareSystemPicker(items: ["Shared item"])
    var failedOutcomes: [Bool] = []
    failedPicker.outcome.onFinish = { failedOutcomes.append($0) }
    failedPicker.sharingService(
      service, didCompleteForItems: ["Shared item"],
      error: NSError(domain: "WebShareConsentTests", code: 2))
    failedPicker.sharingService(service, didShareItems: ["Shared item"])

    #expect(failedOutcomes == [false])
  }

  @Test func dismissingTheSystemPickerCancelsTheShareOnce() {
    let systemPicker = WebShareSystemPicker(items: ["Shared item"])
    var outcomes: [Bool] = []
    systemPicker.outcome.onFinish = { outcomes.append($0) }

    systemPicker.sharingServicePicker(systemPicker.picker, didChoose: nil)
    systemPicker.outcome.finish(true)

    #expect(outcomes == [false])
  }

  @Test func sharingPickerAssignsItsServiceOutcomeDelegateBeforeExecution() {
    let systemPicker = WebShareSystemPicker(items: ["Shared item"])
    let service = NSSharingService(
      title: "Test", image: NSImage(size: NSSize(width: 1, height: 1)),
      alternateImage: nil, handler: {})

    let delegate = systemPicker.sharingServicePicker(
      systemPicker.picker, delegateFor: service)

    #expect(delegate === systemPicker)
  }

  @Test func onlyOneSystemPickerCanBePresentedForAShareRequest() {
    let gate = WebSharePresentationGate()

    #expect(gate.begin())
    #expect(gate.isActive)
    #expect(!gate.begin())

    gate.finish()
    #expect(!gate.isActive)
    #expect(gate.begin())
  }

  @Test func changedFrameOrOriginCancelsAWebShare() throws {
    let store = openedStore()
    let share = try request(store)
    var outcome: WebShareOutcome?
    store.onWebShareDecision = { _, value in outcome = value }
    #expect(store.requestWebShare(share))

    store.rememberPermissionFrame(
      share.tabID, frameID: "fedcba9876543210fedcba9876543210",
      origin: URL(string: "https://other.example")!)
    #expect(outcome == .cancelled)

    store.resolveWebShare(share.id, outcome: .shared)
    #expect(outcome == .cancelled)
  }

  @Test func sameURLDocumentCommitCancelsAWebShare() throws {
    let store = openedStore()
    let share = try request(store)
    var outcome: WebShareOutcome?
    store.onWebShareDecision = { _, value in outcome = value }
    #expect(store.requestWebShare(share))

    store.nativeDocumentCommitted(share.tabID, profileID: share.profileID)
    #expect(outcome == .cancelled)

    store.resolveWebShare(share.id, outcome: .shared)

    #expect(outcome == .cancelled)
  }

  @Test func forgettingRejectedPromptBindingKeepsAnAcceptedShare() throws {
    let store = openedStore()
    let share = try request(store)
    #expect(store.requestWebShare(share))

    store.forgetPermissionFrame(share.tabID, matching: share.frameID)

    #expect(store.canPresentWebShare(share))
  }

  @Test func pickerPresentationRequiresTheCurrentPresentedFrame() throws {
    let store = openedStore()
    let share = try request(store)
    #expect(store.requestWebShare(share))
    #expect(store.canPresentWebShare(share))

    store.rememberPermissionFrame(
      share.tabID, frameID: "fedcba9876543210fedcba9876543210",
      origin: URL(string: "https://other.example")!)

    #expect(!store.canPresentWebShare(share))
  }

  @Test func rejectedQueueOverflowDoesNotInvalidatePresentedShare() throws {
    let store = openedStore()
    var first: WebShareRequest?
    for index in 0..<10 {
      let share = try request(store, id: "00000000-0000-0000-0000-00000000000\(index)")
      if index == 0 { first = share }
      #expect(store.requestWebShare(share))
    }
    let overflow = try request(store)
    #expect(!store.requestWebShare(overflow))
    #expect(try #require(first).sheetID == store.sheet?.id)
    #expect(store.canPresentWebShare(try #require(first)))
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
