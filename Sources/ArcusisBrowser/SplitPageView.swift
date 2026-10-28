import AppKit
import BrowserCore
import SwiftUI

/// Renders a split layout tree: each pane gets its own toolbar, groups get draggable dividers.
struct SplitPageView<Pane: View, Header: View>: View {
  let split: BrowserSplit
  let focusedID: UUID?
  let onFocus: (UUID) -> Void
  let onWeightsChange: ([Double], [Int]) -> Void
  @ViewBuilder let header: (UUID) -> Header
  @ViewBuilder let pane: (UUID) -> Pane

  var body: some View {
    node(split.root, path: [])
  }

  private func node(_ node: SplitNode, path: [Int]) -> AnyView {
    switch node {
    case .pane(let id):
      return AnyView(paneView(id))
    case .group(let axis, let children, let weights):
      return AnyView(
        SplitGroupView(
          axis: axis, weights: weights,
          onWeightsChange: { onWeightsChange($0, path) }
        ) { index in
          self.node(children[index], path: path + [index])
        })
    }
  }

  private func paneView(_ id: UUID) -> some View {
    VStack(spacing: 0) {
      header(id)
      Divider().opacity(0.4)
      pane(id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background { SplitPaneFocusObserver(onFocus: { onFocus(id) }) }
    .contentShape(Rectangle())
    .simultaneousGesture(TapGesture().onEnded { onFocus(id) })
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(id == focusedID ? Color.accentColor.opacity(0.85) : .clear, lineWidth: 2)
        .allowsHitTesting(false)
    }
  }
}

/// Children of one group laid out along its axis, separated by draggable dividers.
private struct SplitGroupView: View {
  static let dividerThickness: CGFloat = 6
  static let minimumPane: CGFloat = 160

  let axis: SplitAxis
  let weights: [Double]
  let onWeightsChange: ([Double]) -> Void
  let child: (Int) -> AnyView
  @State private var dragStart: [Double]?

  var body: some View {
    GeometryReader { geometry in
      let total = axis == .columns ? geometry.size.width : geometry.size.height
      let available = max(0, total - Self.dividerThickness * CGFloat(weights.count - 1))
      let layout =
        axis == .columns ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
      layout {
        ForEach(weights.indices, id: \.self) { index in
          if index > 0 { divider(after: index - 1, available: available) }
          child(index)
            .frame(
              width: axis == .columns ? available * weights[index] : nil,
              height: axis == .rows ? available * weights[index] : nil)
        }
      }
    }
  }

  private func divider(after index: Int, available: CGFloat) -> some View {
    Color.clear
      .frame(
        width: axis == .columns ? Self.dividerThickness : nil,
        height: axis == .rows ? Self.dividerThickness : nil)
      .contentShape(Rectangle())
      .pointerStyle(axis == .columns ? .columnResize : .rowResize)
      .gesture(
        DragGesture(minimumDistance: 1)
          .onChanged { value in
            let start = dragStart ?? weights
            if dragStart == nil { dragStart = start }
            let delta = axis == .columns ? value.translation.width : value.translation.height
            onWeightsChange(Self.resized(start, at: index, by: delta, available: available))
          }
          .onEnded { _ in dragStart = nil })
      .accessibilityLabel("Split divider")
  }

  /// Moves the divider after `index`, keeping both neighbours above the minimum size.
  static func resized(_ weights: [Double], at index: Int, by delta: CGFloat, available: CGFloat)
    -> [Double]
  {
    guard available > 0, weights.indices.contains(index + 1) else { return weights }
    let pair = weights[index] + weights[index + 1]
    let minimum = min(Double(minimumPane / available), pair / 2)
    let leading = min(max(weights[index] + Double(delta / available), minimum), pair - minimum)
    var next = weights
    next[index] = leading
    next[index + 1] = pair - leading
    return next
  }
}

struct BrowserSplitPageView: View {
  let store: BrowserStore
  let engine: BrowserEngine
  let split: BrowserSplit

  var body: some View {
    SplitPageView(
      split: split, focusedID: store.session.selectedSpace.selectedTabID,
      onFocus: { focus($0) },
      onWeightsChange: { store.setSplitWeights($0, at: $1, splitID: split.id) }
    ) { id in
      SplitPaneToolbar(store: store, engine: engine, tabID: id)
    } pane: { id in
      if let failure = store.rendererFailures[id] {
        FailedPageView(store: store, failure: failure)
      } else if engine.pages[id] != nil {
        ChromiumPage(engine: engine, tabID: id, autofocus: id == store.session.selectedSpace.selectedTabID)
      } else {
        ProgressView("Loading profile…")
      }
    }
    .padding(2)
  }

  private func focus(_ id: UUID) {
    guard store.session.selectedSpace.selectedTabID != id else { return }
    store.focusSplitTab(id)
  }
}

private struct SplitPaneFocusObserver: NSViewRepresentable {
  let onFocus: () -> Void

  func makeNSView(context: Context) -> SplitPaneFocusView {
    let view = SplitPaneFocusView()
    view.onFocus = onFocus
    return view
  }

  func updateNSView(_ view: SplitPaneFocusView, context: Context) {
    view.onFocus = onFocus
  }
}

private final class SplitPaneFocusView: NSView {
  var onFocus: (() -> Void)?
  private var monitor: Any?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    guard window != nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
      guard let self, event.window === self.window,
        self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
      self.onFocus?()
      return event
    }
  }

  isolated deinit {
    if let monitor { NSEvent.removeMonitor(monitor) }
  }
}
