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
    Button {
      engine.showExtensionList()
    } label: {
      Image(systemName: "puzzlepiece.extension")
    }
    .help("Extensions for \(store.profileName)")
    .accessibilityLabel("Extensions for \(store.profileName)")
    .popover(
      item: engine.presentsNativePanels ? $engine.extensionPanel : .constant(nil),
      arrowEdge: .top
    ) { route in
      switch route {
      case .list:
        ExtensionList(engine: engine, store: store)
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

private struct ExtensionList: View {
  let engine: BrowserEngine
  let store: BrowserStore

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Extensions").font(.headline)
      Text("\(store.profileName) profile").font(.caption).foregroundStyle(.secondary)
      Divider()
      if engine.extensions.isEmpty {
        Text("No extensions in this profile.").foregroundStyle(.secondary)
      }
      ForEach(engine.extensions) { browserExtension in
        Button {
          engine.executeExtension(browserExtension.id)
        } label: {
          HStack {
            Image(systemName: "puzzlepiece.extension")
            Text(browserExtension.name).lineLimit(2)
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(store.session.selectedSpace.selectedTabID == nil)
      }
      Divider()
      Button("Get Bitwarden…") {
        engine.extensionPanel = nil
        store.perform(
          .open(
            URL(
              string:
                "https://chromewebstore.google.com/detail/bitwarden-password-manager/nngceckbapebfimnlniiiahkandclblb"
            )!))
      }
    }
    .padding(18)
    .frame(width: 290)
    .onAppear { engine.refreshExtensions() }
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
