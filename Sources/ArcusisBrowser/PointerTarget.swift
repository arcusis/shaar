// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

extension Optional where Wrapped: Equatable {
  /// The hover or drop target after `candidate` reports whether the pointer is over it. Entering
  /// the next target can be reported before leaving the previous one, so leaving clears only a
  /// target that is still `candidate`.
  func updatingTarget(_ candidate: Wrapped, isActive: Bool) -> Wrapped? {
    if isActive { return candidate }
    return self == candidate ? nil : self
  }
}

extension Array where Element: Identifiable {
  /// The element to insert before when moving the element at `index` one step by `offset`
  /// (-1 or 1); nil moves it to the end.
  func insertionAnchor(movingIndex index: Int, by offset: Int) -> Element.ID? {
    if offset < 0 { return self[index - 1].id }
    return indices.contains(index + 2) ? self[index + 2].id : nil
  }
}
