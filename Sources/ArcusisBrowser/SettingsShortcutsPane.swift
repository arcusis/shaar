import AppKit
import SwiftUI

struct SettingsShortcutsPane: View {
  @State private var search = ""

  private var entries: [ShortcutCatalog.Entry] {
    let menu = NativeBrowserHost.makeMenu(target: NSApplication.shared)
    let all = ShortcutCatalog(menu: menu).entries
    guard !search.isEmpty else { return all }
    return all.filter {
      $0.title.localizedCaseInsensitiveContains(search)
        || $0.menu.localizedCaseInsensitiveContains(search)
        || $0.displayKeys.localizedCaseInsensitiveContains(search)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Shortcuts").font(.title2.weight(.semibold))
      TextField("Search shortcuts", text: $search)
        .textFieldStyle(.roundedBorder)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 18) {
          ForEach(Array(NSOrderedSet(array: entries.map(\.menu))) as? [String] ?? [], id: \.self) { menu in
            VStack(alignment: .leading, spacing: 8) {
              Text(menu).font(.headline)
              ForEach(entries.filter { $0.menu == menu }) { entry in
                HStack {
                  Text(entry.title)
                  Spacer()
                  Text(entry.displayKeys).foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
              }
            }
          }
        }
      }
    }
    .padding(24)
    .frame(maxWidth: 680, maxHeight: .infinity, alignment: .topLeading)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
