// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import Testing

@testable import ShaarVerification

@MainActor
private final class RecordingPopupRuntime: ARCChromiumRuntime {
  var evaluations: [(String, String)] = []
  var onEvaluate: (@MainActor () -> Void)?

  override func evaluateProbePopupID(_ popupID: String, script: String) async -> String? {
    evaluations.append((popupID, script))
    let notify = onEvaluate
    onEvaluate = nil
    notify?()
    return nil
  }
}

@Test @MainActor func dispatchProbePopupEvaluationUsesTheAsyncBridge() async {
  let runtime = RecordingPopupRuntime()
  // The bridge hops through an unstructured task. Suspending lets that task
  // run; a fixed yield count returns before it is scheduled under coverage.
  await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
    runtime.onEvaluate = { continuation.resume() }
    dispatchProbePopupEvaluation(runtime, popupID: "popup", script: "return true")
  }

  #expect(runtime.evaluations.count == 1)
  #expect(runtime.evaluations.first?.0 == "popup")
  #expect(runtime.evaluations.first?.1 == "return true")
}
