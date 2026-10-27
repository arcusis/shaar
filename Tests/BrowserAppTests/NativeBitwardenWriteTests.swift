import Foundation
import XCTest

@testable import ArcusisBrowser

final class NativeBitwardenWriteTests: XCTestCase {
  func testInputBoundsAndRedaction() throws {
    let input = NativeBitwardenWriteInput(
      username: "synthetic-user", password: "synthetic-secret", name: "Site")
    XCTAssertNoThrow(try input.validate())
    XCTAssertFalse(input.description.contains("synthetic"))
    XCTAssertFalse(input.debugDescription.contains("synthetic"))
    for invalid in [
      NativeBitwardenWriteInput(username: "", password: "p", name: "n"),
      NativeBitwardenWriteInput(username: "u", password: "", name: "n"),
      NativeBitwardenWriteInput(username: "u", password: "p", name: ""),
      NativeBitwardenWriteInput(
        username: "u", password: String(repeating: "x", count: 16_385), name: "n"),
    ] {
      XCTAssertThrowsError(try invalid.validate()) { error in
        XCTAssertEqual(error as? NativeBitwardenWriteError, .invalidInput)
      }
    }
  }
}
