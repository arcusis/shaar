// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct DeviceChooserTests {
  @Test func parsesAnEngineChooserEventAndRejectsAPageTitle() throws {
    let store = try store()
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let parsed = try #require(
      request(store, kind: "deviceChooserRequested", transport: "bluetooth", id: "2"))
    #expect(parsed.id == "2")
    #expect(parsed.transport == .bluetooth)
    #expect(parsed.pageURL == tab.url)
    #expect(parsed.options.isEmpty)
    #expect(!parsed.canGrant)
    let populated = try #require(
      request(
        store, transport: "usb", id: "3",
        options: [["optionId": "opaque-1", "name": "Adapter"]], canGrant: true))
    #expect(populated.options.map(\.optionID) == ["opaque-1"])
    #expect(DeviceChooserIntake.isChooserID("2"))
    #expect(!DeviceChooserIntake.isChooserID(""))
    #expect(!DeviceChooserIntake.isChooserID("quote\"id"))
    #expect(
      DeviceChooserIntake.request(
        tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
        payload: ["title": "Docs"]) == nil)
  }

  @Test func emptyChooserEventsCannotBeGranted() throws {
    let store = try store()
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let serial = try #require(request(store, transport: "serial", id: "1"))
    #expect(!serial.bluetoothUnavailable)
    #expect(!serial.canGrant)
    let usb = try #require(request(store, transport: "usb", id: "3"))
    #expect(!usb.bluetoothUnavailable)
    #expect(!usb.canGrant)
    var mismatch = event(transport: "usb", id: "5", page: tab.url)
    mismatch["canGrant"] = true
    #expect(
      DeviceChooserIntake.request(
        tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
        payload: mismatch) == nil)
    var extra = event(transport: "hid", id: "6", page: tab.url)
    extra["previous"] = "HID"
    #expect(
      DeviceChooserIntake.request(
        tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
        payload: extra) == nil)
  }

  @Test func sheetCancelRejectsWithoutAnOptionID() throws {
    let store = try store()
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let request = try #require(self.request(store, transport: "hid", id: "4"))
    var decided: String??
    store.onDeviceChooserDecision = { _, optionID in decided = .some(optionID) }
    #expect(store.requestDeviceChooser(request))
    #expect(!store.requestDeviceChooser(request))
    let sheet = try #require(store.sheet)
    #expect(sheet.id == request.sheetID)
    #expect(sheet.isConsent)
    #expect(sheet.tabID == tab.id)
    #expect(sheet.matches(store.session))
    store.resolveDeviceChooser(request.id, optionID: nil)
    #expect(decided == .some(nil))
    #expect(store.deviceChooserRequests.isEmpty)
    _ = DeviceChooserConsent(store: store, request: request).body
    let populated = DeviceChooserRequest(
      id: "9", tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
      transport: .usb,
      options: [DeviceChooserOption(optionID: "option-a", title: "Adapter", detail: "USB")],
      bluetoothUnavailable: false, canGrant: true)
    _ = DeviceChooserConsent(store: store, request: populated, initialSelection: "option-a").body
    let unavailable = DeviceChooserRequest(
      id: "8", tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
      transport: .bluetooth, options: [], bluetoothUnavailable: true, canGrant: false)
    _ = DeviceChooserConsent(store: store, request: unavailable).body
  }

  @Test func anUpdateReplacesTheOpenDeviceList() throws {
    let store = try store()
    let opened = try #require(self.request(store, transport: "usb", id: "7"))
    #expect(store.requestDeviceChooser(opened))
    let updated = try #require(
      self.request(
        store, kind: "deviceChooserUpdated", transport: "usb", id: "7",
        options: [["optionId": "option-a", "name": "USB serial adapter"]], canGrant: true))
    #expect(updated.canGrant)
    #expect(store.updateDeviceChooser(updated))
    guard case .deviceChooser(let shown) = store.sheet else {
      Issue.record("The chooser sheet was not updated.")
      return
    }
    #expect(shown.options.map(\.title) == ["USB serial adapter"])
    #expect(shown.options.first?.optionID == "option-a")
    #expect(shown.canGrant)
    store.dismissDeviceChooserFromEngine(updated.id)
    #expect(store.deviceChooserRequests.isEmpty)
    #expect(store.sheet == nil)
  }

  @Test func selectionReturnsTheOpaqueOptionID() throws {
    let store = try store()
    let request = try #require(
      self.request(
        store, transport: "usb", id: "opaque-session",
        options: [["optionId": "opaque-option", "name": "Adapter"]], canGrant: true))
    var decided: String??
    store.onDeviceChooserDecision = { _, optionID in decided = .some(optionID) }
    #expect(store.requestDeviceChooser(request))
    store.resolveDeviceChooser(request.id, optionID: "opaque-option")
    #expect(decided == .some(.some("opaque-option")))
  }

  @Test func chooserRejectsDuplicateOrMalformedOpaqueOptionIDs() throws {
    let store = try store()
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let duplicate = event(
      transport: "usb", id: "8", page: tab.url,
      options: [
        ["optionId": "same", "name": "First"],
        ["optionId": "same", "name": "Second"],
      ], canGrant: true)
    #expect(
      DeviceChooserIntake.request(
        tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
        payload: duplicate) == nil)
    let malformed = event(
      transport: "usb", id: "9", page: tab.url,
      options: [["optionId": "invalid id", "name": "Adapter"]], canGrant: true)
    #expect(
      DeviceChooserIntake.request(
        tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
        payload: malformed) == nil)
  }

  private func store() throws -> BrowserStore {
    let store = BrowserStore()
    store.perform(.open(try #require(URL(string: "https://devices.example/chooser"))))
    return store
  }

  private func request(
    _ store: BrowserStore, kind: String = "deviceChooserRequested", transport: String, id: String,
    options: [[String: Any]] = [], canGrant: Bool = false
  ) -> DeviceChooserRequest? {
    guard let tab = store.session.selectedSpace.selectedTab else { return nil }
    return DeviceChooserIntake.request(
      tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
      payload: event(
        kind: kind, transport: transport, id: id, page: tab.url, options: options,
        canGrant: canGrant))
  }

  private func event(
    kind: String = "deviceChooserRequested", transport: String, id: String, page: URL,
    options: [[String: Any]] = [], canGrant: Bool = false
  ) -> [String: Any] {
    [
      "schemaVersion": 1, "kind": kind, "id": id, "transport": transport,
      "pageURL": page.absoluteString, "origin": page.absoluteString, "options": options,
      "canGrant": canGrant, "profileID": "profile", "tabID": "tab", "windowID": "window",
    ]
  }
}
