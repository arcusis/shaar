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
    #expect(DeviceChooserIntake.isChooserID("2"))
    #expect(!DeviceChooserIntake.isChooserID(""))
    #expect(!DeviceChooserIntake.isChooserID("quote\"id"))
    #expect(DeviceChooserIntake.isChooserID(String(repeating: "a", count: 64)))
    #expect(!DeviceChooserIntake.isChooserID(String(repeating: "a", count: 65)))
    #expect(
      DeviceChooserIntake.request(
        tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
        payload: ["title": "Docs"]) == nil)
  }

  @Test func chooserEventsRejectBooleanSchemaVersions() throws {
    let store = try store()
    let tab = try #require(store.session.selectedSpace.selectedTab)
    var payload = event(transport: "usb", id: "boolean-version", page: tab.url)
    payload["schemaVersion"] = true

    #expect(
      DeviceChooserIntake.request(
        tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
        payload: payload) == nil)
  }

  @Test func chooserDisplaysTheRequestingFrameOrigin() throws {
    let store = try store()
    let tab = try #require(store.session.selectedSpace.selectedTab)
    var payload = event(transport: "usb", id: "embedded", page: tab.url)
    payload["origin"] = "https://device-frame.example:8443/chooser"

    let request = try #require(
      DeviceChooserIntake.request(
        tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
        payload: payload))

    #expect(request.pageURL.host() == "devices.example")
    #expect(request.displayOrigin == "https://device-frame.example:8443")

    payload["origin"] = "http://device-frame.example:8443/chooser"
    let insecureOrigin = try #require(
      DeviceChooserIntake.request(
        tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
        payload: payload))
    #expect(insecureOrigin.displayOrigin == "http://device-frame.example:8443")
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

  @Test func deviceNamesCannotInjectLineBreaksOrBidirectionalOverrides() throws {
    let store = try store()
    let unsafeName = "Adapter\n\u{202E}txt.exe"
    let request = try #require(
      self.request(
        store, transport: "usb", id: "unsafe-name",
        options: [["index": 0, "name": unsafeName]], canGrant: true))

    #expect(request.options.first?.title == "Adapter\u{FFFD}\u{FFFD}txt.exe")
  }

  @Test func deviceNamesPreserveJoinersUsedByEmojiAndShaping() throws {
    let store = try store()
    let name = "👩‍💻 فارسی\u{200C}زبان"
    let request = try #require(
      self.request(
        store, transport: "usb", id: "joined-name",
        options: [["index": 0, "name": name]], canGrant: true))

    #expect(request.options.first?.title == name)
  }

  @Test func chooserRejectsFractionalAndOutOfRangeOptionIndexes() throws {
    let store = try store()
    let tab = try #require(store.session.selectedSpace.selectedTab)

    for invalidIndex: Any in [0.5, 64] {
      let payload = event(
        transport: "usb", id: "invalid-index", page: tab.url,
        options: [["index": invalidIndex, "name": "Adapter"]], canGrant: true)
      #expect(
        DeviceChooserIntake.request(
          tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
          payload: payload) == nil)
    }
  }

  @Test func unnamedDevicesHaveAVisibleFallbackLabel() throws {
    let store = try store()
    let request = try #require(
      self.request(
        store, transport: "usb", id: "unnamed-device",
        options: [
          ["index": 0, "name": ""],
          ["index": 1, "name": "   "],
        ], canGrant: true))

    #expect(
      request.options.map(\.title) == [
        PanelsL10n.string("Unknown device"), PanelsL10n.string("Unknown device"),
      ])
  }

  @Test func chooserEventsRejectFloatingPointSchemaVersions() throws {
    let store = try store()
    let tab = try #require(store.session.selectedSpace.selectedTab)
    var payload = event(transport: "usb", id: "floating-version", page: tab.url)
    payload["schemaVersion"] = NSNumber(value: 1.0)

    #expect(
      DeviceChooserIntake.request(
        tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
        payload: payload) == nil)
  }

  @Test func sheetCancelRejectsWithoutADeviceIndex() throws {
    let store = try store()
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let request = try #require(self.request(store, transport: "hid", id: "4"))
    var decided: Int??
    store.onDeviceChooserDecision = { _, index in decided = .some(index) }
    #expect(store.requestDeviceChooser(request))
    #expect(!store.requestDeviceChooser(request))
    let sheet = try #require(store.sheet)
    #expect(sheet.id == request.sheetID)
    #expect(sheet.isConsent)
    #expect(sheet.tabID == tab.id)
    #expect(sheet.matches(store.session))
    store.resolveDeviceChooser(request.id, optionIndex: 0)
    #expect(decided == .some(nil))
    #expect(store.deviceChooserRequests.isEmpty)
    _ = DeviceChooserConsent(store: store, request: request).body
    let populated = DeviceChooserRequest(
      id: "9", tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
      origin: tab.url, transport: .usb,
      options: [DeviceChooserOption(index: 0, title: "Adapter", detail: "USB")],
      bluetoothUnavailable: false, canGrant: true)
    _ = DeviceChooserConsent(store: store, request: populated, initialSelection: 0).body
    let unavailable = DeviceChooserRequest(
      id: "8", tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
      origin: tab.url, transport: .bluetooth, options: [], bluetoothUnavailable: true,
      canGrant: false)
    _ = DeviceChooserConsent(store: store, request: unavailable).body
  }

  @Test func navigatingAwayCancelsThePresentedChooser() throws {
    let store = try store()
    let request = try #require(
      self.request(
        store, transport: "usb", id: "navigation-cancel",
        options: [["index": 0, "name": "Adapter"]], canGrant: true))
    var decided: Int??
    store.onDeviceChooserDecision = { _, index in decided = .some(index) }

    #expect(store.requestDeviceChooser(request))
    store.perform(.open(try #require(URL(string: "https://elsewhere.example/"))))

    #expect(decided == .some(nil))
    #expect(store.sheet == nil)
  }

  @Test func anUpdateReplacesTheOpenDeviceList() throws {
    let store = try store()
    let opened = try #require(self.request(store, transport: "usb", id: "7"))
    #expect(store.requestDeviceChooser(opened))
    let updated = try #require(
      self.request(
        store, kind: "deviceChooserUpdated", transport: "usb", id: "7",
        options: [["index": 0, "name": "USB serial adapter"]], canGrant: true))
    #expect(updated.canGrant)
    #expect(store.updateDeviceChooser(updated))
    guard case .deviceChooser(let shown) = store.sheet else {
      Issue.record("The chooser sheet was not updated.")
      return
    }
    #expect(shown.options.map(\.title) == ["USB serial adapter"])
    #expect(shown.canGrant)
    store.dismissDeviceChooserFromEngine(updated.id)
    #expect(store.deviceChooserRequests.isEmpty)
    #expect(store.sheet == nil)
  }

  @Test func chooserUpdateCannotChangeTransportOrRequestingOrigin() throws {
    let store = try store()
    let opened = try #require(self.request(store, transport: "usb", id: "identity"))
    #expect(store.requestDeviceChooser(opened))

    let wrongTransport = try #require(
      self.request(store, kind: "deviceChooserUpdated", transport: "hid", id: "identity"))
    #expect(!store.updateDeviceChooser(wrongTransport))

    let tab = try #require(store.session.selectedSpace.selectedTab)
    var payload = event(
      kind: "deviceChooserUpdated", transport: "usb", id: "identity", page: tab.url)
    payload["origin"] = "https://other-frame.example/"
    let wrongOrigin = try #require(
      DeviceChooserIntake.request(
        tabID: tab.id, profileID: store.session.profileID(forTabID: tab.id), pageURL: tab.url,
        payload: payload))
    #expect(!store.updateDeviceChooser(wrongOrigin))
    #expect(store.deviceChooserRequests.first?.transport == .usb)
  }

  @Test func anUpdatedOptionListInvalidatesThePreviousSelection() {
    let previous = [DeviceChooserOption(index: 0, title: "Adapter A", detail: "")]
    let updated = [DeviceChooserOption(index: 0, title: "Adapter B", detail: "")]
    let revision = UUID()
    let updatedRevision = UUID()
    var selection = DeviceChooserSelection(options: previous, revision: revision)
    selection.select(0, from: previous, revision: revision)

    #expect(selection.selectedIndex(for: previous, revision: revision) == 0)
    #expect(selection.selectedIndex(for: updated, revision: updatedRevision) == nil)
    selection.select(0, from: updated, revision: updatedRevision)
    #expect(selection.selectedIndex(for: updated, revision: updatedRevision) == 0)
  }

  @Test func anIdenticalOptionRefreshInvalidatesThePreviousSelection() {
    let options = [DeviceChooserOption(index: 0, title: "Same adapter", detail: "")]
    let revision = UUID()
    let refreshedRevision = UUID()
    var selection = DeviceChooserSelection(options: options, revision: revision)
    selection.select(0, from: options, revision: revision)

    #expect(selection.selectedIndex(for: options, revision: revision) == 0)
    #expect(selection.selectedIndex(for: options, revision: refreshedRevision) == nil)
  }

  @Test func selectedDeviceOptionHasASelectedAccessibilityTrait() {
    #expect(DeviceChooserConsent.optionAccessibilityTraits(isSelected: true).contains(.isSelected))
    #expect(
      !DeviceChooserConsent.optionAccessibilityTraits(isSelected: false).contains(.isSelected))
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
