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

  @Test func measurementModesRequireTheirTabCountAndEagerSleepingBase() {
    #expect(
      EngineProbeMeasurementArguments.modeDependencyFailure(arguments: [], tabCount: nil) == nil)
    #expect(
      EngineProbeMeasurementArguments.modeDependencyFailure(
        arguments: ["--probe-measure-eager"], tabCount: nil)
        == "Eager measurement requires --probe-measure-tabs.")
    #expect(
      EngineProbeMeasurementArguments.modeDependencyFailure(
        arguments: ["--probe-measure-inspector"], tabCount: nil)
        == "Inspector measurement requires --probe-measure-tabs.")
    #expect(
      EngineProbeMeasurementArguments.modeDependencyFailure(
        arguments: ["--probe-measure-sleeping"], tabCount: nil)
        == "Sleeping measurement requires eagerly loaded measurement tabs.")
    #expect(
      EngineProbeMeasurementArguments.modeDependencyFailure(
        arguments: ["--probe-measure-sleeping"], tabCount: 10)
        == "Sleeping measurement requires eagerly loaded measurement tabs.")
    #expect(
      EngineProbeMeasurementArguments.modeDependencyFailure(
        arguments: ["--probe-measure-sleeping", "--probe-measure-eager"], tabCount: 10) == nil)
  }

  @Test func measurementModeIgnoresItsOwnFlagButRejectsOtherProbeModes() {
    let modes = ["--probe-measure-tabs", "--probe-localization", "--probe-basic-browsing"]
    #expect(
      !EngineProbeMeasurementArguments.conflictsWithOtherMode(
        arguments: ["--probe-measure-tabs", "10"], conflictingFlags: modes))
    #expect(
      EngineProbeMeasurementArguments.conflictsWithOtherMode(
        arguments: ["--probe-measure-tabs", "10", "--probe-localization"],
        conflictingFlags: modes))
  }
}
