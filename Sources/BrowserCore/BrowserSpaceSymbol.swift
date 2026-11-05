// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

extension BrowserSession {
  @discardableResult
  public mutating func updateSpaceSymbol(_ id: UUID, symbol: String) -> Bool {
    let cleanSymbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanSymbol.isEmpty, let index = spaces.firstIndex(where: { $0.id == id }) else {
      return false
    }
    spaces[index].symbol = cleanSymbol
    return true
  }
}
