// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Observation
import SwiftUI

@MainActor @Observable
final class TabSwitcherController {
  private var recency = TabRecency()
  private(set) var choices: [UUID] = []
  private(set) var index = 0
  private var spaceID: UUID?

  func record(store: BrowserStore) {
    if let tab = store.session.selectedPage?.tab.id {
      recency.record(tab, in: store.session.selectedSpaceID)
    }
    if spaceID != nil && spaceID != store.session.selectedSpaceID { cancel() }
  }

  func advance(store: BrowserStore, reverse: Bool) {
    let space = store.session.selectedSpace
    if choices.isEmpty {
      var available = space.tabs.map(\.id)
      if let selected = store.session.selectedPage?.tab.id, !available.contains(selected) {
        available.insert(selected, at: 0)
      }
      guard available.count > 1 else { return }
      record(store: store)
      choices = recency.ordered(in: space.id, available: available)
      spaceID = space.id
      index = 0
    }
    index = TabRecency.cycle(index, count: choices.count, reverse: reverse)
  }

  func commit(store: BrowserStore) {
    guard let spaceID, choices.indices.contains(index), store.session.selectedSpaceID == spaceID
    else {
      cancel()
      return
    }
    let tab = choices[index]
    cancel()
    store.perform(.tab(space: spaceID, tab: tab))
  }

  func cancel() {
    choices = []
    spaceID = nil
    index = 0
  }
}

struct TabSwitcherPanel: View {
  let store: BrowserStore
  @State private var controller = TabSwitcherController()

  var body: some View {
    ZStack {
      TabSwitcherMonitor(store: store, controller: controller)
        .frame(width: 0, height: 0)
      if !controller.choices.isEmpty {
        VStack(alignment: .leading, spacing: 3) {
          ForEach(Array(controller.choices.enumerated()), id: \.element) { index, id in
            if let tab = store.session.page(forTabID: id)?.tab {
              HStack(spacing: 10) {
                if let icon = store.engine?.favicons[id] {
                  Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                } else {
                  Image(systemName: "globe").frame(width: 16, height: 16)
                }
                Text(tab.title).lineLimit(1)
                Spacer(minLength: 0)
              }
              .padding(8)
              .background(
                index == controller.index ? Color.accentColor.opacity(0.25) : .clear,
                in: RoundedRectangle(cornerRadius: 6))
            }
          }
        }
        .padding(10)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
        .allowsHitTesting(false)
      }
    }
    .onAppear { controller.record(store: store) }
    .onChange(of: store.session.selectedSpaceID) { _, _ in controller.record(store: store) }
    .onChange(of: store.session.selectedPage?.tab.id) { _, _ in controller.record(store: store) }
  }
}

private struct TabSwitcherMonitor: NSViewRepresentable {
  let store: BrowserStore
  let controller: TabSwitcherController

  func makeNSView(context: Context) -> TabSwitcherMonitorView {
    let view = TabSwitcherMonitorView()
    view.store = store
    view.controller = controller
    return view
  }

  func updateNSView(_ view: TabSwitcherMonitorView, context: Context) {
    view.store = store
    view.controller = controller
  }

  static func dismantleNSView(_ view: TabSwitcherMonitorView, coordinator: ()) {
    view.detach()
  }
}

@MainActor
private final class TabSwitcherMonitorView: NSView {
  weak var store: BrowserStore?
  var controller: TabSwitcherController?
  private var monitor: Any?
  private var resignObserver: NSObjectProtocol?

  isolated deinit { detach() }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if window !== newWindow { detach() }
    super.viewWillMove(toWindow: newWindow)
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window, monitor == nil else { return }
    resignObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification, object: window, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.controller?.cancel() }
    }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
      [weak self] event in
      guard let self else { return event }
      return self.route(event)
    }
  }
  func detach() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    resignObserver = nil
    controller?.cancel()
  }
  private func route(_ event: NSEvent) -> NSEvent? {
    guard let window, window.isKeyWindow, let store, let controller else { return event }
    if !controller.choices.isEmpty {
      if store.commandIsOpen || store.sheet != nil || store.libraryDrawerSection != nil
        || window.attachedSheet != nil || NSApp.modalWindow != nil
      {
        controller.cancel()
        return event
      }
      if event.type == .flagsChanged && !event.modifierFlags.contains(.control) {
        controller.commit(store: store)
        return event
      }
      if event.type == .keyDown && event.keyCode == 53 {
        controller.cancel()
        return nil
      }
    }
    guard event.type == .keyDown, event.keyCode == 48,
      event.modifierFlags.contains(.control),
      event.modifierFlags.intersection([.command, .option]).isEmpty,
      !store.commandIsOpen, store.sheet == nil, store.libraryDrawerSection == nil,
      window.attachedSheet == nil, NSApp.modalWindow == nil
    else { return event }
    controller.advance(store: store, reverse: event.modifierFlags.contains(.shift))
    return nil
  }
}
