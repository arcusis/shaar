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

struct InspectorPageLayout<Page: View>: View {
  let model: InspectorModel?
  let shell: ShaarDevToolsModel?
  let openChromium: () -> Void
  @ViewBuilder let page: () -> Page

  var body: some View {
    GeometryReader { geometry in
      if let shell, shell.isOpen {
        if shell.dock == .floating {
          page().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if shell.dock == .right {
          HStack(spacing: 0) {
            page().frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            resizeHandle(shell: shell, side: .right, available: geometry.size.width)
            ShaarDevToolsPanel(model: shell, inspector: model, openChromium: openChromium)
              .frame(
                width: ShaarDevToolsSizing.side(shell.rightWidth, available: geometry.size.width))
          }
        } else if shell.dock == .left {
          HStack(spacing: 0) {
            ShaarDevToolsPanel(model: shell, inspector: model, openChromium: openChromium)
              .frame(
                width: ShaarDevToolsSizing.side(shell.leftWidth, available: geometry.size.width))
            resizeHandle(shell: shell, side: .left, available: geometry.size.width)
            page().frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
          }
        } else {
          VStack(spacing: 0) {
            page().frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            resizeHandle(shell: shell, side: .bottom, available: geometry.size.height)
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
    .onAppear { syncFloatingWindow() }
    .onChange(of: shell?.dock) { _, _ in syncFloatingWindow() }
    .onChange(of: shell?.isOpen) { _, _ in syncFloatingWindow() }
  }

  private func syncFloatingWindow() {
    guard let shell else { return }
    if shell.isOpen && shell.dock == .floating {
      if shell.floatingWindow == nil {
        let window = ShaarDevToolsFloatingWindow(
          model: shell, inspector: model, openChromium: openChromium)
        shell.floatingWindow = window
        window.present()
      }
    } else {
      shell.floatingWindow?.dismiss()
      shell.floatingWindow = nil
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
    shell: ShaarDevToolsModel, side: ShaarDevToolsDock, available: CGFloat
  ) -> some View {
    let vertical = side == .bottom
    return ShaarDevToolsSplitHandle(vertical: vertical) {
      splitLength(shell, side: side)
    } changed: { start, translation in
      applySplit(
        shell, side: side, start: start, translation: translation, available: available)
    }
    .frame(width: vertical ? nil : 5, height: vertical ? 5 : nil)
    .accessibilityLabel(
      ShellL10n.string(vertical ? "Resize DevTools height" : "Resize DevTools width")
    )
  }

  private func splitLength(_ shell: ShaarDevToolsModel, side: ShaarDevToolsDock) -> CGFloat {
    switch side {
    case .bottom: shell.bottomHeight
    case .right: shell.rightWidth
    case .left: shell.leftWidth
    case .floating: 0
    }
  }

  private func applySplit(
    _ shell: ShaarDevToolsModel, side: ShaarDevToolsDock, start: CGFloat, translation: CGFloat,
    available: CGFloat
  ) {
    let next = ShaarDevToolsSplitDrag.proposed(
      start: start, translation: translation, edge: side, available: available)
    switch side {
    case .bottom: shell.bottomHeight = next
    case .right: shell.rightWidth = next
    case .left: shell.leftWidth = next
    case .floating: break
    }
  }
}
