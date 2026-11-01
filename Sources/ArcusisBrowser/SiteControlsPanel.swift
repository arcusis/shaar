// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SecurityInterface
import SwiftUI

/// The toolbar button that opens the site control center for the selected page.
struct SiteControlsButton: View {
  @Bindable var engine: BrowserEngine
  let store: BrowserStore
  @State private var model: SiteControlsModel?

  private var extensionModel: ExtensionManagerModel {
    ExtensionManagerModel.shared(
      runtime: engine.runtime, preferences: store.preferences,
      profileID: store.session.selectedSpace.profileID)
  }

  var body: some View {
    HStack(spacing: 4) {
      if let developer = engine.selectedDeveloperModel {
        DeveloperSimulationBadge(model: developer)
      }
      Button(action: open) {
        Image(systemName: "slider.horizontal.3")
          .frame(width: 28, height: 28)
          .contentShape(Rectangle())
      }
      .help("Site controls")
      .accessibilityLabel("Site controls")
      .disabled(store.session.selectedPage == nil)
      .popover(item: engine.presentsNativePanels ? $model : .constant(nil), arrowEdge: .top) {
        model in
        SiteControlsPanel(
          model: model, extensions: extensionModel, profileName: store.profileName,
          developer: engine.selectedDeveloperModel,
          actions: SiteControlsPanelActions(
            runExtension: { id in
              self.model = nil
              engine.executeExtension(id)
            },
            addExtensions: {
              self.model = nil
              store.perform(.open(BrowserExtension.storeCatalogURL))
            },
            showCertificate: { showCertificate(model) },
            close: { self.model = nil }))
      }
      .onChange(of: store.session.selectedPage?.tab.id) { model = nil }
      .onChange(of: store.session.selectedPage?.tab.url) { model = nil }
    }
  }

  private func open() {
    guard store.sheet == nil, let target = engine.siteControlTarget else { return }
    engine.extensionPanel = nil
    store.dismissCommand()
    model = SiteControlsModel(target: target, backend: engine)
  }

  private func showCertificate(_ model: SiteControlsModel) {
    Task {
      guard let chain = await model.certificateChain(),
        let window = engine.runtime.window(forID: engine.windowID)
      else { return }
      self.model = nil
      SiteCertificateViewer.present(chain, in: window)
    }
  }
}

enum SiteCertificateViewer {
  /// Shows the macOS certificate viewer as a sheet on the browser window, leaf first.
  @MainActor static func present(_ chain: [SecCertificate], in window: NSWindow) {
    SFCertificatePanel.shared().beginSheet(
      for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil, certificates: chain,
      showGroup: true)
  }
}

struct SiteControlsPanelActions {
  let runExtension: (String) -> Void
  let addExtensions: () -> Void
  let showCertificate: () -> Void
  let close: () -> Void
}

struct SiteControlsPanel: View {
  let model: SiteControlsModel
  let extensions: ExtensionManagerModel
  let profileName: String
  var developer: SiteControlsDeveloperModel? = nil
  let actions: SiteControlsPanelActions

  var body: some View {
    SiteControlsScrollContainer { panelContent }
      .task { await model.load() }
  }

  private var panelContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      SiteExtensionsSection(model: extensions, actions: actions)
      if !model.permissions.isEmpty {
        Divider()
        SitePermissionsSection(model: model)
      }
      if model.security != .unavailable {
        Divider()
        SiteSecurityRow(
          security: model.security, hasCertificate: model.hasCertificate,
          action: actions.showCertificate
        )
        .padding(8)
      }
      Divider()
      SiteActionsSection(model: model, close: actions.close)
      if let developer {
        Divider()
        SiteControlsDeveloperSection(model: developer)
      }
      if let failure = model.failure {
        Text(failure)
          .font(.caption).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .padding([.horizontal, .bottom], 16)
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(model.target.host).font(.headline).lineLimit(1).truncationMode(.middle)
      Text("\(profileName) profile").font(.caption).foregroundStyle(.secondary)
    }
    .padding([.horizontal, .top], 16)
    .padding(.bottom, 10)
  }
}

private struct SiteSectionTitle: View {
  let title: String

  init(_ title: String) { self.title = title }

  var body: some View {
    Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      .padding(.horizontal, 8)
  }
}

struct SiteExtensionsSection: View {
  let model: ExtensionManagerModel
  let actions: SiteControlsPanelActions

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      SiteSectionTitle("Extensions")
      HStack(spacing: 4) {
        if model.pinnedExtensions.isEmpty {
          Text("Pin extensions to show them here.")
            .font(.callout).foregroundStyle(.secondary)
            .padding(.leading, 4)
          Spacer(minLength: 0)
        }
        ForEach(model.pinnedExtensions) { pinned in
          Button {
            actions.runExtension(pinned.id)
          } label: {
            ExtensionIcon(image: model.icons[pinned.id], size: 20)
              .frame(width: 32, height: 32)
              .contentShape(Rectangle())
          }
          .help(pinned.name)
          .accessibilityLabel(pinned.name)
        }
        Button(action: actions.addExtensions) {
          Image(systemName: "plus")
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .help("Add Extensions…")
        .accessibilityLabel("Add Extensions")
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 4)
    }
    .padding(8)
    .task { model.refresh() }
  }
}

struct SitePermissionsSection: View {
  let model: SiteControlsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      SiteSectionTitle("Permissions").padding(.bottom, 4)
      ForEach(model.permissions, id: \.self) { permission in
        SitePermissionRow(
          permission: permission, value: model.permissionValues[permission],
          setAllowed: { allowed in Task { await model.setPermission(permission, allowed: allowed) }
          }
        )
      }
    }
    .padding(8)
  }
}

struct SitePermissionRow: View {
  let permission: SitePermission
  let value: SitePermissionValue?
  let setAllowed: (Bool) -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: permission.symbol)
        .frame(width: 20)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 0) {
        Text(permission.title).lineLimit(1)
        if value == .ask {
          Text("Asks first").font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
      Toggle("", isOn: Binding(get: { value == .allow }, set: { setAllowed($0) }))
        .toggleStyle(.switch)
        .controlSize(.mini)
        .labelsHidden()
        .disabled(value == nil)
        .accessibilityLabel(permission.title)
    }
    .hoverRowBackground()
  }
}

struct SiteSecurityRow: View {
  let security: SiteSecurity
  let hasCertificate: Bool
  let action: () -> Void

  var body: some View {
    if hasCertificate {
      Button(action: action) { label }
        .buttonStyle(.plain)
        .help("Show certificate")
    } else {
      label
    }
  }

  private var label: some View {
    HStack(spacing: 10) {
      Image(systemName: security == .secure ? "lock.fill" : "exclamationmark.triangle.fill")
        .frame(width: 20)
        .foregroundStyle(security == .secure ? Color.secondary : Color.orange)
      VStack(alignment: .leading, spacing: 0) {
        Text(security == .secure ? "Secure" : "Not Secure")
        Text(hasCertificate ? "Show certificate" : "This connection is not encrypted")
          .font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      if hasCertificate {
        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
      }
    }
    .contentShape(Rectangle())
    .hoverRowBackground()
  }
}

struct SiteActionsSection: View {
  let model: SiteControlsModel
  let close: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(SiteAction.allCases) { action in
        Button {
          Task { if await model.perform(action) { close() } }
        } label: {
          SiteActionLabel(action: action, running: model.runningAction == action)
        }
        .buttonStyle(.plain)
        .disabled(!model.isAvailable(action))
        .help(action.help)
      }
    }
    .padding(8)
  }
}

struct SiteActionLabel: View {
  let action: SiteAction
  let running: Bool

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: action.symbol).frame(width: 20)
      Text(action.title)
      Spacer(minLength: 0)
      if running {
        ProgressView().controlSize(.small)
      } else if let keys = action.shortcutKeys {
        Text(keys).foregroundStyle(.secondary)
      }
    }
    .foregroundStyle(action == .clearSiteData ? Color.red : Color.primary)
    .contentShape(Rectangle())
    .hoverRowBackground()
  }
}

extension SiteAction {
  /// The menu shortcut that runs the same action, shown beside it.
  var shortcutKeys: String? {
    let command: BrowserMenuCommand? =
      switch self {
      case .reload: .reload
      case .hardReload: .hardReload
      default: nil
      }
    return ShortcutCatalog.displayKeys(for: command)
  }
}

extension SitePermission {
  var title: String {
    switch self {
    case .microphone: "Microphone"
    case .camera: "Camera"
    case .location: "Location"
    case .notifications: "Notifications"
    case .popups: "Pop-ups and Redirects"
    case .sound: "Sound"
    case .autoPictureInPicture: "Automatic Picture-in-Picture"
    }
  }

  var symbol: String {
    switch self {
    case .microphone: WebsitePermissionKind.microphone.symbol
    case .camera: WebsitePermissionKind.camera.symbol
    case .location: WebsitePermissionKind.location.symbol
    case .notifications: WebsitePermissionKind.notifications.symbol
    case .popups: "rectangle.on.rectangle"
    case .sound: "speaker.wave.2"
    case .autoPictureInPicture: "pip"
    }
  }
}
