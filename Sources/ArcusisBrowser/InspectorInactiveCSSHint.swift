// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct InspectorInactiveCSSHint: View {
  let reason: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
      Text(InspectorDetailsL10n.string("Inactive")).fontWeight(.semibold)
      Text(InspectorDetailsL10n.string(reason)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .font(.system(size: 10)).padding(.horizontal, 6).padding(.vertical, 3)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
    .help(InspectorDetailsL10n.string(reason))
    .accessibilityElement(children: .combine)
  }
}
