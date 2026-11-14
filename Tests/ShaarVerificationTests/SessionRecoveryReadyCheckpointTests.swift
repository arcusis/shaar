// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite @MainActor struct SessionRecoveryReadyCheckpointTests {
  @Test func readyCheckpointRequiresMatchingModeAndJSONTrue() throws {
    let valid = Data(
      #"{"mode":"session-recovery-only","ready":true,"pid":42}"#.utf8)
    let numeric = Data(
      #"{"mode":"session-recovery-only","ready":1,"pid":42}"#.utf8)
    let wrongMode = Data(
      #"{"mode":"other-probe","ready":true,"pid":42}"#.utf8)
    let falseValue = Data(
      #"{"mode":"session-recovery-only","ready":false,"pid":42}"#.utf8)

    #expect(parse(valid)?["pid"] as? Int == 42)
    #expect(parse(numeric) == nil)
    #expect(parse(wrongMode) == nil)
    #expect(parse(falseValue) == nil)
  }

  @Test func readyCheckpointRejectsMissingAndMalformedData() {
    #expect(parse(nil) == nil)
    #expect(parse(Data("not JSON".utf8)) == nil)
  }

  private func parse(_ data: Data?) -> [String: Any]? {
    SessionRecoveryProbe.readyCheckpoint(from: data, expectedMode: "session-recovery-only")
  }
}
