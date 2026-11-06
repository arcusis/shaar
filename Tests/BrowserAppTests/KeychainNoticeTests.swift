// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import ObjectiveC
import ShaarEngineC
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct KeychainNoticeTests {
  private let message =
    "Browsing is available, but saved cookies and passwords are unavailable for this launch. Unlock your keychain or approve access, then restart Shaar."

  @Test func unavailableKeychainReachesExistingAndLaterWindows() throws {
    let runtime = ARCShaarRuntime()
    let events = BrowserRuntimeEvents(runtime: runtime)
    let firstStore = BrowserStore()
    let first = try BrowserEngine(events: events, windowID: "first", store: firstStore)
    send(
      runtime,
      payload: [
        "schemaVersion": 1, "kind": "storage.keychainUnavailable",
        "restartRequired": true, "persistentCookiesAvailable": false,
      ])
    #expect(first.notice == message)
    let laterStore = BrowserStore()
    let later = try BrowserEngine(events: events, windowID: "later", store: laterStore)
    #expect(later.notice == message)
  }

  @Test func startupNoticeSurvivesUntilFirstWindow() throws {
    let runtime = ARCShaarRuntime()
    let events = BrowserRuntimeEvents(runtime: runtime)
    send(
      runtime,
      payload: [
        "schemaVersion": 1, "kind": "storage.keychainUnavailable",
        "restartRequired": true, "persistentCookiesAvailable": false,
      ])
    let store = BrowserStore()
    let engine = try BrowserEngine(events: events, windowID: "first", store: store)
    #expect(engine.notice == message)
  }

  @Test func warningUsesLaunchLanguage() {
    ARCConfigureLocalization(BrowserLocalization.resourceBundleURL, "he")
    defer { ARCConfigureLocalization(BrowserLocalization.resourceBundleURL, "en") }
    let runtime = ARCShaarRuntime()
    send(
      runtime,
      payload: [
        "schemaVersion": 1, "kind": "storage.keychainUnavailable",
        "restartRequired": true, "persistentCookiesAvailable": false,
      ])
    #expect(runtime.startupNotice?.contains("צרור המפתחות") == true)
    #expect(runtime.startupNotice?.contains("Shaar") == true)
  }

  @Test func unrelatedOrMalformedEventsDoNotWarn() throws {
    let runtime = ARCShaarRuntime()
    let events = BrowserRuntimeEvents(runtime: runtime)
    let store = BrowserStore()
    let engine = try BrowserEngine(events: events, windowID: "first", store: store)
    for payload: [String: Any] in [
      ["schemaVersion": 1, "kind": "storage.other"],
      [
        "schemaVersion": 2, "kind": "storage.keychainUnavailable", "restartRequired": true,
        "persistentCookiesAvailable": false,
      ],
      ["schemaVersion": 1, "kind": "storage.keychainUnavailable"],
    ] { send(runtime, payload: payload) }
    #expect(engine.notice == nil)
  }

  private func send(_ runtime: ARCShaarRuntime, payload: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: payload)
    let selector = NSSelectorFromString("receiveEvent:")
    let method = class_getInstanceMethod(ARCShaarRuntime.self, selector)!
    typealias Receiver = @convention(c) (AnyObject, Selector, UnsafePointer<shaar_event>) -> Void
    let receive = unsafeBitCast(method_getImplementation(method), to: Receiver.self)
    data.withUnsafeBytes { bytes in
      var event = shaar_event()
      event.size = UInt32(MemoryLayout<shaar_event>.size)
      event.kind = SHAAR_EVENT_ENGINE
      event.payload_json = shaar_bytes(
        data: bytes.baseAddress!.assumingMemoryBound(to: CChar.self), size: data.count)
      receive(runtime, selector, &event)
    }
  }
}
