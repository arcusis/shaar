// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Testing

@testable import ArcusisBrowser

struct SymbolCatalogTests {
  @Test func catalogHasUniqueResolvableSymbols() {
    let symbols = SymbolCatalog.all.flatMap(\.symbols)
    #expect(symbols.count >= 350)
    #expect(Set(symbols).count == symbols.count)
    for symbol in symbols {
      #expect(
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
        "Missing symbol: \(symbol)")
    }
  }

  @Test func keywordSearchFindsExpectedSections() {
    #expect(
      SymbolCatalog.sections(matching: "money").contains {
        $0.name == "Money" && $0.symbols.contains("dollarsign.circle")
      })
    #expect(
      SymbolCatalog.sections(matching: "plane").contains {
        $0.name == "Travel" && $0.symbols.contains("airplane")
      })
    #expect(
      SymbolCatalog.sections(matching: "code").contains {
        $0.name == "Devices" && $0.symbols.contains("terminal")
      })
  }
}
