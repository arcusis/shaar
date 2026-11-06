// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The developer shell and Inspector occupy layout space inside each page card.
struct InspectorPage: View {
  let engine: BrowserEngine
  let tabID: UUID
  var autofocus = true
  var body: some View {
    InspectorPageLayout(
      model: engine.inspectors[tabID], shell: engine.shaarDevTools[tabID],
      openChromium: { engine.openChromiumDeveloperTools(for: tabID) },
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
      model: session.inspectors[tabID], shell: session.shaarDevTools[tabID],
      openChromium: { session.openChromiumDeveloperTools(for: tabID) },
      page: { PrivateBrowserPage(session: session, tabID: tabID, inSplit: inSplit) }
    )
  }
}

private struct InspectorPageLayout<Page: View>: View {
  let model: InspectorModel?
  let shell: ShaarDevToolsModel?
  let openChromium: () -> Void
  @ViewBuilder let page: () -> Page
  @State private var dragStart: CGFloat?

  var body: some View {
    GeometryReader { geometry in
      if let shell, shell.isOpen {
        if shell.dock == .right && geometry.size.width >= 640 {
          HStack(spacing: 0) {
            page().frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            resizeHandle(shell: shell, vertical: false, available: geometry.size.width)
            ShaarDevToolsPanel(model: shell, inspector: model, openChromium: openChromium)
              .frame(
                width: ShaarDevToolsSizing.right(shell.rightWidth, available: geometry.size.width))
          }
        } else {
          VStack(spacing: 0) {
            page().frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            resizeHandle(shell: shell, vertical: true, available: geometry.size.height)
            ShaarDevToolsPanel(model: shell, inspector: model, openChromium: openChromium)
              .frame(
                height: ShaarDevToolsSizing.bottom(
                  shell.bottomHeight, available: geometry.size.height))
          }
        }
      } else {
        inspectorLayout(in: geometry.size)
      }
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

  private func resizeHandle(
    shell: ShaarDevToolsModel, vertical: Bool, available: CGFloat
  ) -> some View {
    Rectangle()
      .fill(Color.primary.opacity(0.12))
      .frame(width: vertical ? nil : 5, height: vertical ? 5 : nil)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 2)
          .onChanged { value in
            if dragStart == nil { dragStart = vertical ? shell.bottomHeight : shell.rightWidth }
            guard let dragStart else { return }
            if vertical {
              shell.bottomHeight = ShaarDevToolsSizing.bottom(
                dragStart - value.translation.height, available: available)
            } else {
              shell.rightWidth = ShaarDevToolsSizing.right(
                dragStart - value.translation.width, available: available)
            }
          }
          .onEnded { _ in dragStart = nil }
      )
      .accessibilityLabel(
        ShellL10n.string(
          vertical ? "Resize DevTools height" : "Resize DevTools width")
      )
      .accessibilityIdentifier("shaar.devtools.resize")
  }
}
