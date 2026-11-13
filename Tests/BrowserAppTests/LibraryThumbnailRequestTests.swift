// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ArcusisBrowser

@Test func completionBeforeContinuationInstallationIsDelivered() async {
  let completion = CancellableContinuation<Int>()
  completion.resume(returning: 42)

  let value = await withCheckedContinuation { continuation in
    completion.install(continuation)
  }

  #expect(value == 42)
}
