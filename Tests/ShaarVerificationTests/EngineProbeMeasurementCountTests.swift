// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct EngineProbeMeasurementCountTests {
  @Test func missingFlagIsDistinctFromInvalidMeasurementArguments() {
    #expect(EngineProbeMeasurementTabCount.parse(arguments: ["verification"]) == .absent)
    #expect(EngineProbeMeasurementTabCount.parse(arguments: ["--probe-measure-tabs"]) == .invalid)
    #expect(
      EngineProbeMeasurementTabCount.parse(arguments: ["--probe-measure-tabs", "many"])
        == .invalid)
    #expect(
      EngineProbeMeasurementTabCount.parse(arguments: ["--probe-measure-tabs", "12"]) == .invalid)
    #expect(
      EngineProbeMeasurementTabCount.parse(
        arguments: ["--probe-measure-tabs", "10", "--probe-measure-tabs", "50"])
        == .invalid)
  }

  @Test func onlySupportedFootprintCountsAreAccepted() {
    for count in [1, 10, 30, 50, 100] {
      #expect(
        EngineProbeMeasurementTabCount.parse(
          arguments: ["--probe-measure-tabs", String(count)]) == .valid(count))
    }
  }
}
