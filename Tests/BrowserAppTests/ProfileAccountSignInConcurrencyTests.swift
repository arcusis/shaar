// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct ProfileAccountSignInConcurrencyTests {
  @Test func cancellingEvaluationResumesWithoutRuntimeCallback() async throws {
    var runtimeCompletion: (@Sendable (String?) -> Void)?
    let evaluation = Task {
      await AccountSignInEvaluation.evaluate { completion in
        runtimeCompletion = completion
      }
    }
    for _ in 0..<100 where runtimeCompletion == nil {
      await Task.yield()
    }
    try #require(runtimeCompletion != nil)

    var returned = false
    let observer = Task {
      _ = await evaluation.value
      returned = true
    }
    evaluation.cancel()
    for _ in 0..<100 where !returned {
      await Task.yield()
    }

    let resumedOnCancellation = returned
    runtimeCompletion?(nil)
    await observer.value
    #expect(resumedOnCancellation)
  }
}
