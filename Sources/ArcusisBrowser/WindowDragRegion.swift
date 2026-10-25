import AppKit
import SwiftUI

struct WindowDragRegion: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    WindowDragView()
  }

  func updateNSView(_ view: NSView, context: Context) {}
}

private final class WindowDragView: NSView {
  override func mouseDown(with event: NSEvent) {
    window?.performDrag(with: event)
  }
}
