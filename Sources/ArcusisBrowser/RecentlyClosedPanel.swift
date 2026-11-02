// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

struct RecentlyClosedPanel: View {
  let store: BrowserStore
  let spaceID: UUID
  @Environment(\.dismiss) private var dismiss

  private var entries: [ClosedBrowserTab] { store.session.recentlyClosedTabs(in: spaceID) }
  private var ownsContext: Bool { store.session.selectedSpaceID == spaceID }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(PanelsL10n.string("Recently Closed")).font(.title2.weight(.semibold))
          if ownsContext {
            Text(
              PanelsL10n.format(
                "%@ · %@ profile", .string(store.session.selectedSpace.name),
                .string(store.profileName))
            )
            .font(.callout).foregroundStyle(.secondary)
          }
        }
        Spacer()
        Button(PanelsL10n.string("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
      }
      if !ownsContext {
        ContentUnavailableView(PanelsL10n.string("Space changed"), systemImage: "square.stack")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if entries.isEmpty {
        ContentUnavailableView(
          PanelsL10n.string("No recently closed tabs"), systemImage: "arrow.uturn.backward",
          description: Text(PanelsL10n.string("Tabs closed in this space appear here."))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
              Button {
                if store.reopenClosedTab(entry.id, in: spaceID) { dismiss() }
              } label: {
                HStack(spacing: 12) {
                  Image(systemName: entry.tab.isPinned ? "pin" : "globe")
                    .foregroundStyle(.secondary).frame(width: 20)
                  VStack(alignment: .leading, spacing: 4) {
                    Text(entry.tab.title).font(.headline).lineLimit(1)
                    Text(entry.tab.url.absoluteString).font(.caption).foregroundStyle(.secondary)
                      .lineLimit(1).truncationMode(.middle)
                  }
                  Spacer()
                  Image(systemName: "arrow.uturn.backward").foregroundStyle(.secondary)
                }
                .padding(.vertical, 12).contentShape(Rectangle())
              }
              .buttonStyle(.plain).help(PanelsL10n.format("Reopen %@", .string(entry.tab.title)))
              .accessibilityLabel(PanelsL10n.format("Reopen %@", .string(entry.tab.title)))
              Divider()
            }
          }
        }
      }
      HStack {
        Text(PanelsL10n.string("Reopens pages in this space’s profile.")).font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button(PanelsL10n.string("Clear list")) { store.clearClosedTabs(in: spaceID) }
          .disabled(!ownsContext || entries.isEmpty)
      }
    }
    .padding(24).frame(width: 520, height: 410)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}
