// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct EngineProbeMeasurementArgumentsTests {
  @Test func acceptsOnlySupportedCountsAndDistinguishesAbsentFromMalformedFlags() {
    let flag = EngineProbeMeasurementArguments.flag
    for count in [1, 10, 30, 50, 100] {
      let arguments = [flag, String(count)]
      #expect(EngineProbeMeasurementArguments.tabCount(in: arguments) == count)
      #expect(EngineProbeMeasurementArguments.hasValidTabCount(in: arguments))
    }

    #expect(EngineProbeMeasurementArguments.tabCount(in: []) == nil)
    #expect(EngineProbeMeasurementArguments.hasValidTabCount(in: []))
    #expect(EngineProbeMeasurementArguments.tabCount(in: [flag]) == nil)
    #expect(EngineProbeMeasurementArguments.tabCount(in: [flag, "many"]) == nil)
    #expect(EngineProbeMeasurementArguments.tabCount(in: [flag, "0"]) == 0)
    #expect(!EngineProbeMeasurementArguments.hasValidTabCount(in: [flag, "0"]))
    #expect(EngineProbeMeasurementArguments.tabCount(in: [flag, "101"]) == 101)
    #expect(!EngineProbeMeasurementArguments.hasValidTabCount(in: [flag, "101"]))
    #expect(
      !EngineProbeMeasurementArguments.hasValidTabCount(in: [flag, "bad", flag, "10"]))
  }
}
