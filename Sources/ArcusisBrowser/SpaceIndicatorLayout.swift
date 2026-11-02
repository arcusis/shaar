// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A bounded strip, with the selected Space retained when the rest need an overflow menu.
struct SpaceIndicatorLayout {
  let visible: Range<Int>
  let dotWidth: CGFloat
  let selectedWidth: CGFloat
  let overflowWidth: CGFloat

  init(count: Int, selectedIndex: Int, width: CGFloat) {
    let width = max(0, width)
    selectedWidth = min(22, width)
    if count <= 1 || CGFloat(count - 1) * 12 + selectedWidth <= width {
      visible = 0..<max(0, count)
      dotWidth = count > 1 ? min(22, (width - selectedWidth) / CGFloat(count - 1)) : 0
      overflowWidth = 0
    } else {
      overflowWidth = min(22, max(0, width - selectedWidth))
      let capacity = min(count, 1 + Int(max(0, width - selectedWidth - overflowWidth) / 12))
      let selected = min(count - 1, max(0, selectedIndex))
      let start = min(count - capacity, max(0, selected - capacity / 2))
      visible = start..<(start + capacity)
      dotWidth = 12
    }
  }
}
