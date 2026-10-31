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

  private(set) weak var pageView: NSView?
  private var retainedPages: [UUID: NSView] = [:]
  private var shownTabID: UUID?

  @discardableResult
  func select(_ page: NSView?, tabID: UUID, liveTabs: Set<UUID>) -> Bool {
    Self.live.add(self)
    shownTabID = page == nil ? nil : tabID
    wantsLayer = true
    layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    for id in retainedPages.keys.filter({ !liveTabs.contains($0) }) {
      if let view = retainedPages.removeValue(forKey: id), view.superview === self {
        view.removeFromSuperview()
      }
    }
    guard let page else { return attach(nil) }
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
      Self.live.allObjects.first { $0.shownTabID == tabID }?.attach(page)
    }
  }

  @discardableResult
  func attach(_ page: NSView?) -> Bool {
    if page == nil {
      for view in retainedPages.values where view.superview === self { view.removeFromSuperview() }
      retainedPages.removeAll()
    }
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
    if let pageView, pageView.superview === self, pageView.frame != bounds {
      pageView.frame = bounds
    }
  }
}
