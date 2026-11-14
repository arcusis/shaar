// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI

@MainActor
final class MiniBrowserController {
  let store: BrowserStore
  let engine: BrowserEngine
  let window: NSWindow
  let target: BrowserStore
  let targetWindow: NSWindow
  let profileID: UUID
  var destinationID: UUID
  private var moved = false
  var onClosed: (() -> Void)?
  var onProfileChange: ((UUID, URL?) -> Bool)?

  init(
    events: BrowserRuntimeEvents, target: BrowserStore, targetWindow: NSWindow, url: URL?,
    destination: UUID? = nil
  ) throws {
    self.target = target
    self.targetWindow = targetWindow
    let selected =
      target.session.spaces.first { $0.id == destination } ?? target.session.selectedSpace
    profileID = selected.profileID
    destinationID = selected.id
    let tabs = url.map { [BrowserTab(url: $0)] } ?? []
    let space = BrowserSpace(
      profileID: selected.profileID, name: selected.name,
      symbol: selected.symbol, tint: selected.tint, tabs: tabs)
    store = BrowserStore(
      session: try BrowserSession(
        profiles: target.session.profiles.filter { $0.id == selected.profileID },
        spaces: [space], selectedSpaceID: space.id))
    let id = UUID().uuidString
    try events.runtime.createWindowID(id)
    var initialized = false
    defer {
      if !initialized { _ = events.runtime.closeWindowID(id) }
    }
    guard let window = events.runtime.window(forID: id),
      let content = events.runtime.hostView(forWindowID: id)
    else { throw WorkspaceError.invalidState }
    self.window = window
    engine = try BrowserEngine(events: events, windowID: id, store: store)
    let hosting = NSHostingView(rootView: MiniBrowserWindow(controller: self).shellLocalization())
    hosting.frame = content.bounds
    hosting.autoresizingMask = [.width, .height]
    content.addSubview(hosting)
    window.title = PanelsL10n.string("Mini window")
    window.setContentSize(NSSize(width: 680, height: 520))
    window.minSize = NSSize(width: 440, height: 320)
    engine.onClosed = { [weak self] _ in
      guard let self else { return }
      if !self.moved,
        let tab = self.store.session.selectedSpace.selectedTab
          ?? self.store.session.closedTabs.last?.tab
      {
        _ = self.target.receiveMiniTab(
          tab, in: self.destinationID, profileID: self.profileID, archive: true)
      }
      self.onClosed?()
    }
    engine.reconcile()
    window.center()
    window.makeKeyAndOrderFront(nil)
    initialized = true
  }

  var destinations: [BrowserSpace] {
    target.session.spaces
  }

  func chooseDestination(_ id: UUID) -> Bool {
    guard let space = target.session.spaces.first(where: { $0.id == id }) else { return false }
    if space.profileID == profileID {
      destinationID = id
      return true
    }
    if onProfileChange?(id, store.session.selectedSpace.selectedTab?.url) == true {
      moved = true
      engine.runtime.closeWindowID(engine.windowID)
      return true
    }
    return false
  }

  func openInSpace() {
    guard let tab = store.session.selectedSpace.selectedTab,
      target.receiveMiniTab(tab, in: destinationID, profileID: profileID, archive: false)
    else { return }
    if let image = engine.favicons[tab.id], let newID = target.session.selectedSpace.selectedTabID {
      target.engine?.seedFavicon(image, for: newID)
    }
    // Reopening retains the profile, but loses document state including forms and scroll position.
    moved = true
    targetWindow.makeKeyAndOrderFront(nil)
    engine.runtime.closeWindowID(engine.windowID)
  }

  static func navigationURL(for input: String) -> URL? {
    NavigationInput.address(for: input)
  }

  func navigate(_ text: String) {
    guard let url = Self.navigationURL(for: text) else { return }
    if store.session.selectedPage == nil {
      store.perform(.open(url))
    } else {
      _ = engine.navigateCurrentPage(to: url)
    }
  }
}

struct MiniDestinationSelection {
  private(set) var id: UUID

  mutating func select(_ requested: UUID, route: (UUID) -> Bool) {
    if route(requested) { id = requested }
  }
}

struct MiniBrowserWindow: View {
  let store: BrowserStore
  let engine: BrowserEngine?
  let destinations: [BrowserSpace]
  let onNavigate: (String) -> Void
  let onDestination: (UUID) -> Bool
  let onOpen: () -> Void
  @State private var address: String
  @State private var destination: MiniDestinationSelection

  init(controller: MiniBrowserController) {
    self.init(
      store: controller.store, engine: controller.engine,
      destinations: controller.destinations, destination: controller.destinationID,
      onNavigate: controller.navigate, onDestination: controller.chooseDestination,
      onOpen: controller.openInSpace)
  }

  init(
    store: BrowserStore, engine: BrowserEngine?, destinations: [BrowserSpace], destination: UUID,
    onNavigate: @escaping (String) -> Void, onDestination: @escaping (UUID) -> Bool,
    onOpen: @escaping () -> Void
  ) {
    self.store = store
    self.engine = engine
    self.destinations = destinations
    self.onNavigate = onNavigate
    self.onDestination = onDestination
    self.onOpen = onOpen
    _destination = State(initialValue: MiniDestinationSelection(id: destination))
    _address = State(
      initialValue: store.session.selectedSpace.selectedTab?.url.absoluteString ?? "")
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        TextField(PanelsL10n.string("Enter address"), text: $address)
          .textFieldStyle(.roundedBorder)
          .environment(\.layoutDirection, .leftToRight)
          .accessibilityLabel(PanelsL10n.string("Enter address"))
          .onSubmit { onNavigate(address) }
        Picker(
          PanelsL10n.string("Space"),
          selection: Binding(
            get: { destination.id },
            set: { destination.select($0, route: onDestination) })
        ) {
          ForEach(destinations) { space in
            Text("\(space.name)").tag(space.id)
          }
        }
        .labelsHidden()
        .frame(width: 130)
        Button(PanelsL10n.string("Open in Space"), action: onOpen)
          .disabled(store.session.selectedSpace.selectedTab == nil)
      }
      .padding(10)
      .background(Color(nsColor: .windowBackgroundColor))
      Divider()
      ZStack {
        Color(nsColor: .textBackgroundColor)
        if let engine, let id = store.session.selectedSpace.selectedTabID, engine.pages[id] != nil {
          ChromiumPage(engine: engine, tabID: id)
        } else {
          Text(PanelsL10n.string("Enter an address to get started")).foregroundStyle(.secondary)
        }
      }
    }
    .onChange(of: store.session.selectedSpace.selectedTab?.url) { _, url in
      if let url { address = url.absoluteString }
    }
  }
}
