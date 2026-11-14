// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI

struct ChromiumPage: NSViewRepresentable {
  let engine: BrowserEngine
  let tabID: UUID
  var autofocus = true

  func makeNSView(context: Context) -> ChromiumPageContainerView {
    ChromiumPageContainerView()
  }

  func updateNSView(_ container: ChromiumPageContainerView, context: Context) {
    if container.select(
      engine.runtime.view(forTabID: tabID.uuidString), tabID: tabID, liveTabs: engine.liveTabs),
      container.window?.isKeyWindow == true, autofocus
    {
      engine.focusPage(tabID)
    }
  }

  static func dismantleNSView(_ view: ChromiumPageContainerView, coordinator: ()) {
    view.dismantle()
  }
}

final class ChromiumPageContainerView: NSView {
  /// Containers on screen. During split animations an outgoing container can briefly hold a
  /// page that a newer container also shows; on teardown the page is handed back.
  private static let live = NSHashTable<ChromiumPageContainerView>.weakObjects()
  private static var nextSelectionOrder: UInt64 = 0

  static func restoreSelectedPage(_ page: NSView, tabID: UUID, in window: NSWindow) -> Bool {
    guard
      let target = live.allObjects
        .filter({ $0.shownTabID == tabID && $0.window === window })
        .max(by: { $0.selectionOrder < $1.selectionOrder })
    else { return false }
    _ = target.attach(page)
    page.isHidden = false
    return page.superview === target && page.window === window
  }

  static func latestLiveContainer(for tabID: UUID) -> ChromiumPageContainerView? {
    live.allObjects
      .filter { $0.shownTabID == tabID }
      .max { $0.selectionOrder < $1.selectionOrder }
  }

  private(set) weak var pageView: NSView?
  private var retainedPages: [UUID: NSView] = [:]
  private var shownTabID: UUID?
  private var selectionOrder: UInt64 = 0

  @discardableResult
  func select(_ page: NSView?, tabID: UUID, liveTabs: Set<UUID>) -> Bool {
    Self.live.add(self)
    shownTabID = page == nil ? nil : tabID
    Self.nextSelectionOrder &+= 1
    selectionOrder = Self.nextSelectionOrder
    wantsLayer = true
    layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    for id in retainedPages.keys.filter({ !liveTabs.contains($0) }) {
      if let view = retainedPages.removeValue(forKey: id), view.superview === self {
        view.removeFromSuperview()
      }
    }
    guard let page else {
      for view in retainedPages.values where view.superview === self {
        view.isHidden = true
      }
      pageView = nil
      return false
    }
    let changed = pageView !== page || page.superview !== self
    for view in retainedPages.values where view.superview === self {
      view.isHidden = view !== page
    }
    if let previous = retainedPages.updateValue(page, forKey: tabID), previous !== page,
      previous.superview === self
    {
      previous.removeFromSuperview()
    }
    pageView = page
    if page.superview !== self {
      page.removeFromSuperview()
      page.translatesAutoresizingMaskIntoConstraints = true
      page.frame = bounds
      page.autoresizingMask = [.width, .height]
      addSubview(page)
    }
    page.isHidden = false
    layoutSubtreeIfNeeded()
    return changed
  }

  func dismantle() {
    let owned = retainedPages.filter { $0.value.superview === self }
    Self.live.remove(self)
    shownTabID = nil
    attach(nil)
    for (tabID, page) in owned {
      Self.latestLiveContainer(for: tabID)?.attach(page)
    }
  }

  @discardableResult
  func attach(_ page: NSView?) -> Bool {
    if page == nil {
      for view in retainedPages.values where view.superview === self { view.removeFromSuperview() }
      retainedPages.removeAll()
    }
    page?.isHidden = false
    if pageView === page, page?.superview === self { return false }
    if let pageView, pageView !== page, pageView.superview === self {
      pageView.removeFromSuperview()
    }
    pageView = page
    if let page {
      if page.superview !== self {
        page.removeFromSuperview()
        page.translatesAutoresizingMaskIntoConstraints = true
        page.frame = bounds
        page.autoresizingMask = [.width, .height]
        addSubview(page)
      }
      layoutSubtreeIfNeeded()
    }
    return true
  }

  override func layout() {
    super.layout()
    guard let pageView, pageView.superview === self else { return }
    // The Shaar layer sizes the inspected page beside its borrowed DevTools
    // frontend. Resetting that page to full width covers the dock's hit area.
    guard !subviews.contains(where: { $0 !== pageView && !$0.isHidden }) else { return }
    if pageView.frame != bounds { pageView.frame = bounds }
  }
}
