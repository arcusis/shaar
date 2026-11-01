// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
        TextField(
          SettingsL10n.string("Search shortcuts"), text: $search,
          prompt: Text(SettingsL10n.string("Search shortcuts"))
        )
        .labelsHidden()
      }
      ForEach(menus, id: \.self) { menu in
        Section(SettingsL10n.string(menu)) {
          ForEach(entries.filter { $0.menu == menu }) { entry in
            LabeledContent(entry.localizedTitle) {
              Text(entry.displayKeys)
                .font(.system(.body, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      if entries.isEmpty {
        Section {
          Text(SettingsL10n.format("No shortcuts match \"%@\".", .string(search)))
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }
}
