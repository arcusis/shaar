import AppKit
import SwiftUI

/// Every menu shortcut, grouped by menu, read from the same menu definitions the app installs.
struct SettingsShortcutsPane: View {
  @State private var search = ""
  @State private var catalog = ShortcutCatalog.installed()

  private var entries: [ShortcutCatalog.Entry] {
    guard !search.isEmpty else { return catalog.entries }
    return catalog.entries.filter {
      $0.title.localizedCaseInsensitiveContains(search)
        || $0.menu.localizedCaseInsensitiveContains(search)
        || $0.displayKeys.localizedCaseInsensitiveContains(search)
    }
  }

  private var menus: [String] {
    var seen = Set<String>()
    return entries.map(\.menu).filter { seen.insert($0).inserted }
  }

  var body: some View {
    Form {
      Section {
        TextField("Search shortcuts", text: $search, prompt: Text("Search shortcuts"))
          .labelsHidden()
      }
      ForEach(menus, id: \.self) { menu in
        Section(menu) {
          ForEach(entries.filter { $0.menu == menu }) { entry in
            LabeledContent(entry.title) {
              Text(entry.displayKeys)
                .font(.system(.body, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      if entries.isEmpty {
        Section { Text("No shortcuts match \"\(search)\".").foregroundStyle(.secondary) }
      }
    }
    .formStyle(.grouped)
  }
}
