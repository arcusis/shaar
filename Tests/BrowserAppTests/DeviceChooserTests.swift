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

  @Test func chooserOriginFormattingOmitsDefaultPortsAndBracketsIPv6() throws {
    let store = try store()
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let request = DeviceChooserRequest(
      id: "ipv6-origin", tabID: tab.id, profileID: store.session.selectedSpace.profileID,
      pageURL: tab.url, origin: try #require(URL(string: "https://[2001:db8::1]:443")),
      transport: .usb, options: [], bluetoothUnavailable: false, canGrant: false)

    #expect(request.displayOrigin == "https://[2001:db8::1]")

    let httpOrigin = DeviceChooserRequest(
      id: "http-origin", tabID: tab.id, profileID: store.session.selectedSpace.profileID,
      pageURL: tab.url, origin: try #require(URL(string: "http://devices.example:80")),
      transport: .usb, options: [], bluetoothUnavailable: false, canGrant: false)
    #expect(httpOrigin.displayOrigin == "http://devices.example")
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
        options: [["optionID": "unsafe-option", "name": unsafeName]], canGrant: true))

    #expect(request.options.first?.title == "Adapter\u{FFFD}\u{FFFD}txt.exe")
  }

  @Test func chooserRejectsMalformedAndLegacyOptionIdentifiers() throws {
    let store = try store()
    let tab = try #require(store.session.selectedSpace.selectedTab)

    for invalidOption: [String: Any] in [
      ["optionID": "bad option", "name": "Adapter"],
      ["optionID": String(repeating: "a", count: 65), "name": "Adapter"],
      ["index": 0, "name": "Adapter"],
    ] {
      let payload = event(
        transport: "usb", id: "invalid-index", page: tab.url,
        options: [invalidOption], canGrant: true)
      #expect(
        DeviceChooserIntake.request(
          tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
          payload: payload) == nil)
    }
  }

  @Test func chooserOptionsRequireUniqueOpaqueIdentifiers() throws {
    let store = try store()
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let valid = ["optionID": "opaque-option-0", "name": "Adapter"]
    let parsedRequest = try #require(
      self.request(store, transport: "usb", id: "opaque-session", options: [valid], canGrant: true))
    #expect(parsedRequest.options.first?.optionID == "opaque-option-0")

    let duplicate = event(
      transport: "usb", id: "opaque-session", page: tab.url,
      options: [valid, valid], canGrant: true)
    #expect(
      DeviceChooserIntake.request(
        tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
        payload: duplicate) == nil)
  }

  @Test func unnamedDevicesHaveAVisibleFallbackLabel() throws {
    let store = try store()
    let request = try #require(
      self.request(
        store, transport: "usb", id: "unnamed-device",
        options: [
          ["optionID": "unnamed-0", "name": ""],
          ["optionID": "unnamed-1", "name": "   "],
        ], canGrant: true))

    #expect(request.options.map(\.title) == [
      PanelsL10n.string("Unknown device"), PanelsL10n.string("Unknown device"),
    ])
  }

  @Test func sheetCancelRejectsWithoutADeviceOptionID() throws {
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
    store.resolveDeviceChooser(request.id, optionID: "opaque-option-0")
    #expect(decided == .some(nil))
    #expect(store.deviceChooserRequests.isEmpty)
    _ = DeviceChooserConsent(store: store, request: request).body
    let populated = DeviceChooserRequest(
      id: "9", tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
      origin: tab.url, transport: .usb,
      options: [DeviceChooserOption(optionID: "opaque-option-0", title: "Adapter", detail: "USB")],
      bluetoothUnavailable: false, canGrant: true)
    _ = DeviceChooserConsent(
      store: store, request: populated, initialSelection: "opaque-option-0").body
    let unavailable = DeviceChooserRequest(
      id: "8", tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
      origin: tab.url, transport: .bluetooth, options: [], bluetoothUnavailable: true,
      canGrant: false)
    _ = DeviceChooserConsent(store: store, request: unavailable).body
  }

  @Test func sheetResolutionReturnsOnlyTheSelectedOpaqueOptionID() throws {
    let store = try store()
    let optionID = "opaque-device-7"
    let request = try #require(
      self.request(
        store, transport: "usb", id: "opaque-selection",
        options: [["optionID": optionID, "name": "Adapter"]], canGrant: true))
    var decisions: [String?] = []
    store.onDeviceChooserDecision = { _, selected in decisions.append(selected) }

    #expect(store.requestDeviceChooser(request))
    store.resolveDeviceChooser(request.id, optionID: optionID)
    #expect(decisions == [optionID])
    #expect(store.deviceChooserRequests.isEmpty)
  }

  @Test func anUpdateReplacesTheOpenDeviceList() throws {
    let store = try store()
    let opened = try #require(self.request(store, transport: "usb", id: "7"))
    #expect(store.requestDeviceChooser(opened))
    let updated = try #require(
      self.request(
        store, kind: "deviceChooserUpdated", transport: "usb", id: "7",
        options: [["optionID": "usb-option-7", "name": "USB serial adapter"]], canGrant: true))
    #expect(updated.canGrant)
    #expect(store.updateDeviceChooser(updated))
    guard case .deviceChooser(let shown) = store.sheet else {
      Issue.record("The chooser sheet was not updated.")
      return
    }
    #expect(shown.options.map(\.title) == ["USB serial adapter"])
    #expect(shown.options.map(\.optionID) == ["usb-option-7"])
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
    let previous = [DeviceChooserOption(optionID: "adapter-a", title: "Adapter A", detail: "")]
    let updated = [DeviceChooserOption(optionID: "adapter-b", title: "Adapter B", detail: "")]
    let revision = UUID()
    let updatedRevision = UUID()
    var selection = DeviceChooserSelection(options: previous, revision: revision)
    selection.select("adapter-a", from: previous, revision: revision)

    #expect(selection.selectedOptionID(for: previous, revision: revision) == "adapter-a")
    #expect(selection.selectedOptionID(for: updated, revision: updatedRevision) == nil)
    selection.select("adapter-b", from: updated, revision: updatedRevision)
    #expect(selection.selectedOptionID(for: updated, revision: updatedRevision) == "adapter-b")
  }

  @Test func anIdenticalOptionRefreshInvalidatesThePreviousSelection() {
    let options = [DeviceChooserOption(optionID: "same-adapter", title: "Same adapter", detail: "")]
    let revision = UUID()
    let refreshedRevision = UUID()
    var selection = DeviceChooserSelection(options: options, revision: revision)
    selection.select("same-adapter", from: options, revision: revision)

    #expect(selection.selectedOptionID(for: options, revision: revision) == "same-adapter")
    #expect(selection.selectedOptionID(for: options, revision: refreshedRevision) == nil)
  }

  @Test func selectedDeviceOptionHasASelectedAccessibilityTrait() {
    #expect(DeviceChooserConsent.optionAccessibilityTraits(isSelected: true).contains(.isSelected))
    #expect(!DeviceChooserConsent.optionAccessibilityTraits(isSelected: false).contains(.isSelected))
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
