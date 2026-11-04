// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarEngineABI

@Suite("Shaar app transport selection")
struct ShaarEngineTransportTests {
  @Test func shippingAndReleaseChoicesRemainArdia() {
    #expect(ShaarEngineImplementation.shippingDefault == .ardia)
    #expect(
      ShaarEngineImplementation.selected(
        environment: ["SHAAR_ENGINE_IMPLEMENTATION": "shaar"], isDebug: false) == .ardia)
    #expect(ShaarEngineImplementation.selected(environment: [:], isDebug: true) == .ardia)
    #expect(
      ShaarEngineImplementation.selected(
        environment: ["SHAAR_ENGINE_IMPLEMENTATION": "shaar"], isDebug: true) == .shaar)
  }

  @Test @MainActor func frameworkLoadFailureFallsBackToArdia() {
    let choice = ShaarEngineTransportSelection<String>.make(
      implementation: .shaar,
      ardia: { "existing-ardia-runtime" },
      shaar: { throw ShaarEngineStartupError.frameworkLoadFailed("missing framework") })
    guard case .ardia(let runtime) = choice else {
      Issue.record("failed Shaar startup must select Ardia")
      return
    }
    #expect(runtime == "existing-ardia-runtime")
  }

  @Test @MainActor func ardiaChoiceDoesNotAttemptShaarStartup() {
    var attempted = false
    let choice = ShaarEngineTransportSelection<String>.make(
      implementation: .shippingDefault,
      ardia: { "existing-ardia-runtime" },
      shaar: {
        attempted = true
        throw ShaarEngineStartupError.frameworkLoadFailed("must not load")
      })
    #expect(!attempted)
    if case .ardia(let runtime) = choice { #expect(runtime == "existing-ardia-runtime") }
    else { Issue.record("shipping choice selected Shaar") }
  }
}
