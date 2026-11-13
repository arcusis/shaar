// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import Testing

@testable import ShaarVerification

@MainActor
private final class RecordingPopupRuntime: ARCChromiumRuntime {
  var evaluations: [(String, String)] = []

  override func evaluateProbePopupID(_ popupID: String, script: String) async -> String? {
    evaluations.append((popupID, script))
    return nil
  }
}

@Test @MainActor func dispatchProbePopupEvaluationUsesTheAsyncBridge() async {
  let runtime = RecordingPopupRuntime()
  dispatchProbePopupEvaluation(runtime, popupID: "popup", script: "return true")

  for _ in 0..<10 where runtime.evaluations.isEmpty {
    await Task.yield()
  }

  #expect(runtime.evaluations.count == 1)
  #expect(runtime.evaluations.first?.0 == "popup")
  #expect(runtime.evaluations.first?.1 == "return true")
}
