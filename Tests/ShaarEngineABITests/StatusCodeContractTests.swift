// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ShaarEngineC
import Testing

@testable import ShaarEngineABI

@Test func swiftStatusCodesMatchThePublicCABI() {
  let mappings: [(ShaarStatusCode, shaar_error_code)] = [
    (.ok, shaar_error_code(rawValue: 0)),
    (.invalidArgument, shaar_error_code(rawValue: 1)),
    (.unsupportedABI, shaar_error_code(rawValue: 2)),
    (.notReady, shaar_error_code(rawValue: 3)),
    (.notFound, shaar_error_code(rawValue: 4)),
    (.wrongProfile, shaar_error_code(rawValue: 5)),
    (.wrongSession, shaar_error_code(rawValue: 6)),
    (.privateDisallowed, shaar_error_code(rawValue: 7)),
    (.policyBlocked, shaar_error_code(rawValue: 8)),
    (.permissionDenied, shaar_error_code(rawValue: 9)),
    (.conflict, shaar_error_code(rawValue: 10)),
    (.cancelled, shaar_error_code(rawValue: 11)),
    (.ioError, shaar_error_code(rawValue: 12)),
    (.chromiumError, shaar_error_code(rawValue: 13)),
    (.shuttingDown, shaar_error_code(rawValue: 14)),
    (.unsupportedCapability, shaar_error_code(rawValue: 15)),
  ]

  #expect(mappings.allSatisfy { $0.0.rawValue == UInt32($0.1.rawValue) })
}
