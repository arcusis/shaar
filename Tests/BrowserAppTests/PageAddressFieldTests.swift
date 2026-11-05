// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct PageAddressFieldTests {
  @Test func compactAddressDistinguishesPortsAndIPv6() {
    #expect(
      PageAddressField.displayAddress(for: URL(string: "http://localhost:3000/path"))
        == "localhost:3000")
    #expect(
      PageAddressField.displayAddress(for: URL(string: "http://localhost:4000/"))
        == "localhost:4000")
    #expect(
      PageAddressField.displayAddress(for: URL(string: "http://[::1]:8080/"))
        == "[::1]:8080")
    #expect(
      PageAddressField.displayAddress(for: URL(string: "https://example.com/")) == "example.com")
    #expect(PageAddressField.displayAddress(for: nil) == nil)
  }
}
