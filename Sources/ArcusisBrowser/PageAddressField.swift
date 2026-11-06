// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

/// Arc-style address shown centered in the page card's top bar.
struct PageAddressField: View {
  @Bindable var store: BrowserStore
  var tabID: UUID? = nil
  @AppStorage(DevelopmentModePreference.key) private var developmentModeEnabled = true

  static func displayAddress(for url: URL?) -> String? {
    guard let url, let host = url.host(), !host.isEmpty else { return nil }
    let shownHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    return url.port.map { "\(shownHost):\($0)" } ?? shownHost
  }

  static func accessibilityLabel(for url: URL?) -> String {
    guard let url else { return CommandPanel.searchPrompt }
    let address = ShellL10n.format(
      "Current address: %@. Search or enter address",
      arguments: [.string(url.absoluteString)])
    return "\(CommandPanel.localizedDisplayName). \(address)"
  }

  private func displayAddress(for url: URL?) -> String {
    if developmentModeEnabled, let url, DevelopmentPage.detect(url: url).isDevelopmentPage {
      return url.absoluteString
    }
    return Self.displayAddress(for: url) ?? CommandPanel.searchPrompt
  }

  var body: some View {
    let url =
      tabID.flatMap { id in store.session.selectedSpace.tabs.first { $0.id == id }?.url }
      ?? store.session.selectedPage?.tab.url
    Button {
      if let tabID { store.focusSplitTab(tabID) }
      store.showAddressEditor(tabID: tabID)
    } label: {
      HStack(spacing: 6) {
        Image(systemName: url == nil ? "magnifyingglass" : "link")
        Text(displayAddress(for: url))
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .font(.system(size: 13))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 10)
      .frame(height: 26)
      .contentShape(Rectangle())
    }
    .accessibilityLabel(Self.accessibilityLabel(for: url))
    .browserChromeControl("browser.chrome.address")
    .help(url?.absoluteString ?? CommandPanel.searchPrompt)
  }
}
