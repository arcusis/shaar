// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct ShaarReproDOMSnapshotTests {
  @Test func acceptsBoundedRedactedTree() throws {
    let root = ShaarReproDOMNode(
      tag: "body", text: "Safe text", attributes: [:], children: [
        ShaarReproDOMNode(
          tag: "form", text: "[redacted]", attributes: [:], children: []),
      ])
    #expect(try ShaarReproDOMSnapshot.decode(JSONEncoder().encode(root)) == root)
    #expect(ShaarReproDOMSnapshot.expression.contains("element.isContentEditable"))
    #expect(ShaarReproDOMSnapshot.expression.contains("element.matches('form,input,textarea"))
  }

  @Test func rejectsFormValuesAndUnexpectedAttributes() throws {
    let unsafe = ShaarReproDOMNode(
      tag: "form", text: "form-secret", attributes: [:], children: [])
    #expect(throws: Error.self) {
      try ShaarReproDOMSnapshot.decode(JSONEncoder().encode(unsafe))
    }
    let attribute = ShaarReproDOMNode(
      tag: "body", text: "", attributes: ["data-token": "secret"], children: [])
    #expect(throws: Error.self) {
      try ShaarReproDOMSnapshot.decode(JSONEncoder().encode(attribute))
    }
  }
}
