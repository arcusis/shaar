// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

struct PrivateStartPage: View {
  weak var store: PrivateBrowserStore?
  @State private var query = ""
  @FocusState private var searchIsFocused: Bool

  private var searchEngineName: String {
    store?.searchEngine.displayName ?? ShellL10n.string("selected search engine")
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        Image(systemName: "eye.slash")
          .font(.system(size: 38, weight: .light))
          .foregroundStyle(.purple)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 8) {
          ShellL10n.text("A little more private.")
            .font(.system(size: 30, weight: .semibold, design: .rounded))
          ShellL10n.text(
            "Your browsing history stays out of this Mac’s saved history. Private windows for the same profile share temporary site data until the last one closes."
          )
          .foregroundStyle(.secondary)
        }
        HStack(spacing: 10) {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField(
            ShellL10n.format(
              "Search with %1$@ or enter address", arguments: [.string(searchEngineName)]),
            text: $query
          )
          .textFieldStyle(.plain)
          .focused($searchIsFocused)
          .onSubmit { store?.navigate(query) }
          .accessibilityLabel(
            ShellL10n.format("Private search with %1$@", arguments: [.string(searchEngineName)]))
          Button {
            store?.navigate(query)
          } label: {
            Image(
              systemName: BrowserLanguage.currentLaunchLanguage.isRightToLeft
                ? "arrow.left" : "arrow.right")
          }
          .buttonStyle(.plain)
          .accessibilityLabel(ShellL10n.string("Search privately"))
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        VStack(alignment: .leading, spacing: 12) {
          ShellL10n.text("Current protections").font(.headline)
          protection(
            "Cookies and storage blocked for addresses opened here",
            symbol: "externaldrive.badge.xmark")
          protection("HTTPS first for addresses opened here", symbol: "lock")
          protection(
            "Permission requests denied; autofill and password saving off",
            symbol: "person.crop.circle.badge.xmark")
        }
        .font(.callout)
        Divider()
        VStack(alignment: .leading, spacing: 8) {
          ShellL10n.text("Know the limits").font(.headline)
          ShellL10n.text(
            "Private browsing does not hide your IP address or activity from websites, your employer, or your internet provider. Downloads remain on disk."
          )
          ShellL10n.text(
            "This engine cannot enforce a global cookie/storage block across redirects, page links, or every frame. Tracker and third-party request blocking, forced HTTPS across page links and redirects, referrer trimming, WebRTC IP limits, and disabling already permitted private extensions are unavailable."
          )
        }
        .font(.callout)
        .foregroundStyle(.secondary)
      }
      .frame(maxWidth: 550, alignment: .leading)
      .padding(40)
      .frame(maxWidth: .infinity, minHeight: 540)
    }
    .onAppear { searchIsFocused = true }
  }

  private func protection(_ title: String, symbol: String) -> some View {
    Label(ShellL10n.string(title), systemImage: symbol)
      .labelStyle(.titleAndIcon)
      .fixedSize(horizontal: false, vertical: true)
  }
}
