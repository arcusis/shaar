// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI

struct ExtensionPopupContext: Identifiable, Equatable {
  let id: String
  let profileID: UUID
  let tabID: UUID
  let extensionID: String
  let name: String
}

enum ExtensionPanelRoute: Identifiable, Equatable {
  case list(profileID: UUID, tabID: UUID?)
  case popup(ExtensionPopupContext)

  var id: String {
    switch self {
    case .list(let profile, let tab): "list-\(profile)-\(tab?.uuidString ?? "empty")"
    case .popup(let popup): popup.id
    }
  }
}

struct ExtensionToolbar: View {
  @Bindable var engine: BrowserEngine
  let store: BrowserStore

  private var extensionModel: ExtensionManagerModel {
    ExtensionManagerModel.shared(
      runtime: engine.runtime, preferences: store.preferences,
      profileID: store.session.selectedSpace.profileID)
  }

  var body: some View {
    HStack(spacing: 6) {
      ForEach(extensionModel.pinnedExtensions) { pinned in
        Button {
          engine.executeExtension(pinned.id)
        } label: {
          ExtensionIcon(image: extensionModel.icons[pinned.id], size: 16)
        }
        .buttonStyle(.plain)
        .help(pinned.name)
        .accessibilityLabel(pinned.name)
        .disabled(store.session.selectedPage == nil)
      }
      Button {
        engine.showExtensionList()
      } label: {
        Image(systemName: "puzzlepiece.extension")
      }
      .help(PanelsL10n.format("Extensions for %@", .string(store.profileName)))
      .accessibilityLabel(PanelsL10n.format("Extensions for %@", .string(store.profileName)))
    }
    .popover(
      item: engine.presentsNativePanels ? $engine.extensionPanel : .constant(nil),
      arrowEdge: .top
    ) { route in
      switch route {
      case .list:
        ExtensionManagerPanel(engine: engine, store: store)
      case .popup(let context):
        VStack(spacing: 0) {
          HStack {
            Text(context.name).font(.headline).lineLimit(1)
            Spacer()
            Button {
              engine.extensionPanel = nil
            } label: {
              Image(systemName: "xmark")
            }
            .buttonStyle(.plain).help(PanelsL10n.string("Close extension"))
          }
          .padding(12)
          Divider()
          ExtensionPopupPage(engine: engine, popupID: context.id)
            .frame(width: engine.extensionPopupSize.width, height: engine.extensionPopupSize.height)
        }
      }
    }
    .task(id: store.session.selectedSpace.profileID) { extensionModel.refresh() }
  }
}

/// Manage installed extensions in place: run, turn on or off, pin, inspect, and remove.
struct ExtensionManagerPanel: View {
  let engine: BrowserEngine
  let store: BrowserStore
  @State private var detailID: String?

  private var model: ExtensionManagerModel {
    ExtensionManagerModel.shared(
      runtime: engine.runtime, preferences: store.preferences,
      profileID: store.session.selectedSpace.profileID)
  }

  var body: some View {
    Group {
      if let detail = model.extensions.first(where: { $0.id == detailID }) {
        ExtensionDetails(model: model, item: detail) { detailID = nil }
      } else {
        list
      }
    }
    .frame(width: 320)
    .task { model.refresh() }
  }

  private var list: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 2) {
        Text(PanelsL10n.string("Extensions")).font(.headline)
        Text(PanelsL10n.format("%@ profile", .string(store.profileName)))
          .font(.caption).foregroundStyle(.secondary)
      }
      .padding([.horizontal, .top], 16)
      .padding(.bottom, 10)
      Divider()
      ExtensionManagerList(
        model: model, canRun: store.session.selectedPage != nil,
        run: { engine.executeExtension($0) }, showDetails: { detailID = $0 })
      Divider()
      Button {
        engine.extensionPanel = nil
        store.perform(.open(BrowserExtension.storeCatalogURL))
      } label: {
        Label(PanelsL10n.string("Add Extensions…"), systemImage: "plus")
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
  }
}

struct ExtensionRowActions {
  let run: () -> Void
  let setPinned: (Bool) -> Void
  let setEnabled: (Bool) -> Void
  let showDetails: () -> Void
}

struct ExtensionRow: View {
  let item: ManagedExtension
  let icon: NSImage?
  let pinned: Bool
  let canRun: Bool
  let actions: ExtensionRowActions

  var body: some View {
    HStack(spacing: 10) {
      Button(action: actions.run) {
        HStack(spacing: 10) {
          ExtensionIcon(image: icon, size: 24)
            .opacity(item.enabled ? 1 : 0.4)
          Text(item.name)
            .lineLimit(1)
            .foregroundStyle(item.enabled ? .primary : .secondary)
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!item.enabled || !canRun)
      .help(
        item.enabled
          ? PanelsL10n.format("Open %@", .string(item.name))
          : PanelsL10n.format("%@ is off", .string(item.name)))
      Button {
        actions.setPinned(!pinned)
      } label: {
        Image(systemName: pinned ? "pin.fill" : "pin")
          .foregroundStyle(pinned ? Color.accentColor : .secondary)
      }
      .buttonStyle(.plain)
      .disabled(!item.enabled)
      .help(PanelsL10n.string(pinned ? "Unpin from toolbar" : "Pin to toolbar"))
      .accessibilityLabel(
        pinned
          ? PanelsL10n.format("Unpin %@", .string(item.name))
          : PanelsL10n.format("Pin %@", .string(item.name)))
      Toggle(
        "", isOn: Binding(get: { item.enabled }, set: actions.setEnabled)
      )
      .toggleStyle(.switch)
      .controlSize(.mini)
      .labelsHidden()
      .disabled(!item.mayDisable)
      .accessibilityLabel(
        item.enabled
          ? PanelsL10n.format("Turn off %@", .string(item.name))
          : PanelsL10n.format("Turn on %@", .string(item.name)))
      Button(action: actions.showDetails) {
        Image(systemName: "info.circle").foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help(PanelsL10n.string("Details"))
      .accessibilityLabel(PanelsL10n.format("Details for %@", .string(item.name)))
    }
    .hoverRowBackground()
  }
}

/// The padded, rounded hover highlight shared by rows in Shaar's popovers.
struct HoverRowBackground: ViewModifier {
  @State private var isHovered = false

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(
        Color.primary.opacity(isHovered ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 8)
      )
      .onHover { isHovered = $0 }
  }
}

extension View {
  func hoverRowBackground() -> some View { modifier(HoverRowBackground()) }
}

struct ExtensionIcon: View {
  let image: NSImage?
  let size: CGFloat

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().interpolation(.high)
      } else {
        Image(systemName: "puzzlepiece.extension.fill").resizable().scaledToFit()
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: size, height: size)
  }
}

struct ExtensionPopupPage: NSViewRepresentable {
  let engine: BrowserEngine
  let popupID: String

  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ container: NSView, context: Context) {
    guard let page = engine.runtime.view(forExtensionPopupID: popupID) else { return }
    if page.superview !== container {
      for child in container.subviews { child.removeFromSuperview() }
      page.removeFromSuperview()
      page.frame = container.bounds
      page.autoresizingMask = [.width, .height]
      container.addSubview(page)
    }
  }

  static func dismantleNSView(_ view: NSView, coordinator: ()) {
    for child in view.subviews { child.removeFromSuperview() }
  }
}
