// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The contrast ratio Design already computed, or the limitation Design already recorded.
struct InspectorContrastLine: View {
  let selection: InspectorSelection

  static func ratioText(_ ratio: Double) -> String {
    String(format: "%.2f:1", ratio)
  }

  var body: some View {
    if let ratio = selection.contrast {
      HStack(spacing: 7) {
        Text(InspectorL10n.string("Contrast")).font(.system(size: 11)).foregroundStyle(.secondary)
        Spacer(minLength: 0)
        Text(Self.ratioText(ratio)).font(.system(size: 11, design: .monospaced))
        badge("AA", passes: ratio >= (selection.largeText ? 3 : 4.5))
        badge("AAA", passes: ratio >= (selection.largeText ? 4.5 : 7))
      }
    } else if let reason = selection.contrastLimit {
      Text(InspectorL10n.display(reason)).font(.system(size: 10)).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(
          horizontal: false, vertical: true)
    }
  }

  private func badge(_ title: String, passes: Bool) -> some View {
    Label(title, systemImage: passes ? "checkmark" : "xmark")
      .font(.system(size: 9, weight: .medium)).padding(.horizontal, 5).padding(.vertical, 3)
      .foregroundStyle(passes ? Color.green : .red)
      .background(
        (passes ? Color.green : .red).opacity(0.08), in: RoundedRectangle(cornerRadius: 3)
      )
      .help(InspectorL10n.format(passes ? "%@ passes" : "%@ fails", arguments: [.string(title)]))
  }
}
