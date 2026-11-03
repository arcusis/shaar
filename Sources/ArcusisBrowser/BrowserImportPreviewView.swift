// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

struct BrowserImportPreviewView: View {
  let items: [BrowserImportItem]
  let profileName: String
  let error: String?
  let canImport: Bool
  let onCancel: () -> Void
  let onImport: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(PanelsL10n.string("Import from another browser")).font(.title2.weight(.semibold))
      if let error {
        Text(error).foregroundStyle(.secondary)
      } else {
        Text(
          PanelsL10n.format(
            "%d bookmarks are ready to import into %@.", .integer(items.count),
            .string(profileName)))
        List(items.prefix(40)) { item in
          VStack(alignment: .leading) {
            Text(item.title).lineLimit(1)
            Text(item.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        Text(
          PanelsL10n.string(
            "History import requires an engine feature that is not available in this build.")
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Spacer()
        Button(PanelsL10n.string("Cancel"), action: onCancel)
        if error == nil {
          Button(PanelsL10n.string("Import Bookmarks"), action: onImport)
            .keyboardShortcut(.defaultAction)
            .disabled(!canImport)
        }
      }
    }
    .padding(24).frame(width: 520, height: 440)
  }
}
