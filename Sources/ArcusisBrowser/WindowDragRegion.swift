// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI

struct WindowDragRegion: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    WindowDragView()
  }

  func updateNSView(_ view: NSView, context: Context) {}

  static func titlebarDragFrame(
    contentBounds: NSRect, contentLayoutRect: NSRect, trafficLightsFrame: NSRect?,
    isFlipped: Bool = false, isRightToLeft: Bool = false,
    trailingAccessoryWidth: CGFloat = 0
  ) -> NSRect? {
    let top: CGFloat
    if isFlipped {
      top = contentLayoutRect.minY - contentBounds.minY
    } else {
      top = contentBounds.maxY - contentLayoutRect.maxY
    }
    guard top > 0 else { return nil }
    guard let trafficLightsFrame else { return nil }
    let originY = isFlipped ? contentBounds.minY : contentLayoutRect.maxY
    let startX: CGFloat
    let endX: CGFloat
    if isRightToLeft {
      startX = max(contentBounds.minX, trafficLightsFrame.maxX + 8)
      endX = min(contentBounds.maxX, contentBounds.maxX - trailingAccessoryWidth)
    } else {
      startX = max(
        contentBounds.minX,
        trafficLightsFrame.maxX + 8 + BrowserChromeLayout.titlebarAccessoryWidth)
      endX = contentBounds.maxX
    }
    guard startX < endX else { return nil }
    return NSRect(x: startX, y: originY, width: endX - startX, height: top)
  }

  static func makeTitlebarDragView(
    window: NSWindow, contentView: NSView, isRightToLeft: Bool = false,
    trailingAccessoryWidth: CGFloat = 0
  ) -> NSView {
    let view = WindowDragView()
    view.autoresizingMask = [.width, .minYMargin]
    updateTitlebarDragView(
      view, window: window, contentView: contentView, isRightToLeft: isRightToLeft,
      trailingAccessoryWidth: trailingAccessoryWidth)
    return view
  }

  static func updateTitlebarDragView(
    _ view: NSView, window: NSWindow, contentView: NSView, isRightToLeft: Bool = false,
    trailingAccessoryWidth: CGFloat = 0
  ) {
    let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
      .compactMap { window.standardWindowButton($0) }
    guard buttons.count == 3 else {
      view.frame = .zero
      view.isHidden = true
      return
    }
    let trafficLights = buttons.compactMap { button -> NSRect? in
      guard let superview = button.superview else { return nil }
      return superview.convert(button.frame, to: contentView)
    }
    let trafficLightsFrame = trafficLights.reduce(nil as NSRect?) { current, frame in
      guard let current else { return frame }
      return current.union(frame)
    }
    let layoutRect = contentView.convert(window.contentLayoutRect, from: nil)
    if let frame = titlebarDragFrame(
      contentBounds: contentView.bounds, contentLayoutRect: layoutRect,
      trafficLightsFrame: trafficLightsFrame, isFlipped: contentView.isFlipped,
      isRightToLeft: isRightToLeft, trailingAccessoryWidth: trailingAccessoryWidth)
    {
      view.frame = frame
      view.isHidden = false
    } else {
      view.frame = .zero
      view.isHidden = true
    }
  }
}

private final class WindowDragView: NSView {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    window?.performDrag(with: event)
  }
}
