// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite struct ProbeReadingTests {
  @Test func geolocationReadingKeepsNumbersAndRejectsBooleans() {
    let reading = GeolocationReading([
      "latitude": NSNumber(value: 31.7683), "permission": "granted",
      "error": "User denied Geolocation", "code": NSNumber(value: 1),
      "origin": "http://127.0.0.1:8000",
    ])
    #expect(reading.latitude == 31.7683)
    #expect(reading.permission == "granted")
    #expect(reading.message == "User denied Geolocation")
    #expect(reading.code == 1)
    #expect(reading.origin == "http://127.0.0.1:8000")
    let payload = reading.payload
    #expect(payload["latitude"] as? Double == 31.7683)
    #expect(payload["permission"] as? String == "granted")
    #expect(payload["error"] as? String == "User denied Geolocation")
    #expect(payload["code"] as? Int == 1)
    #expect(payload["origin"] as? String == "http://127.0.0.1:8000")

    let booleans = GeolocationReading(["latitude": true, "code": false])
    #expect(booleans.latitude == nil && booleans.code == nil)
    #expect(booleans.payload.isEmpty)
    #expect(GeolocationReading(nil).payload.isEmpty)
  }

  @Test func evaluateBoxReportsArrivalOnlyAfterFinish() {
    let box = EvaluateBox()
    let pending = box.poll()
    #expect(!pending.arrived && pending.value == nil)
    box.finish(nil)
    let empty = box.poll()
    #expect(empty.arrived && empty.value == nil)
    box.finish("{\"ok\":true}")
    #expect(box.poll().value == "{\"ok\":true}")
  }
}
