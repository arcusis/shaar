// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@MainActor
@Suite("Device chooser page settlement")
struct DeviceChooserProbeTests {
  @Test func aMissingUsbChooserFailsTheHiddenProbe() {
    #expect(
      DeviceChooserProbePolicy.missingChooserError(transport: "usb")
        == "The WebUSB request settled without a native device chooser.")
  }

  @Test func otherTransportFallbacksAreUnaffected() {
    for transport in ["serial", "bluetooth", "hid"] {
      #expect(DeviceChooserProbePolicy.missingChooserError(transport: transport) == nil)
    }
  }

  @Test func onlyBooleanSuccessWithAnIntegerCountCanResolveHID() {
    let valid = DeviceChooserProbe.PageSettlement(raw: #"{"ok":true,"count":0}"#)
    #expect(valid?.isChooserDismissal(for: "hid") == true)
    #expect(valid?.summary == "resolved 0")

    for raw in [
      #"{"ok":1,"count":0}"#,
      #"{"ok":true,"count":false}"#,
      #"{"ok":"true","count":0}"#,
      #"{"ok":true,"count":1}"#,
    ] {
      #expect(
        DeviceChooserProbe.PageSettlement(raw: raw)?.isChooserDismissal(for: "hid") == false)
    }
  }

  @Test func fractionalJSONNumberCannotResolveHIDAsAnIntegerCount() {
    let fractional = DeviceChooserProbe.PageSettlement(raw: #"{"ok":true,"count":0.0}"#)
    #expect(fractional?.isChooserDismissal(for: "hid") == false)
  }

  @Test func anErrorFieldCannotResolveHIDAlongsideASuccessCount() {
    for raw in [
      #"{"error":"","ok":true,"count":0}"#,
      #"{"error":null,"ok":true,"count":0}"#,
    ] {
      #expect(DeviceChooserProbe.PageSettlement(raw: raw)?.isChooserDismissal(for: "hid") == false)
    }
  }

  @Test func baseURLMustBeAnUnauthenticatedLoopbackHTTPFixtureWithAValidPort() {
    #expect(
      DeviceChooserProbeConfiguration.acceptsBaseURL(
        URL(string: "http://127.0.0.1:43210/serial")))
    for value in [
      "https://127.0.0.1:43210/serial",
      "http://localhost:43210/serial",
      "http://example.invalid:43210/serial",
      "http://127.0.0.1:0/serial",
      "http://user:secret@127.0.0.1:43210/serial",
    ] {
      #expect(!DeviceChooserProbeConfiguration.acceptsBaseURL(URL(string: value)))
    }
    #expect(!DeviceChooserProbeConfiguration.acceptsBaseURL(nil))
  }
}
