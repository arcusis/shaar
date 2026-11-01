// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI

/// Keeps expanded controls reachable when the popover has less room than its content.
struct SiteControlsScrollContainer<Content: View>: View {
  @ViewBuilder let content: () -> Content
  @State private var contentHeight: CGFloat = 720

  var body: some View {
    ScrollView {
      content()
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(width: 320, height: min(contentHeight, maximumHeight))
  }

  private var maximumHeight: CGFloat {
    max(300, min(740, (NSScreen.main?.visibleFrame.height ?? 900) - 140))
  }
}
