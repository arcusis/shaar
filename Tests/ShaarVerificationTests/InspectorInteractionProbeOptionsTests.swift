// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct InspectorInteractionProbeOptionsTests {
  @Test func domEventFallbackRequiresItsExactCommandLineArgument() {
    let argument = InspectorInteractionProbeOptions.domEventsArgument
    #expect(InspectorInteractionProbeOptions.usesDOMEvents(arguments: [argument]))
    #expect(InspectorInteractionProbeOptions.usesDOMEvents(arguments: ["--probe", argument]))
    #expect(!InspectorInteractionProbeOptions.usesDOMEvents(arguments: []))
    #expect(!InspectorInteractionProbeOptions.usesDOMEvents(arguments: ["\(argument)-debug"]))
    #expect(!InspectorInteractionProbeOptions.usesDOMEvents(arguments: ["\(argument)=true"]))
  }
}
