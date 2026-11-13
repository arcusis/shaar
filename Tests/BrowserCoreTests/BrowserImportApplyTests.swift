// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import BrowserCore

@Test @MainActor func browserImportApplyIgnoresDuplicateAsynchronousCallbacks() {
  let operations: [[String: Any]] = [["id": "first"], ["id": "second"]]
  var applied: [String] = []
  var callbacks: [String: @MainActor (Error?) -> Void] = [:]
  var completionCount = 0

  BrowserImport.apply(
    operations,
    using: { operation, done in
      let id = operation["id"] as! String
      applied.append(id)
      callbacks[id] = done
    },
    completion: { _ in completionCount += 1 })

  #expect(applied == ["first"])
  callbacks["first"]?(nil)
  #expect(applied == ["first", "second"])
  callbacks["first"]?(nil)
  #expect(completionCount == 0)
  callbacks["second"]?(nil)
  #expect(completionCount == 1)
}
