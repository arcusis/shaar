// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct DeviceChooserEngineTests {
  @Test func requestedAndUpdatedEventsFlowThroughTheOwningEngine() throws {
    let runtime = ARCChromiumRuntime()
    let events = BrowserRuntimeEvents(runtime: runtime)
    let store = BrowserStore()
    store.perform(.open(try #require(URL(string: "https://devices.example/chooser"))))
    let engine = try BrowserEngine(events: events, windowID: "chooser-window", store: store)
    let tab = try #require(store.session.selectedSpace.selectedTab)
    #expect(events.router.bindTab(tab.id.uuidString, windowID: engine.windowID))

    var payload = Self.event(
      id: "chooser-1", kind: "deviceChooserRequested", tabID: tab.id,
      profileID: store.session.selectedSpace.profileID, url: tab.url)
    runtime.onDeviceChooserEvent?(payload)
    guard case .deviceChooser(let requested) = store.sheet else {
      Issue.record("The requested chooser was not presented")
      return
    }
    #expect(requested.id == "chooser-1")
    #expect(requested.options.isEmpty)
    #expect(!requested.canGrant)

    payload["kind"] = "deviceChooserUpdated"
    payload["options"] = [["optionId": "adapter-2", "name": "USB adapter"]]
    payload["canGrant"] = true
    runtime.onDeviceChooserEvent?(payload)
    guard case .deviceChooser(let updated) = store.sheet else {
      Issue.record("The chooser update was not presented")
      return
    }
    #expect(updated.id == requested.id)
    #expect(updated.options.map(\.title) == ["USB adapter"])
    #expect(updated.canGrant)

    payload["kind"] = "deviceChooserDismissed"
    runtime.onDeviceChooserEvent?(payload)
    #expect(store.sheet == nil)
    #expect(store.deviceChooserRequests.isEmpty)
  }

  @Test func malformedUpdateCancelsAndDismissesTheStaleChooser() throws {
    let runtime = ARCChromiumRuntime()
    let events = BrowserRuntimeEvents(runtime: runtime)
    events.onDeviceChooserResolution = { _, _, _ in }
    let store = BrowserStore()
    store.perform(.open(try #require(URL(string: "https://devices.example/chooser"))))
    let engine = try BrowserEngine(events: events, windowID: "chooser-window", store: store)
    let tab = try #require(store.session.selectedSpace.selectedTab)
    #expect(events.router.bindTab(tab.id.uuidString, windowID: engine.windowID))

    var payload = Self.event(
      id: "chooser-invalid-update", kind: "deviceChooserRequested", tabID: tab.id,
      profileID: store.session.selectedSpace.profileID, url: tab.url)
    runtime.onDeviceChooserEvent?(payload)
    #expect(store.sheet?.id == "chooser-chooser-invalid-update")

    payload["kind"] = "deviceChooserUpdated"
    payload["options"] = [["optionId": "usb-0", "name": "USB adapter"]]
    payload["canGrant"] = false
    runtime.onDeviceChooserEvent?(payload)

    #expect(store.sheet == nil)
    #expect(store.deviceChooserRequests.isEmpty)
  }

  @Test func foreignWindowCannotDismissTheOwnedChooser() throws {
    let runtime = ARCChromiumRuntime()
    let events = BrowserRuntimeEvents(runtime: runtime)
    let store = BrowserStore()
    store.perform(.open(try #require(URL(string: "https://devices.example/chooser"))))
    let engine = try BrowserEngine(events: events, windowID: "chooser-window", store: store)
    let tab = try #require(store.session.selectedSpace.selectedTab)
    #expect(events.router.bindTab(tab.id.uuidString, windowID: engine.windowID))

    var payload = Self.event(
      id: "window-owned-chooser", kind: "deviceChooserRequested", tabID: tab.id,
      profileID: store.session.selectedSpace.profileID, url: tab.url)
    runtime.onDeviceChooserEvent?(payload)
    #expect(store.sheet?.id == "chooser-window-owned-chooser")

    payload["kind"] = "deviceChooserDismissed"
    payload["windowID"] = "other-window"
    runtime.onDeviceChooserEvent?(payload)

    #expect(store.sheet?.id == "chooser-window-owned-chooser")
    #expect(store.deviceChooserRequests.map(\.id) == ["window-owned-chooser"])
  }

  @Test func updateWithoutStoreCancelsThePendingChooser() throws {
    let runtime = ARCChromiumRuntime()
    let events = BrowserRuntimeEvents(runtime: runtime)
    var store: BrowserStore? = BrowserStore()
    let (engine, tabID, profileID, pageURL) = try {
      let activeStore = try #require(store)
      activeStore.perform(.open(try #require(URL(string: "https://devices.example/chooser"))))
      let engine = try BrowserEngine(
        events: events, windowID: "chooser-window", store: activeStore)
      let tab = try #require(activeStore.session.selectedSpace.selectedTab)
      return (engine, tab.id, activeStore.session.selectedSpace.profileID, tab.url)
    }()
    #expect(events.router.bindTab(tabID.uuidString, windowID: engine.windowID))

    let payload = Self.event(
      id: "chooser-store-released", kind: "deviceChooserRequested", tabID: tabID,
      profileID: profileID, url: pageURL)
    runtime.onDeviceChooserEvent?(payload)

    var resolvedID: String?
    var resolvedWindowID: String?
    var resolvedIndex: Int??
    events.onDeviceChooserResolution = { id, windowID, index in
      resolvedID = id
      resolvedWindowID = windowID
      resolvedIndex = .some(index)
    }
    store = nil
    runtime.onDeviceChooserEvent?(Self.event(
      id: "chooser-store-released", kind: "deviceChooserUpdated", tabID: tabID,
      profileID: profileID, url: pageURL))

    #expect(resolvedID == "chooser-store-released")
    #expect(resolvedWindowID == "chooser-window")
    #expect(resolvedIndex == .some(nil))
  }

  private static func event(
    id: String, kind: String, tabID: UUID, profileID: UUID, url: URL
  ) -> [String: Any] {
    var origin = URLComponents(url: url, resolvingAgainstBaseURL: false)
    origin?.path = ""
    origin?.query = nil
    origin?.fragment = nil
    return [
      "schemaVersion": 1, "kind": kind, "id": id, "transport": "usb",
      "pageURL": url.absoluteString, "origin": origin?.string ?? url.absoluteString, "options": [],
      "canGrant": false, "profileID": profileID.uuidString,
      "tabID": tabID.uuidString, "windowID": "chooser-window",
    ]
  }
}
