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

  var body: some View {
    HStack(spacing: 6) {
      ForEach(engine.pinnedExtensions) { pinned in
        Button {
          engine.executeExtension(pinned.id)
        } label: {
          ExtensionIcon(image: engine.extensionIcons[pinned.id], size: 16)
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
      .help("Extensions for \(store.profileName)")
      .accessibilityLabel("Extensions for \(store.profileName)")
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
            .buttonStyle(.plain).help("Close extension")
          }
          .padding(12)
          Divider()
          ExtensionPopupPage(engine: engine, popupID: context.id)
            .frame(width: engine.extensionPopupSize.width, height: engine.extensionPopupSize.height)
        }
      }
    }
  }
}

/// Manage installed extensions in place: run, turn on or off, pin, inspect, and remove.
struct ExtensionManagerPanel: View {
  let engine: BrowserEngine
  let store: BrowserStore
  @State private var detailID: String?

  var body: some View {
    Group {
      if let detail = engine.managedExtensions.first(where: { $0.id == detailID }) {
        ExtensionDetailView(engine: engine, item: detail) { detailID = nil }
      } else {
        list
      }
    }
    .frame(width: 320)
  }

  private var list: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Extensions").font(.headline)
        Text("\(store.profileName) profile").font(.caption).foregroundStyle(.secondary)
      }
      .padding([.horizontal, .top], 16)
      .padding(.bottom, 10)
      Divider()
      if engine.managedExtensions.isEmpty {
        ContentUnavailableView(
          "No Extensions", systemImage: "puzzlepiece.extension",
          description: Text("Extensions you add appear here for this profile.")
        )
        .padding(.vertical, 12)
      } else {
        ScrollView {
          VStack(spacing: 2) {
            ForEach(engine.managedExtensions) { item in
              ExtensionRow(
                item: item, icon: engine.extensionIcons[item.id],
                pinned: engine.pinnedExtensionIDs.contains(item.id),
                canRun: store.session.selectedPage != nil,
                actions: ExtensionRowActions(
                  run: { engine.executeExtension(item.id) },
                  setPinned: { engine.setExtension(item.id, pinned: $0) },
                  setEnabled: { engine.setExtension(item.id, enabled: $0) },
                  showDetails: { detailID = item.id }))
            }
          }
          .padding(8)
        }
        .frame(maxHeight: 360)
        .fixedSize(horizontal: false, vertical: true)
      }
      Divider()
      Button {
        engine.extensionPanel = nil
        store.perform(.open(URL(string: "https://chromewebstore.google.com/category/extensions")!))
      } label: {
        Label("Add Extensions…", systemImage: "plus")
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
  @State private var isHovered = false

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
      .help(item.enabled ? "Open \(item.name)" : "\(item.name) is off")
      Button {
        actions.setPinned(!pinned)
      } label: {
        Image(systemName: pinned ? "pin.fill" : "pin")
          .foregroundStyle(pinned ? Color.accentColor : .secondary)
      }
      .buttonStyle(.plain)
      .disabled(!item.enabled)
      .help(pinned ? "Unpin from toolbar" : "Pin to toolbar")
      .accessibilityLabel(pinned ? "Unpin \(item.name)" : "Pin \(item.name)")
      Toggle(
        "", isOn: Binding(get: { item.enabled }, set: actions.setEnabled)
      )
      .toggleStyle(.switch)
      .controlSize(.mini)
      .labelsHidden()
      .disabled(!item.mayDisable)
      .accessibilityLabel(item.enabled ? "Turn off \(item.name)" : "Turn on \(item.name)")
      Button(action: actions.showDetails) {
        Image(systemName: "info.circle").foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Details")
      .accessibilityLabel("Details for \(item.name)")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(
      Color.primary.opacity(isHovered ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 8)
    )
    .onHover { isHovered = $0 }
  }
}

private struct ExtensionDetailView: View {
  let engine: BrowserEngine
  let item: ManagedExtension
  let back: () -> Void
  @State private var confirmsRemoval = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button(action: back) {
        Label("Extensions", systemImage: "chevron.left")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      HStack(spacing: 12) {
        ExtensionIcon(image: engine.extensionIcons[item.id], size: 40)
        VStack(alignment: .leading, spacing: 2) {
          Text(item.name).font(.headline).lineLimit(2)
          Text("Version \(item.version)").font(.caption).foregroundStyle(.secondary)
        }
      }
      if !item.description.isEmpty {
        Text(item.description).font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      detailSection("Permissions", values: item.permissions)
      detailSection("Site access", values: item.hostPermissions)
      Divider()
      Button("Remove Extension…", role: .destructive) { confirmsRemoval = true }
        .disabled(!item.mayDisable)
    }
    .padding(16)
    .confirmationDialog(
      "Remove \(item.name)?", isPresented: $confirmsRemoval, titleVisibility: .visible
    ) {
      Button("Remove", role: .destructive) {
        engine.removeExtension(item.id)
        back()
      }
    } message: {
      Text("Its data in this profile is deleted. You can add it again from the Chrome Web Store.")
    }
  }

  @ViewBuilder
  private func detailSection(_ title: String, values: [String]) -> some View {
    if !values.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        ForEach(values, id: \.self) { value in
          Text(value).font(.caption).lineLimit(1).truncationMode(.middle)
        }
      }
    }
  }
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
