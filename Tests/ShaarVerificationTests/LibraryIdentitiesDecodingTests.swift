// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite struct LibraryIdentitiesDecodingTests {
  @Test func decodesAllCheckpointIdentityFields() throws {
    let values = (0..<6).map { _ in UUID() }
    let data = try JSONSerialization.data(
      withJSONObject: [
        "alpha": values[0].uuidString,
        "beta": values[1].uuidString,
        "shared": values[2].uuidString,
        "folder": values[3].uuidString,
        "bookmarkA": values[4].uuidString,
        "bookmarkB": values[5].uuidString,
      ])

    let decoded = try LibraryIdentities.decode(from: data)
    #expect(decoded.alpha == values[0])
    #expect(decoded.beta == values[1])
    #expect(decoded.shared == values[2])
    #expect(decoded.folder == values[3])
    #expect(decoded.bookmarkA == values[4])
    #expect(decoded.bookmarkB == values[5])
  }

  @Test func rejectsMissingAndMalformedIdentityFields() throws {
    let missingField = try JSONSerialization.data(
      withJSONObject: ["alpha": UUID().uuidString])
    #expect(throws: DecodingError.self) {
      try LibraryIdentities.decode(from: missingField)
    }

    let malformedUUID = try JSONSerialization.data(
      withJSONObject: [
        "alpha": "invalid", "beta": UUID().uuidString, "shared": UUID().uuidString,
        "folder": UUID().uuidString, "bookmarkA": UUID().uuidString,
        "bookmarkB": UUID().uuidString,
      ])
    #expect(throws: DecodingError.self) {
      try LibraryIdentities.decode(from: malformedUUID)
    }
  }
}
