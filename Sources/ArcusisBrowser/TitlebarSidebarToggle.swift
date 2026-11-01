// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Sidebar toggle beside the traffic lights, as in Safari and Arc. In full screen the traffic
/// lights are hidden, so it moves to the sidebar's top-left corner like Arc.
struct TitlebarSidebarToggle: View {
  @Bindable var store: BrowserStore
  @Environment(\.browserWindowIsFullScreen) private var isFullScreen
  @Environment(\.layoutDirection) private var layoutDirection

  var body: some View {
    GeometryReader { geometry in
      let titlebarHeight = geometry.safeAreaInsets.top
      let rowHeight = isFullScreen ? BrowserChromeLayout.fullScreenToggleRowHeight : titlebarHeight
      Button {
        store.sidebarIsVisible = false
      } label: {
        Image(systemName: "sidebar.leading")
          .font(.system(size: 14))
          .foregroundStyle(.secondary)
          .frame(width: 28, height: max(rowHeight, 24))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(ShellL10n.string("Hide sidebar (Command-S)"))
      .accessibilityLabel(ShellL10n.string("Hide sidebar (Command-S)"))
      .offset(
        x: isFullScreen
          ? (layoutDirection == .rightToLeft
            ? -BrowserChromeLayout.fullScreenToggleLeading
            : BrowserChromeLayout.fullScreenToggleLeading)
          : (layoutDirection == .rightToLeft
            ? -BrowserChromeLayout.titlebarToggleLeading
            : BrowserChromeLayout.titlebarToggleLeading),
        y: -titlebarHeight)
    }
  }
}
