// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite @MainActor struct QuitExitBackgroundModeTests {
  @Test func backgroundModeRequiresAnExplicitFalseBoolean() throws {
    let disabled = try JSONSerialization.data(
      withJSONObject: ["background_mode": ["enabled": false]])
    #expect(QuitExitProbe.backgroundModeIsOff(disabled))

    let enabled = try JSONSerialization.data(
      withJSONObject: ["background_mode": ["enabled": true]])
    #expect(!QuitExitProbe.backgroundModeIsOff(enabled))

    let numericZero = try JSONSerialization.data(
      withJSONObject: ["background_mode": ["enabled": 0]])
    #expect(!QuitExitProbe.backgroundModeIsOff(numericZero))

    let missing = try JSONSerialization.data(withJSONObject: ["background_mode": [:]])
    #expect(!QuitExitProbe.backgroundModeIsOff(missing))
    #expect(!QuitExitProbe.backgroundModeIsOff(Data("not JSON".utf8)))
    #expect(!QuitExitProbe.backgroundModeIsOff(nil))
  }
}
