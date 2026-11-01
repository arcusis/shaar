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

  init?(store: PrivateBrowserStore, runtime: ARCChromiumRuntime) {
    guard let tab = store.selectedTab, let url = URL(string: tab.url),
      let origin = SiteOrigin.string(for: url)
    else { return nil }
    self.runtime = runtime
    tabID = tab.id
    windowID = store.windowID
    contextID = store.contextID
    self.origin = origin
  }

  func load() async {
    do {
      allowed = try await runtime.privateCookies(
        forTabID: tabID, windowID: windowID, contextID: contextID, origin: origin
      ).boolValue
    } catch { failure = error.localizedDescription }
  }

  func setAllowed(_ value: Bool) async {
    guard !saving, allowed != nil else { return }
    saving = true
    defer { saving = false }
    do {
      try await runtime.setPrivateCookiesAllowed(
        value, tabID: tabID, windowID: windowID, contextID: contextID, origin: origin)
      allowed = value
      failure = nil
    } catch { failure = error.localizedDescription }
  }
}

struct PrivateSiteControlsButton: View {
  let store: PrivateBrowserStore
  let runtime: ARCChromiumRuntime
  @State private var model: PrivateSiteControlsModel?

  var body: some View {
    Button {
      model = PrivateSiteControlsModel(store: store, runtime: runtime)
    } label: {
      Image(systemName: "slider.horizontal.3").frame(width: 28, height: 28)
    }
    .help("Site controls")
    .accessibilityLabel("Site controls")
    .disabled(store.showsStartPage)
    .popover(item: $model, arrowEdge: .top) { model in
      PrivateSiteControlsPanel(model: model)
    }
    .onChange(of: store.selectedTabID) { model = nil }
    .onChange(of: store.selectedTab?.url) { model = nil }
  }
}

struct PrivateSiteControlsPanel: View {
  let model: PrivateSiteControlsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Private site controls").font(.headline)
      Text(model.origin).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      Divider()
      Toggle(
        "Allow cookies for this site",
        isOn: Binding(
          get: { model.allowed == true }, set: { value in Task { await model.setAllowed(value) } }
        )
      )
      .toggleStyle(.switch)
      .disabled(model.allowed == nil || model.saving)
      Text("Also allows site storage. Reload the page after changing this setting.")
      Text(
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
