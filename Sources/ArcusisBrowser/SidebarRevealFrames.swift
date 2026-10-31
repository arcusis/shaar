// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct SidebarFooterBoundsPreferenceKey: PreferenceKey {
  static let defaultValue: CGRect = .zero

  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    let next = nextValue()
    if !next.isEmpty { value = next }
  }
}

struct SidebarRevealFrames: Equatable {
  var selected: CGRect = .zero
  var selectedID: UUID?
  var viewport: CGRect = .zero

  /// Keeps the frames already reported unless `next` reports a non-empty replacement.
  mutating func merge(_ next: SidebarRevealFrames) {
    if !next.selected.isEmpty {
      selected = next.selected
      selectedID = next.selectedID
    }
    if !next.viewport.isEmpty { viewport = next.viewport }
  }
}

struct SidebarOrdinaryRevealFramesPreferenceKey: PreferenceKey {
  static let defaultValue = SidebarRevealFrames()

  static func reduce(value: inout SidebarRevealFrames, nextValue: () -> SidebarRevealFrames) {
    value.merge(nextValue())
  }
}

struct SidebarFavoriteRevealFramesPreferenceKey: PreferenceKey {
  static let defaultValue = SidebarRevealFrames()

  static func reduce(value: inout SidebarRevealFrames, nextValue: () -> SidebarRevealFrames) {
    value.merge(nextValue())
  }
}

struct SidebarSpaceRevealFramesPreferenceKey: PreferenceKey {
  static let defaultValue = SidebarRevealFrames()

  static func reduce(value: inout SidebarRevealFrames, nextValue: () -> SidebarRevealFrames) {
    value.merge(nextValue())
  }
}
