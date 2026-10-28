import AppKit
import BrowserCore
import SwiftUI

/// While a tab is dragged, covers a page with drop zones: the nearest edge decides where the
/// tab joins the split, and a tinted half previews it.
struct SplitDropZone: View {
  let store: BrowserStore
  let targetID: UUID
  @State private var edge: SplitEdge?

  var body: some View {
    if store.tabDrag != nil, store.canDropTab(beside: targetID) {
      GeometryReader { geometry in
        ZStack(alignment: alignment) {
          SplitDropCatcher(
            onHover: { point in edge = point.map { Self.edge(at: $0, in: geometry.size) } },
            onDrop: { point in
              store.dropTab(beside: targetID, edge: Self.edge(at: point, in: geometry.size))
            })
          if let edge {
            preview(edge, in: geometry.size)
          }
        }
      }
      .animation(.smooth(duration: 0.16), value: edge)
    }
  }

  private var alignment: Alignment {
    switch edge {
    case .left: .leading
    case .right: .trailing
    case .top: .top
    case .bottom, nil: .bottom
    }
  }

  private func preview(_ edge: SplitEdge, in size: CGSize) -> some View {
    let horizontal = edge == .left || edge == .right
    return RoundedRectangle(cornerRadius: 10)
      .fill(Color.accentColor.opacity(0.18))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2))
      .frame(
        width: horizontal ? size.width / 2 : size.width,
        height: horizontal ? size.height : size.height / 2)
      .padding(6)
      .allowsHitTesting(false)
      .transition(.opacity)
  }

  /// The edge closest to the pointer.
  static func edge(at point: CGPoint, in size: CGSize) -> SplitEdge {
    guard size.width > 0, size.height > 0 else { return .right }
    let distances: [(SplitEdge, CGFloat)] = [
      (.left, point.x / size.width), (.right, 1 - point.x / size.width),
      (.top, point.y / size.height), (.bottom, 1 - point.y / size.height),
    ]
    return distances.min { $0.1 < $1.1 }?.0 ?? .right
  }
}

/// AppKit drop target, so it sits above the Chromium view that would otherwise take the drag.
private struct SplitDropCatcher: NSViewRepresentable {
  let onHover: (CGPoint?) -> Void
  let onDrop: (CGPoint) -> Bool

  func makeNSView(context: Context) -> SplitDropCatcherView {
    let view = SplitDropCatcherView()
    view.registerForDraggedTypes([SplitDropCatcherView.sidebarItemType])
    update(view)
    return view
  }

  func updateNSView(_ view: SplitDropCatcherView, context: Context) {
    update(view)
  }

  private func update(_ view: SplitDropCatcherView) {
    view.onHover = onHover
    view.onDrop = onDrop
  }
}

private final class SplitDropCatcherView: NSView {
  static let sidebarItemType = NSPasteboard.PasteboardType("com.arcusis.browser.sidebar-item")

  var onHover: ((CGPoint?) -> Void)?
  var onDrop: ((CGPoint) -> Bool)?

  override var isFlipped: Bool { true }

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    draggingUpdated(sender)
  }

  override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
    onHover?(convert(sender.draggingLocation, from: nil))
    return .move
  }

  override func draggingExited(_ sender: (any NSDraggingInfo)?) {
    onHover?(nil)
  }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    let point = convert(sender.draggingLocation, from: nil)
    onHover?(nil)
    return onDrop?(point) ?? false
  }
}
