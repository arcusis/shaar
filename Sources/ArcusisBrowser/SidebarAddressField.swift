import SwiftUI

struct SidebarAddressField: View {
  @Bindable var store: BrowserStore

  var body: some View {
    let url = store.session.selectedPage?.tab.url
    Button {
      store.showCommand()
      store.commandQuery = url?.absoluteString ?? ""
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
        Text(url?.host() ?? "Search or enter address")
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
      }
      .font(.system(size: 12))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
      .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
      .contentShape(RoundedRectangle(cornerRadius: 8))
    }
    .accessibilityLabel("Search or enter address")
    .help(url?.absoluteString ?? "Search or enter address")
  }
}
