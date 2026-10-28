import SwiftUI

/// Sidebar toggle placed in the titlebar row beside the traffic lights, as in Safari and Arc.
struct TitlebarSidebarToggle: View {
  @Bindable var store: BrowserStore

  var body: some View {
    GeometryReader { geometry in
      let titlebarHeight = geometry.safeAreaInsets.top
      Button {
        store.sidebarIsVisible = false
      } label: {
        Image(systemName: "sidebar.left")
          .font(.system(size: 14))
          .foregroundStyle(.secondary)
          .frame(width: 28, height: max(titlebarHeight, 24))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Hide sidebar (Command-S)")
      .accessibilityLabel("Hide sidebar (Command-S)")
      .offset(x: BrowserChromeLayout.titlebarToggleLeading, y: -titlebarHeight)
    }
  }
}
