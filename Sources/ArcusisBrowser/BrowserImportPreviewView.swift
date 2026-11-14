// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

enum BrowserImportPreviewCounts {
  static func count(_ items: [BrowserImportItem]) -> (bookmarks: Int, history: Int) {
    items.reduce(into: (bookmarks: 0, history: 0)) { counts, item in
      if item.kind == .bookmark {
        counts.bookmarks += 1
      } else {
        counts.history += 1
      }
    }
  }

  static func summary(
    bookmarks: Int, history: Int, profileName: String,
    language: BrowserLanguage = .currentLaunchLanguage
  ) -> String {
    let bookmarkCount = BrowserLocalization.plural(
      "%d bookmark", count: bookmarks, table: "Panels", language: language)
    let historyCount = BrowserLocalization.plural(
      "%d history entry", count: history, table: "Panels", language: language)
    return BrowserLocalization.format(
      "%@ and %@ are ready to import into %@.", table: "Panels", language: language,
      arguments: [.string(bookmarkCount), .string(historyCount), .string(profileName)])
  }
}

struct BrowserImportPreviewView: View {
  static let headingTraits: AccessibilityTraits = .isHeader
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
    let counts =
      error == nil ? BrowserImportPreviewCounts.count(items) : (bookmarks: 0, history: 0)

    VStack(alignment: .leading, spacing: 14) {
      Text(PanelsL10n.string("Import from another browser")).font(.title2.weight(.semibold))
        .accessibilityAddTraits(Self.headingTraits)
      if let error {
        Text(error).foregroundStyle(.secondary)
      } else {
        Text(PanelsL10n.format("From %@", .string(source.title)))
          .font(.caption).foregroundStyle(.secondary)
        Text(
          BrowserImportPreviewCounts.summary(
            bookmarks: counts.bookmarks, history: counts.history, profileName: profileName))
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
