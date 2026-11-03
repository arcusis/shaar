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

    let display = DesktopCaptureSource(id: "screen:1:0", name: "Main Display", kind: .display)
    let window = DesktopCaptureSource(id: "window:4:0", name: "Browser — Meet", kind: .window)
    #expect(display.label.contains("Main Display"))
    #expect(window.label.contains("Browser"))
    #expect(display.systemImageName == "display")
    #expect(window.systemImageName == "macwindow")

    let states = [
      DesktopCapturePickerContent(
        request: capture, sources: [], loading: true, error: nil, onSelect: { _ in },
        onCancel: {}),
      DesktopCapturePickerContent(
        request: capture, sources: [], loading: false, error: "Screen Recording unavailable",
        onSelect: { _ in }, onCancel: {}),
      DesktopCapturePickerContent(
        request: capture, sources: [], loading: false, error: nil, onSelect: { _ in },
        onCancel: {}),
      DesktopCapturePickerContent(
        request: capture, sources: [display, window], loading: false, error: nil,
        onSelect: { _ in }, onCancel: {}),
    ]
    for state in states { _ = state.body }
  }

  @Test func sourceDiscoveryHandlesDeniedAndUnavailableScreenAccess() async throws {
    let store = store()
    let capture = try request(store)
    let denied = DesktopCapturePicker(
      request: capture,
      store: store,
      hasScreenRecordingAccess: { false },
      shareableContent: { throw CocoaError(.fileReadUnknown) }
    )
    await denied.loadSources()

    let unavailable = DesktopCapturePicker(
      request: capture,
      store: store,
      hasScreenRecordingAccess: { true },
      shareableContent: { throw CocoaError(.fileReadUnknown) }
    )
    await unavailable.loadSources()
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
    store.resolveDesktopCapture(first.id, sourceID: "screen:1:0")
    #expect(decisions == ["\(first.id):screen:1:0"])
    #expect(store.sheet?.id == second.sheetID)

    store.resolveDesktopCapture(second.id, sourceID: "window:2:0")
    #expect(decisions == ["\(first.id):screen:1:0", "\(second.id):window:2:0"])

    let third = try request(store, id: UUID().uuidString)
    let fourth = try request(store, id: UUID().uuidString)
    #expect(store.requestDesktopCapture(third))
    #expect(store.requestDesktopCapture(fourth))
    store.resolveDesktopCapture(fourth.id, sourceID: "window:4:0")
    #expect(
      decisions == [
        "\(first.id):screen:1:0", "\(second.id):window:2:0", "\(fourth.id):cancel",
      ])
    #expect(store.sheet?.id == third.sheetID)

    store.dismissDesktopCapture(third.id)
    store.resolveDesktopCapture(third.id, sourceID: "window:3:0")
    #expect(
      decisions == [
        "\(first.id):screen:1:0", "\(second.id):window:2:0", "\(fourth.id):cancel",
      ])
    #expect(store.sheet == nil)
  }

  @Test func stalePageAndRendererFailureDenyDesktopCapture() throws {
    let browser = store()
    let stale = try request(browser, id: UUID().uuidString)
    var decisions: [String] = []
    browser.onDesktopCaptureDecision = { id, sourceID in
      decisions.append("\(id):\(sourceID ?? "cancel")")
    }

    #expect(browser.requestDesktopCapture(stale))
    browser.perform(.open(URL(string: "https://meet.google.com/another")!))
    browser.resolveDesktopCapture(stale.id, sourceID: "screen:1:0")
    #expect(decisions == ["\(stale.id):cancel"])

    let failedStore = store()
    let rendererFailure = try request(failedStore, id: UUID().uuidString)
    var rendererDecisions: [String?] = []
    failedStore.onDesktopCaptureDecision = { _, sourceID in rendererDecisions.append(sourceID) }
    #expect(failedStore.requestDesktopCapture(rendererFailure))
    failedStore.nativeRendererGone(
      rendererFailure.tabID, profileID: rendererFailure.profileID, status: "crashed", exitCode: 1)
    failedStore.resolveDesktopCapture(rendererFailure.id, sourceID: "window:1:0")
    #expect(rendererDecisions == [nil])
  }

  @Test func staleProfileAndNavigationInvalidateRequestOwnership() throws {
    let browser = store()
    let capture = try request(browser, id: UUID().uuidString)
    browser.cycleSpace(by: 1)
    #expect(!capture.matches(browser.session))

    let sameProfileStore = store()
    let sameProfileRequest = try request(sameProfileStore, id: UUID().uuidString)
    sameProfileStore.perform(.open(URL(string: "https://meet.google.com/another")!))
    #expect(!sameProfileRequest.matches(sameProfileStore.session))
  }
}
