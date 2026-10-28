import Foundation

extension BrowserSession {
  @discardableResult
  public mutating func updateSpaceSymbol(_ id: UUID, symbol: String) -> Bool {
    guard !symbol.isEmpty, let index = spaces.firstIndex(where: { $0.id == id }) else {
      return false
    }
    spaces[index].symbol = symbol
    return true
  }
}
