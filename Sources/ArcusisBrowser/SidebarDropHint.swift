// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Dashed placeholder shown in an empty sidebar section while a tab is dragged, like Arc.
struct SidebarDropHint: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.browserChromeAccessibilityOverrides) private var accessibilityOverrides
  let title: String
  let symbol: String
  let isTargeted: Bool

  static func targetAnimation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.12)
  }

  private var reduceSidebarMotion: Bool {
    accessibilityOverrides.reduceMotionEnabled(systemSetting: reduceMotion)
  }

  var body: some View {
    Label(title, systemImage: symbol)
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
      .frame(maxWidth: .infinity)
      .frame(height: 40)
      .background(
        Color.accentColor.opacity(isTargeted ? 0.14 : 0),
        in: RoundedRectangle(cornerRadius: 10)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .strokeBorder(
            isTargeted ? Color.accentColor : Color.primary.opacity(0.22),
            style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
      )
      .animation(Self.targetAnimation(reduceMotion: reduceSidebarMotion), value: isTargeted)
      .transition(
        reduceSidebarMotion
          ? .opacity : .opacity.combined(with: .scale(scale: 0.96))
      )
      .allowsHitTesting(false)
  }
}
