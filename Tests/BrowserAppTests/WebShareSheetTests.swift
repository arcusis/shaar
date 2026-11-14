// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct WebShareSheetTests {
  @Test func presentationGateAllowsOnlyOneActivePickerAndCanReset() {
    let gate = WebSharePresentationGate()

    #expect(gate.begin())
    #expect(!gate.begin())
    gate.finish()
    #expect(gate.begin())
  }

  @Test func outcomeGateFinishesOnlyOnceAndRejectsMissingService() {
    let gate = WebShareOutcomeGate()
    var outcomes: [Bool] = []
    gate.onFinish = { outcomes.append($0) }

    gate.chooseService(available: false)
    gate.finish(true)
    gate.chooseService(available: false)

    #expect(outcomes == [false])
    #expect(gate.onFinish == nil)
  }
}
