// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct DeviceChooserTests {
  @Test func chooserTitleIsVoiceOverHeading() {
    #expect(DeviceChooserConsent.headingTraits.contains(.isHeader))
  }

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
    payload["origin"] = "https://device-frame.example:8443"

    let request = try #require(
      DeviceChooserIntake.request(
        tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
        payload: payload))

    #expect(request.pageURL.host() == "devices.example")
    #expect(request.displayOrigin == "https://device-frame.example:8443")

    payload["origin"] = "http://device-frame.example:8443"
    let insecureOrigin = try #require(
      DeviceChooserIntake.request(
        tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
        payload: payload))
    #expect(insecureOrigin.displayOrigin == "http://device-frame.example:8443")
  }

  @Test func chooserOriginMustBeSerializedWithoutCredentialsOrPath() throws {
    let store = try store()
    let tab = try #require(store.session.selectedSpace.selectedTab)

    for invalidOrigin in [
      "https://user:secret@device-frame.example/chooser",
      "https://user@device-frame.example/chooser",
      "https://device-frame.example:65536/chooser",
      "https://trusted.example@attacker.example",
      "https://device-frame.example/private",
      "https://device-frame.example/?next=attacker.example",
      "https://device-frame.example/#section",
    ] {
      var payload = event(transport: "usb", id: "non-origin", page: tab.url)
      payload["origin"] = invalidOrigin
      #expect(
        DeviceChooserIntake.request(
          tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
          payload: payload) == nil)
    }
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
        options: [["optionId": "unsafe-name", "name": unsafeName]], canGrant: true))

    #expect(request.options.first?.title == "Adapter\u{FFFD}\u{FFFD}txt.exe")
  }

  @Test func deviceNamesPreserveJoinersUsedByEmojiAndShaping() throws {
    let store = try store()
    let name = "👩‍💻 فارسی\u{200C}زبان"
    let request = try #require(
      self.request(
        store, transport: "usb", id: "joined-name",
        options: [["optionId": "joined-name", "name": name]], canGrant: true))

    #expect(request.options.first?.title == name)
  }

  @Test func chooserRejectsMalformedAndDuplicateOptionIDs() throws {
    let store = try store()
    let tab = try #require(store.session.selectedSpace.selectedTab)

    for invalidOptionID in ["", "not an id"] {
      let payload = event(
        transport: "usb", id: "invalid-option", page: tab.url,
        options: [["optionId": invalidOptionID, "name": "Adapter"]], canGrant: true)
      #expect(
        DeviceChooserIntake.request(
          tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
          payload: payload) == nil)
    }
    let duplicates = event(
      transport: "usb", id: "duplicate-option", page: tab.url,
      options: [
        ["optionId": "same-id", "name": "Adapter A"],
        ["optionId": "same-id", "name": "Adapter B"],
      ], canGrant: true)
    #expect(
      DeviceChooserIntake.request(
        tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
        payload: duplicates) == nil)
  }

  @Test func chooserRejectsNonStringOptionIDs() throws {
    let store = try store()
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let payload = event(
      transport: "usb", id: "boolean-option", page: tab.url,
      options: [["optionId": true, "name": "Adapter"]], canGrant: true)

    #expect(
      DeviceChooserIntake.request(
        tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
        payload: payload) == nil)
  }

  @Test func chooserDeviceNameMatchesTheEngineByteLimit() throws {
    let store = try store()
    let acceptedName = String(repeating: "a", count: 256)
    let accepted = try #require(
      request(
        store, transport: "usb", id: "max-name-bytes",
        options: [["optionId": "name-boundary", "name": acceptedName]], canGrant: true))
    #expect(accepted.options.first?.title == acceptedName)
    let oversizedName = String(repeating: "a", count: 257)
    #expect(
      request(
        store, transport: "usb", id: "oversized-name",
        options: [["optionId": "name-too-large", "name": oversizedName]], canGrant: true) == nil)
    let multibyteName = String(repeating: "🔌", count: 64)
    #expect(
      request(
        store, transport: "usb", id: "max-multibyte-name",
        options: [["optionId": "multibyte-name", "name": multibyteName]], canGrant: true)?.options.first?.title
        == multibyteName)
    let oversizedMultibyteName = String(repeating: "🔌", count: 65)
    #expect(
      request(
        store, transport: "usb", id: "oversized-multibyte-name",
        options: [["optionId": "multibyte-too-large", "name": oversizedMultibyteName]], canGrant: true) == nil)
  }

  @Test func chooserOptionCountMatchesTheEngineLimit() throws {
    let store = try store()
    let acceptedOptions = (0..<64).map {
      ["optionId": "device-\($0)", "name": "Device \($0)"] as [String: Any]
    }
    let accepted = try #require(
      request(store, transport: "usb", id: "max-options", options: acceptedOptions, canGrant: true))
    #expect(accepted.options.count == 64)
    let excessOptions = (0..<65).map {
      ["optionId": "device-\($0)", "name": "Device \($0)"] as [String: Any]
    }
    #expect(request(store, transport: "usb", id: "too-many-options", options: excessOptions,
      canGrant: true) == nil)
  }

  @Test func chooserRejectsDuplicateOptionIndexes() throws {
    let store = try store()
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let payload = event(
      transport: "usb", id: "duplicate-index", page: tab.url,
      options: [
        ["index": 0, "name": "First adapter"],
        ["index": 0, "name": "Second adapter"],
      ], canGrant: true)

    #expect(
      DeviceChooserIntake.request(
        tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
        payload: payload) == nil)
  }

  @Test func unnamedDevicesHaveAVisibleFallbackLabel() throws {
    let store = try store()
    let request = try #require(
      self.request(
        store, transport: "usb", id: "unnamed-device",
        options: [
          ["optionId": "unnamed-1", "name": ""],
          ["optionId": "unnamed-2", "name": "   "],
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

  @Test func deviceNamesWithoutAVisibleBaseUseTheFallbackLabel() throws {
    let store = try store()
    let request = try #require(self.request(store, transport: "usb", id: "invisible-name",
      options: [["optionId": "device-0", "name": "\u{FE0F}"]], canGrant: true))
    #expect(request.options.first?.title == PanelsL10n.string("Unknown device"))
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
      origin: tab.url, transport: .usb,
      options: [DeviceChooserOption(optionID: "adapter-1", title: "Adapter", detail: "USB")],
      bluetoothUnavailable: false, canGrant: true)
    _ = DeviceChooserConsent(store: store, request: populated, initialSelection: "adapter-1").body
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
        options: [["optionId": "adapter-0", "name": "Adapter"]], canGrant: true))
    var decided: String??
    store.onDeviceChooserDecision = { _, optionID in decided = .some(optionID) }

    #expect(store.requestDeviceChooser(request))
    store.perform(.open(try #require(URL(string: "https://elsewhere.example/"))))

    #expect(decided == .some(nil))
    #expect(store.sheet == nil)
  }

  @Test func sheetRejectsAnOptionIDThatWasNotPresented() throws {
    let store = try store()
    let request = try #require(
      self.request(
        store, transport: "usb", id: "unlisted-option",
        options: [["optionId": "adapter-2", "name": "Presented adapter"]], canGrant: true))
    var decided: String??
    store.onDeviceChooserDecision = { _, optionID in decided = .some(optionID) }

    #expect(store.requestDeviceChooser(request))
    store.resolveDeviceChooser(request.id, optionID: "adapter-1")

    #expect(decided == .some(nil))
    #expect(store.deviceChooserRequests.isEmpty)
  }

  @Test func anUpdateReplacesTheOpenDeviceList() throws {
    let store = try store()
    let opened = try #require(self.request(store, transport: "usb", id: "7"))
    #expect(store.requestDeviceChooser(opened))
    let updated = try #require(
      self.request(
        store, kind: "deviceChooserUpdated", transport: "usb", id: "7",
        options: [["optionId": "adapter-1", "name": "USB serial adapter"]], canGrant: true))
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

  @Test func selectedDeviceOptionHasASelectedAccessibilityTrait() {
    #expect(DeviceChooserConsent.optionAccessibilityTraits(isSelected: true).contains(.isSelected))
    #expect(
      !DeviceChooserConsent.optionAccessibilityTraits(isSelected: false).contains(.isSelected))
  }

  @Test func selectedDevicePresentationTracksTheCurrentOpaqueOptionID() {
    let revision = UUID()
    let options = [DeviceChooserOption(optionID: "adapter-2", title: "Adapter", detail: "")]
    var selection = DeviceChooserSelection(
      options: options, revision: revision, selectedOptionID: "adapter-2")
    #expect(selection.selectedOptionID(for: options, revision: revision) == "adapter-2")
    selection.select("stale-id", from: options, revision: UUID())
    #expect(selection.selectedOptionID(for: options, revision: revision) == nil)
  }

  @Test func aRefreshRejectsTheOldOpaqueOptionIDEvenWhenLabelsMatch() throws {
    let store = try store()
    let opened = try #require(self.request(store, transport: "usb", id: "stable-option"))
    #expect(store.requestDeviceChooser(opened))
    let updated = try #require(
      self.request(
        store, kind: "deviceChooserUpdated", transport: "usb", id: "stable-option",
        options: [["optionId": "adapter-new", "name": "Same adapter"]], canGrant: true))
    #expect(store.updateDeviceChooser(updated))
    var decided: String??
    store.onDeviceChooserDecision = { _, optionID in decided = .some(optionID) }
    store.resolveDeviceChooser(updated.id, optionID: "adapter-old")
    #expect(decided == .some(nil))
  }

  @Test func longOptionListFitsWithinTheNativeSheet() throws {
    let store = try store()
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let options = (0..<64).map {
      DeviceChooserOption(optionID: "device-\($0)", title: "USB device \($0)", detail: "")
    }
    let request = DeviceChooserRequest(
      id: "long-list", tabID: tab.id, profileID: store.session.selectedSpace.profileID,
      pageURL: tab.url, origin: tab.url, transport: .usb, options: options,
      bluetoothUnavailable: false, canGrant: true)
    let hostingView = NSHostingView(rootView: DeviceChooserConsent(store: store, request: request))
    hostingView.frame = NSRect(x: 0, y: 0, width: 440, height: 700)
    hostingView.layoutSubtreeIfNeeded()

    #expect(hostingView.fittingSize.height <= 700)
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
    var origin = URLComponents(url: page, resolvingAgainstBaseURL: false)
    origin?.path = ""
    origin?.query = nil
    origin?.fragment = nil
    return [
      "schemaVersion": 1, "kind": kind, "id": id, "transport": transport,
      "pageURL": page.absoluteString, "origin": origin?.string ?? page.absoluteString,
      "options": options,
      "canGrant": canGrant, "profileID": "profile", "tabID": "tab", "windowID": "window",
    ]
  }
}
