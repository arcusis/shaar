// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

struct BrowserImportPreviewView: View {
  let items: [BrowserImportItem]
  let source: BrowserImportSource
  let profileName: String
  let error: String?
  let canImport: Bool
  let onCancel: () -> Void
  let onImport: () -> Void

  init(
    items: [BrowserImportItem], source: BrowserImportSource = .chrome, profileName: String,
    error: String?, canImport: Bool, onCancel: @escaping () -> Void,
    onImport: @escaping () -> Void
  ) {
    self.items = items
    self.source = source
    self.profileName = profileName
    self.error = error
    self.canImport = canImport
    self.onCancel = onCancel
    self.onImport = onImport
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(PanelsL10n.string("Import from another browser")).font(.title2.weight(.semibold))
      if let error {
        Text(error).foregroundStyle(.secondary)
      } else {
        Text(PanelsL10n.format("From %@", .string(source.title)))
          .font(.caption).foregroundStyle(.secondary)
        Text(
          PanelsL10n.format(
            "%d bookmarks and %d history entries are ready to import into %@.",
            .integer(items.filter { $0.kind == .bookmark }.count),
            .integer(items.filter { $0.kind == .history }.count), .string(profileName)))
        List(items.prefix(40)) { item in
          VStack(alignment: .leading) {
            HStack {
              Text(item.title).lineLimit(1)
              Spacer()
              Text(PanelsL10n.string(item.kind == .bookmark ? "Bookmark" : "History"))
                .font(.caption).foregroundStyle(.secondary)
            }
            Text(item.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
      }
      HStack {
        Spacer()
        Button(PanelsL10n.string("Cancel"), role: .cancel, action: onCancel)
        if error == nil {
          Button(PanelsL10n.string("Import Data"), action: onImport)
            .keyboardShortcut(.defaultAction)
            .disabled(!canImport)
        }
      }
    }
    .padding(24).frame(width: 520, height: 440)
  }
}
