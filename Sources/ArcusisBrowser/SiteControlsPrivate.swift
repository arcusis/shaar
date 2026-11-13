// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import SwiftUI

/// A private target carries all three transient identities; no regular profile fallback.
@MainActor @Observable
final class PrivateSiteControlsModel: Identifiable {
  let id = UUID()
  let tabID: String
  let windowID: String
  let contextID: String
  let origin: String
  private(set) var allowed: Bool?
  private(set) var saving = false
  private(set) var failure: String?
  private let runtime: ARCChromiumRuntime
  @ObservationIgnored private var changeRevision = 0
  @ObservationIgnored private var readRevision = 0

  static func loadFailure(language: BrowserLanguage = .currentLaunchLanguage) -> String {
    BrowserLocalization.string(
      "Could not load private site cookie settings. Try again.", table: "Shell", language: language)
  }

  static func updateFailure(language: BrowserLanguage = .currentLaunchLanguage) -> String {
    BrowserLocalization.string(
      "Could not update private site cookie settings. Try again.", table: "Shell", language: language)
  }

  init?(
    tabID: String, windowID: String, contextID: String, url: URL,
    runtime: ARCChromiumRuntime
  ) {
    guard let origin = SiteOrigin.string(for: url) else { return nil }
    self.runtime = runtime
    self.tabID = tabID
    self.windowID = windowID
    self.contextID = contextID
    self.origin = origin
  }

  convenience init?(store: BrowserStore, runtime: ARCChromiumRuntime) {
    guard let page = store.privatePage, let tab = store.session.selectedPage?.tab else {
      return nil
    }
    self.init(
      tabID: tab.id.uuidString, windowID: page.windowID,
      contextID: page.contextID, url: tab.url, runtime: runtime)
  }

  func load() async {
    readRevision += 1
    let currentRead = readRevision
    let currentChange = changeRevision
    do {
      let current = try await runtime.privateCookies(
        forTabID: tabID, windowID: windowID, contextID: contextID, origin: origin
      ).boolValue
      guard !Task.isCancelled, currentRead == readRevision, currentChange == changeRevision else {
        return
      }
      allowed = current
    } catch {
      guard !Task.isCancelled, currentRead == readRevision, currentChange == changeRevision else {
        return
      }
      failure = Self.loadFailure()
    }
  }

  func setAllowed(_ value: Bool) async {
    guard !saving, allowed != nil else { return }
    changeRevision += 1
    saving = true
    defer {
      saving = false
      changeRevision += 1
    }
    do {
      try await runtime.setPrivateCookiesAllowed(
        value, tabID: tabID, windowID: windowID, contextID: contextID, origin: origin)
      guard !Task.isCancelled else { return }
      let applied = try await runtime.privateCookies(
        forTabID: tabID, windowID: windowID, contextID: contextID, origin: origin
      ).boolValue
      guard !Task.isCancelled else { return }
      allowed = applied
      failure =
        applied == value
        ? nil
        : ARCBridgeLocalizedString("The private cookie setting was not applied.")
    } catch {
      guard !Task.isCancelled else { return }
      failure = Self.updateFailure()
    }
  }
}

struct PrivateSiteControlsButton: View {
  weak var store: BrowserStore?
  let runtime: ARCChromiumRuntime
  @State private var model: PrivateSiteControlsModel?

  var body: some View {
    Button {
      guard let store else { return }
      model = PrivateSiteControlsModel(store: store, runtime: runtime)
    } label: {
      Image(systemName: "slider.horizontal.3").frame(width: 28, height: 28)
    }
    .help(ShellL10n.string("Site controls"))
    .accessibilityLabel(ShellL10n.string("Site controls"))
    .disabled(store?.showsStartPage != false)
    .popover(item: $model, arrowEdge: .top) { model in
      PrivateSiteControlsPanel(model: model)
    }
    .onChange(of: store?.selectedTabID) { model = nil }
    .onChange(of: store?.selectedTab?.url) { model = nil }
  }
}

struct PrivateSiteControlsPanel: View {
  static let headingTraits: AccessibilityTraits = .isHeader

  let model: PrivateSiteControlsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ShellL10n.text("Private site controls")
        .font(.headline)
        .accessibilityAddTraits(Self.headingTraits)
      Text(model.origin)
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .environment(\.layoutDirection, .leftToRight)
      Divider()
      Toggle(
        ShellL10n.string("Allow cookies for this site"),
        isOn: Binding(
          get: { model.allowed == true }, set: { value in Task { await model.setAllowed(value) } }
        )
      )
      .toggleStyle(.switch)
      .disabled(model.allowed == nil || model.saving)
      ShellL10n.text("Also allows site storage. Reload the page after changing this setting.")
      ShellL10n.text(
        "Private windows for this profile share this setting. Closing the window that allowed it blocks the site again. Turning it off blocks it in every private window; existing data is erased when the last private window closes."
      )
      if let failure = model.failure { Text(failure).foregroundStyle(.red) }
    }
    .font(.callout)
    .padding(18)
    .frame(width: 340)
    .task { await model.load() }
  }
}
