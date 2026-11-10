// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct ShaarA11yOverlayControls: View {
  @Bindable var model: ShaarA11yOverlayModel
  let inspector: InspectorModel?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle(
        isOn: Binding(
          get: { model.enabled },
          set: { model.setEnabled($0, caller: inspector) })
      ) {
        Text(ShellL10n.string("Show focus order and contrast"))
          .font(.system(size: 12))
      }
      .toggleStyle(.switch)
      .controlSize(.small)
      .accessibilityIdentifier("shaar.devtools.a11yOverlay")
      if !model.summary.isEmpty {
        Text(model.summary)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("shaar.devtools.a11yOverlay.summary")
      }
      if let failure = model.failure {
        Text(failure)
          .font(.system(size: 11))
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("shaar.devtools.a11yOverlay.failure")
      }
      ForEach(model.rows) { row in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(row.title)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .frame(width: 36, alignment: .leading)
          Text(row.detail)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .accessibilityIdentifier("shaar.devtools.a11yOverlay.row.\(row.id)")
      }
    }
  }
}
