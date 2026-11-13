// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ShaarEngineABIC
import ShaarEngineC
import Testing

@Test func navigationCShimRejectsMissingRequiredPointers() {
  let invalidArgument = UInt32(shaar_error_code(rawValue: 1).rawValue)
  let noSymbol = shaar_navigation_submit_invoke(
    nil, nil, nil, nil, nil, 0, shaar_bytes(data: nil, size: 0), 1, nil, nil, nil)
  #expect(noSymbol == invalidArgument)

  var scope = shaar_scope(
    size: UInt32(MemoryLayout<shaar_scope>.size), profile: nil,
    private_session: nil)
  let noErrorOutput = withUnsafePointer(to: &scope) { scopePointer in
    shaar_navigation_submit_invoke(
      UnsafeRawPointer(bitPattern: 1), nil, scopePointer, nil, nil, 0,
      shaar_bytes(data: nil, size: 0), 1, nil, nil, nil)
  }
  #expect(noErrorOutput == invalidArgument)
}
