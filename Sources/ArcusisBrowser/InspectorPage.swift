// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The Shaar Inspector occupies layout space inside each page card.
struct InspectorPage: View {
  let engine: BrowserEngine
  let tabID: UUID
  var autofocus = true
  var body: some View {
    InspectorPageLayout(
      model: engine.inspectors[tabID],
      page: {
        VStack(spacing: 0) {
          if let bridge = engine.developerModels[tabID]?.agentBridge, bridge.needsBanner {
            AgentBridgeBanner(model: bridge)
          }
          ChromiumPage(engine: engine, tabID: tabID, autofocus: autofocus)
        }
      }
    )
  }
}

struct PrivateInspectorPage: View {
  let session: PrivatePageSession
  let tabID: UUID
  var inSplit = false
  var body: some View {
    InspectorPageLayout(
      model: session.inspectors[tabID],
      page: { PrivateBrowserPage(session: session, tabID: tabID, inSplit: inSplit) }
    )
  }
}

struct InspectorPageLayout<Page: View>: View {
  let model: InspectorModel?
  @ViewBuilder let page: () -> Page

  var body: some View {
    GeometryReader { geometry in
      inspectorLayout(in: geometry.size)
    }
  }

  private func inspectorLayout(in size: CGSize) -> some View {
    let vertical = size.width < 560
    let layout =
      vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
    return layout {
      page().frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
      if let model, model.isOpen {
        Divider()
        InspectorPanel(model: model)
          .frame(
            width: vertical ? size.width : 320,
            height: vertical ? min(420, size.height * 0.62) : nil
          )
          .clipped()
      }
    }
    .frame(width: size.width, height: size.height)
    .clipped()
  }

}
