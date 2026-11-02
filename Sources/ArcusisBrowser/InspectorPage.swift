// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The Inspector occupies layout space inside the page card, alongside Chromium's own dock.
struct InspectorPage: View {
  let engine: BrowserEngine
  let tabID: UUID
  var autofocus = true
  var body: some View {
    GeometryReader { geometry in
      let model = engine.inspectors[tabID]
      let vertical = geometry.size.width < 560
      let layout =
        vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
      layout {
        ChromiumPage(engine: engine, tabID: tabID, autofocus: autofocus)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        if let model, model.isOpen {
          Divider()
          InspectorPanel(model: model)
            .frame(
              width: vertical ? nil : 320,
              height: vertical ? min(420, geometry.size.height * 0.62) : nil)
        }
      }
    }
  }
}
