// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct DeviceChooserTests {
  @Test func refusesIOBluetoothOnTheMainThreadOrWithoutPermission() {
    #expect(ShaarBluetoothMayCallIOBluetooth(false, 3, true))
    #expect(!ShaarBluetoothMayCallIOBluetooth(true, 3, true))
    #expect(!ShaarBluetoothMayCallIOBluetooth(false, 0, true))
    #expect(!ShaarBluetoothMayCallIOBluetooth(false, 1, true))
    #expect(!ShaarBluetoothMayCallIOBluetooth(false, 2, true))
    #expect(!ShaarBluetoothMayCallIOBluetooth(false, 3, false))
    #expect(!ShaarBluetoothMayCallIOBluetooth(true, 0, false))
  }

  @Test func parsesTheTitleSignalAndIgnoresOrdinaryTitles() throws {
    let signal = try title(kind: "bluetooth", id: "2-20", previous: "Docs")
    let parsed = try #require(DeviceChooserSignal.parse(title: signal))
    #expect(parsed.id == "2-20")
    #expect(parsed.transport == .bluetooth)
    #expect(parsed.previousTitle == "Docs")
    #expect(DeviceChooserSignal.parse(title: "Docs") == nil)
    #expect(DeviceChooserSignal.parse(title: DeviceChooserSignal.prefix + "{") == nil)
    #expect(!DeviceChooserSignal.isSignalID("quote\"id"))
  }

  @Test func blockedSerialAndBluetoothCannotBeGranted() throws {
    let store = try store()
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let serial = try #require(DeviceChooserIntake.request(
      tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
      title: title(kind: "serial", id: "1-10", previous: "Serial"), bluetoothBlocked: true))
    #expect(serial.bluetoothUnavailable)
    #expect(!serial.canGrant)
    #expect(serial.transport == .serial)
    let usb = try #require(DeviceChooserIntake.request(
      tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
      title: title(kind: "usb", id: "3-30", previous: "USB"), bluetoothBlocked: true))
    #expect(!usb.bluetoothUnavailable)
    #expect(DeviceChooserIntake.request(
      tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
      title: "USB", bluetoothBlocked: true) == nil)
  }

  @Test func sheetCancelRejectsWithoutADeviceIndex() throws {
    let store = try store()
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let request = try #require(DeviceChooserIntake.request(
      tabID: tab.id, profileID: store.session.selectedSpace.profileID, pageURL: tab.url,
      title: title(kind: "hid", id: "4-40", previous: "HID"), bluetoothBlocked: false))
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
      id: "preview", signalID: "9-90", tabID: tab.id,
      profileID: store.session.selectedSpace.profileID, pageURL: tab.url, transport: .usb,
      options: [DeviceChooserOption(index: 0, title: "Adapter", detail: "USB")],
      bluetoothUnavailable: false, canGrant: true)
    _ = DeviceChooserConsent(store: store, request: populated, initialSelection: 0).body
    let unavailable = DeviceChooserRequest(
      id: "bluetooth-preview", signalID: "8-80", tabID: tab.id,
      profileID: store.session.selectedSpace.profileID, pageURL: tab.url, transport: .bluetooth,
      options: [], bluetoothUnavailable: true, canGrant: false)
    _ = DeviceChooserConsent(store: store, request: unavailable).body
  }

  @Test func installScriptSkipsBluetoothTransportsWhenBlocked() {
    let blocked = DeviceChooserScript.install(bluetoothBlocked: true)
    #expect(blocked.contains("const blocked = true"))
    #expect(blocked.contains("\"serial\", !blocked"))
    #expect(blocked.contains("\"bluetooth\", !blocked"))
    #expect(blocked.contains("\\u2060shaar-chooser:"))
    let open = DeviceChooserScript.install(bluetoothBlocked: false)
    #expect(open.contains("const blocked = false"))
    let settle = DeviceChooserScript.settle(signalID: "1-10", action: "reject")
    #expect(settle.contains("\"1-10\""))
    #expect(settle.contains("\"reject\""))
  }

  private func store() throws -> BrowserStore {
    let store = BrowserStore()
    store.perform(.open(try #require(URL(string: "https://devices.example/chooser"))))
    return store
  }

  private func title(kind: String, id: String, previous: String) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: [
      "id": id, "kind": kind, "previous": previous,
    ])
    return DeviceChooserSignal.prefix + String(decoding: data, as: UTF8.self)
  }
}
