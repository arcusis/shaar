// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct FailedPageView: View {
  let store: BrowserStore
  let failure: RendererFailure

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "arrow.clockwise.circle")
        .font(.system(size: 38, weight: .light)).foregroundStyle(.secondary)
      Text(PanelsL10n.string("This page stopped working"))
        .font(.system(size: 24, weight: .medium, design: .rounded))
      Text(failure.pageURL.host() ?? PanelsL10n.string("This page"))
        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
      Text(failure.message).foregroundStyle(.secondary).multilineTextAlignment(.center)
      if failure.reloading {
        ProgressView(PanelsL10n.string("Reloading page…"))
      } else {
        Button(PanelsL10n.string("Reload page")) { store.reloadFailedPage(failure.id) }
          .buttonStyle(.borderedProminent).disabled(!store.canReloadFailure(failure.id))
          .help(PanelsL10n.string("Reload (Command-R)"))
      }
    }
    .padding(32).frame(maxWidth: 440)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
