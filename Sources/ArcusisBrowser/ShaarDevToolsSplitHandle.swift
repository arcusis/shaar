// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI

enum ShaarDevToolsSplitDrag {
  /// Window y grows upward. The bottom handle treats a downward drag as positive, matching the
  /// previous SwiftUI gesture.
  static func translation(vertical: Bool, delta: CGFloat) -> CGFloat {
    if vertical { return -delta }
    return delta
  }

  static func proposed(
    start: CGFloat, translation: CGFloat, edge: ShaarDevToolsDock, available: CGFloat
  ) -> CGFloat {
    switch edge {
    case .bottom:
      ShaarDevToolsSizing.bottom(start - translation, available: available)
    case .right:
      ShaarDevToolsSizing.side(start - translation, available: available)
    case .left:
      ShaarDevToolsSizing.side(start + translation, available: available)
    case .floating:
      start
    }
  }
}

struct ShaarDevToolsSplitHandle: NSViewRepresentable {
  var vertical: Bool
  var began: () -> CGFloat
  var changed: (CGFloat, CGFloat) -> Void

  func makeNSView(context: Context) -> ShaarDevToolsSplitHandleView {
    let view = ShaarDevToolsSplitHandleView()
    view.setAccessibilityIdentifier("shaar.devtools.resize")
    update(view)
    return view
  }

  func updateNSView(_ view: ShaarDevToolsSplitHandleView, context: Context) {
    update(view)
  }

  private func update(_ view: ShaarDevToolsSplitHandleView) {
    view.vertical = vertical
    view.began = began
    view.changed = changed
  }
}

final class ShaarDevToolsSplitHandleView: NSView {
  var vertical = false
  var began: (() -> CGFloat)?
  var changed: ((CGFloat, CGFloat) -> Void)?
  private var origin: CGFloat = 0
  private var startLength: CGFloat?

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func resetCursorRects() {
    let cursor: NSCursor = vertical ? .resizeUpDown : .resizeLeftRight
    addCursorRect(bounds, cursor: cursor)
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.labelColor.withAlphaComponent(0.12).setFill()
    dirtyRect.intersection(bounds).fill()
  }

  override func mouseDown(with event: NSEvent) {
    origin = vertical ? event.locationInWindow.y : event.locationInWindow.x
    startLength = began?()
  }

  override func mouseDragged(with event: NSEvent) {
    guard let startLength else { return }
    let point = vertical ? event.locationInWindow.y : event.locationInWindow.x
    let translation = ShaarDevToolsSplitDrag.translation(vertical: vertical, delta: point - origin)
    changed?(startLength, translation)
  }

  override func mouseUp(with event: NSEvent) {
    startLength = nil
  }
}
