import SwiftUI

struct PageNavigationButtons: View {
  @Bindable var store: BrowserStore
  let engine: BrowserEngine?

  var body: some View {
    let id = store.session.selectedPage?.tab.id
    let state = id.flatMap { engine?.pages[$0] }

    HStack(spacing: 4) {
      navigationButton("chevron.left", label: "Back") {
        if let id { engine?.runtime.goBack(inTabID: id.uuidString) }
      }
      .disabled(state?.canGoBack != true)

      navigationButton("chevron.right", label: "Forward") {
        if let id { engine?.runtime.goForward(inTabID: id.uuidString) }
      }
      .disabled(state?.canGoForward != true)

      navigationButton("arrow.clockwise", label: "Reload (Command-R)") {
        store.reloadCurrentPage()
      }
      .disabled(!store.canReloadCurrentPage)
    }
  }

  private func navigationButton(
    _ symbol: String, label: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 13))
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
    .help(label)
    .accessibilityLabel(label)
  }
}
