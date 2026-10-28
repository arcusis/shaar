import SwiftUI

/// Arc-style address shown centered in the page card's top bar.
struct PageAddressField: View {
  @Bindable var store: BrowserStore

  var body: some View {
    let url = store.session.selectedPage?.tab.url
    Button {
      store.showCommand()
      store.commandQuery = url?.absoluteString ?? ""
    } label: {
      HStack(spacing: 6) {
        Image(systemName: url == nil ? "magnifyingglass" : "link")
        Text(url?.host() ?? "Search or enter address")
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .font(.system(size: 13))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 10)
      .frame(height: 26)
      .contentShape(Rectangle())
    }
    .accessibilityLabel("Search or enter address")
    .help(url?.absoluteString ?? "Search or enter address")
  }
}
