// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct PrivateStartPage: View {
  let store: PrivateBrowserStore
  @State private var query = ""
  @FocusState private var searchIsFocused: Bool

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        Image(systemName: "eye.slash")
          .font(.system(size: 38, weight: .light))
          .foregroundStyle(.purple)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 8) {
          Text("A little more private.")
            .font(.system(size: 30, weight: .semibold, design: .rounded))
          Text(
            "Your browsing history stays out of this Mac’s saved history. Private windows for the same profile share temporary site data until the last one closes."
          )
          .foregroundStyle(.secondary)
        }
        HStack(spacing: 10) {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField("Search with \(store.searchEngine.displayName) or enter address", text: $query)
            .textFieldStyle(.plain)
            .focused($searchIsFocused)
            .onSubmit { store.navigate(query) }
            .accessibilityLabel("Private search with \(store.searchEngine.displayName)")
          Button {
            store.navigate(query)
          } label: {
            Image(systemName: "arrow.right")
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Search privately")
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        VStack(alignment: .leading, spacing: 12) {
          Text("Current protections").font(.headline)
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
          Text("Know the limits").font(.headline)
          Text(
            "Private browsing does not hide your IP address or activity from websites, your employer, or your internet provider. Downloads remain on disk."
          )
          Text(
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
    Label(title, systemImage: symbol)
      .labelStyle(.titleAndIcon)
      .fixedSize(horizontal: false, vertical: true)
  }
}
