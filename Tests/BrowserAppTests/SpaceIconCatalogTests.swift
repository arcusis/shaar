import AppKit
import Testing

@testable import ArcusisBrowser

struct SpaceIconCatalogTests {
  @Test func catalogHasUniqueResolvableSymbols() {
    let symbols = SpaceIconCatalog.all.flatMap(\.symbols)
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
      SpaceIconCatalog.sections(matching: "money").contains {
        $0.name == "Money" && $0.symbols.contains("dollarsign.circle")
      })
    #expect(
      SpaceIconCatalog.sections(matching: "plane").contains {
        $0.name == "Travel" && $0.symbols.contains("airplane")
      })
    #expect(
      SpaceIconCatalog.sections(matching: "code").contains {
        $0.name == "Devices" && $0.symbols.contains("terminal")
      })
  }
}
