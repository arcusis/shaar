// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ShaarEngineC
import Testing

@testable import ShaarEngineABI

@Test func swiftStatusCodesMatchThePublicCABI() {
  let mappings: [(ShaarStatusCode, shaar_error_code)] = [
    (.ok, SHAAR_OK),
    (.invalidArgument, SHAAR_INVALID_ARGUMENT),
    (.unsupportedABI, SHAAR_UNSUPPORTED_ABI),
    (.notReady, SHAAR_NOT_READY),
    (.notFound, SHAAR_NOT_FOUND),
    (.wrongProfile, SHAAR_WRONG_PROFILE),
    (.wrongSession, SHAAR_WRONG_SESSION),
    (.privateDisallowed, SHAAR_PRIVATE_DISALLOWED),
    (.policyBlocked, SHAAR_POLICY_BLOCKED),
    (.permissionDenied, SHAAR_PERMISSION_DENIED),
    (.conflict, SHAAR_CONFLICT),
    (.cancelled, SHAAR_CANCELLED),
    (.ioError, SHAAR_IO_ERROR),
    (.chromiumError, SHAAR_CHROMIUM_ERROR),
    (.shuttingDown, SHAAR_SHUTTING_DOWN),
    (.unsupportedCapability, SHAAR_UNSUPPORTED_CAPABILITY),
  ]

  #expect(mappings.allSatisfy { $0.0.rawValue == UInt32($0.1.rawValue) })
}
