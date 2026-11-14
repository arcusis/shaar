// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import BrowserCore

@Suite
struct BrowserImportCancellationTests {
  @Test func callerCancellationReachesTheOffMainWorker() async throws {
    let workerStarted = DispatchSemaphore(value: 0)
    let caller = Task {
      try await BrowserImport.performOffMain {
        workerStarted.signal()
        while !Task<Never, Never>.isCancelled {
          Thread.sleep(forTimeInterval: 0.001)
        }
        try Task<Never, Never>.checkCancellation()
        return 1
      }
    }
    let startResult = await Task.detached {
      waitForSignal(workerStarted)
    }.value
    #expect(startResult == .success)

    caller.cancel()
    await #expect(throws: CancellationError.self) { try await caller.value }
  }
}

private func waitForSignal(_ semaphore: DispatchSemaphore) -> DispatchTimeoutResult {
  semaphore.wait(timeout: .now() + 2)
}
