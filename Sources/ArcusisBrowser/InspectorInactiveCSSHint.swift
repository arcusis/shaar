// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct InspectorInactiveCSSHint: View {
  let reason: String

  var body: some View {
    Label {
      Text(InspectorDetailsL10n.string(reason))
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Text(InspectorDetailsL10n.string("Inactive"))
        .fontWeight(.medium)
        .fixedSize()
    }
    .font(.system(size: 10))
    .foregroundStyle(.secondary)
    .padding(.leading, 8)
    .accessibilityElement(children: .combine)
  }
}
