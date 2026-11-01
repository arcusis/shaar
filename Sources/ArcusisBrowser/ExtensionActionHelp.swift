// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Keeps native hover help and VoiceOver in sync with the extension's current tab action.
struct ExtensionActionHelp: ViewModifier {
  let model: ExtensionManagerModel
  let item: ManagedExtension
  let tabID: UUID?
  @State private var hoveredHelp: String?

  func body(content: Content) -> some View {
    let help = hoveredHelp ?? model.help(for: item, tabID: tabID)
    content
      .help(help)
      .accessibilityLabel(help)
      .onHover { hoveredHelp = $0 ? model.help(for: item, tabID: tabID) : nil }
      .onChange(of: tabID) { hoveredHelp = nil }
  }
}
