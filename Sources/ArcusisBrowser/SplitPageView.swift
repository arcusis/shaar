// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
/// A drag resizes from local state and commits once on release, so the session is not
/// rewritten on every frame.
struct SplitGroupView: View {
  static let dividerThickness: CGFloat = 8
  static let minimumPane: CGFloat = 160

  static func dividerHighlightAnimation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.12)
  }

  let axis: SplitAxis
  let weights: [Double]
  let onWeightsChange: ([Double]) -> Void
  let child: (Int) -> AnyView
  @State private var liveWeights: [Double]?
  @State private var activeDivider: Int?
  @State private var hoveredDivider: Int?
  @Environment(\.layoutDirection) private var layoutDirection
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let shown = Self.displayedWeights(liveWeights, matching: weights)
    GeometryReader { geometry in
      let total = axis == .columns ? geometry.size.width : geometry.size.height
      let available = max(0, total - Self.dividerThickness * CGFloat(shown.count - 1))
      let layout =
        axis == .columns ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
      layout {
        ForEach(shown.indices, id: \.self) { index in
          if index > 0 { divider(after: index - 1, available: available) }
          child(index)
            .frame(
              width: axis == .columns ? available * shown[index] : nil,
              height: axis == .rows ? available * shown[index] : nil)
        }
      }
      .transaction { if liveWeights != nil { $0.animation = nil } }
    }
  }

  private func divider(after index: Int, available: CGFloat) -> some View {
    let highlighted = activeDivider == index || hoveredDivider == index
    let pair = weights[index] + weights[index + 1]
    let leadingPercent = pair > 0 ? weights[index] / pair : 0.5
    return ZStack {
      Capsule()
        .fill(Color.primary.opacity(highlighted ? 0.35 : 0))
        .frame(
          width: axis == .columns ? 3 : 36,
          height: axis == .rows ? 3 : 36)
    }
    .frame(
      width: axis == .columns ? Self.dividerThickness : nil,
      height: axis == .rows ? Self.dividerThickness : nil
    )
    .frame(maxWidth: axis == .rows ? .infinity : nil, maxHeight: axis == .columns ? .infinity : nil)
    .contentShape(Rectangle())
    .pointerStyle(axis == .columns ? .columnResize : .rowResize)
    .onHover { inside in
      hoveredDivider = hoveredDivider.updatingTarget(index, isActive: inside)
    }
    .gesture(
      DragGesture(minimumDistance: 0, coordinateSpace: .global)
        .onChanged { value in
          activeDivider = index
          let physicalDelta = axis == .columns ? value.translation.width : value.translation.height
          let delta = SplitResizeDecision.logicalDelta(
            physicalDelta, isHorizontal: axis == .columns,
            isRightToLeft: layoutDirection == .rightToLeft)
          liveWeights = Self.resized(weights, at: index, by: delta, available: available)
        }
        .onEnded { _ in
          if let liveWeights { onWeightsChange(liveWeights) }
          liveWeights = nil
          activeDivider = nil
        }
    )
    .animation(Self.dividerHighlightAnimation(reduceMotion: reduceMotion), value: highlighted)
    .accessibilityLabel(
      SplitDividerAccessibility.label(
        axis: axis, index: index, dividerCount: weights.count - 1,
        language: .currentLaunchLanguage)
    )
    .accessibilityValue("\(Int((leadingPercent * 100).rounded()))%")
    .accessibilityAdjustableAction(
      SplitDividerInput.accessibilityAction(step: Self.keyboardStep) {
        adjustDivider(index, by: $0, available: available)
      }
    )
    .focusable()
    .onKeyPress(
      .leftArrow,
      action: SplitDividerInput.keyboardAction(
        for: .left, axis: axis, isRightToLeft: layoutDirection == .rightToLeft,
        step: Self.keyboardStep
      ) { adjustDivider(index, by: $0, available: available) }
    )
    .onKeyPress(
      .rightArrow,
      action: SplitDividerInput.keyboardAction(
        for: .right, axis: axis, isRightToLeft: layoutDirection == .rightToLeft,
        step: Self.keyboardStep
      ) { adjustDivider(index, by: $0, available: available) }
    )
    .onKeyPress(
      .upArrow,
      action: SplitDividerInput.keyboardAction(
        for: .up, axis: axis, isRightToLeft: layoutDirection == .rightToLeft,
        step: Self.keyboardStep
      ) { adjustDivider(index, by: $0, available: available) }
    )
    .onKeyPress(
      .downArrow,
      action: SplitDividerInput.keyboardAction(
        for: .down, axis: axis, isRightToLeft: layoutDirection == .rightToLeft,
        step: Self.keyboardStep
      ) { adjustDivider(index, by: $0, available: available) })
  }

  private static let keyboardStep: CGFloat = 32

  static func displayedWeights(_ liveWeights: [Double]?, matching weights: [Double]) -> [Double] {
    guard let liveWeights, liveWeights.count == weights.count else { return weights }
    return liveWeights
  }

  private func adjustDivider(_ index: Int, by delta: CGFloat, available: CGFloat) {
    let next = Self.resized(weights, at: index, by: delta, available: available)
    guard next != weights else { return }
    onWeightsChange(next)
  }

  /// Moves the divider after `index`, keeping both neighbours above the minimum size.
  static func resized(_ weights: [Double], at index: Int, by delta: CGFloat, available: CGFloat)
    -> [Double]
  {
    guard available > 0, weights.count >= 2, (0..<(weights.count - 1)).contains(index) else {
      return weights
    }
    let pair = weights[index] + weights[index + 1]
    let minimum = min(Double(minimumPane / available), pair / 2)
    let leading = min(max(weights[index] + Double(delta / available), minimum), pair - minimum)
    var next = weights
    next[index] = leading
    next[index + 1] = pair - leading
    return next
  }
}

enum SplitDividerAccessibility {
  static func label(
    axis: SplitAxis, index: Int, dividerCount: Int, language: BrowserLanguage
  ) -> String {
    let key =
      axis == .columns
      ? "Vertical split divider %d of %d" : "Horizontal split divider %d of %d"
    return BrowserLocalization.format(
      key, table: "Shell", language: language,
      arguments: [.integer(index + 1), .integer(dividerCount)])
  }
}

enum SplitDividerInput {
  enum Key {
    case left, right, up, down
  }

  static func keyboardDelta(
    for key: Key, axis: SplitAxis, isRightToLeft: Bool, step: CGFloat
  ) -> CGFloat? {
    switch (key, axis) {
    case (.left, .columns):
      SplitResizeDecision.logicalDelta(-step, isHorizontal: true, isRightToLeft: isRightToLeft)
    case (.right, .columns):
      SplitResizeDecision.logicalDelta(step, isHorizontal: true, isRightToLeft: isRightToLeft)
    case (.up, .rows): -step
    case (.down, .rows): step
    default: nil
    }
  }

  static func keyboardAction(
    for key: Key, axis: SplitAxis, isRightToLeft: Bool, step: CGFloat,
    resize: @escaping (CGFloat) -> Void
  ) -> () -> KeyPress.Result {
    {
      guard
        let delta = keyboardDelta(
          for: key, axis: axis, isRightToLeft: isRightToLeft, step: step)
      else { return .ignored }
      resize(delta)
      return .handled
    }
  }

  static func accessibilityDelta(
    for direction: AccessibilityAdjustmentDirection, step: CGFloat
  ) -> CGFloat? {
    switch direction {
    case .increment: step
    case .decrement: -step
    @unknown default: nil
    }
  }

  static func accessibilityAction(
    step: CGFloat, resize: @escaping (CGFloat) -> Void
  ) -> (AccessibilityAdjustmentDirection) -> Void {
    { direction in
      guard let delta = accessibilityDelta(for: direction, step: step) else { return }
      resize(delta)
    }
  }
}

enum SplitResizeDecision {
  static func logicalDelta(
    _ physicalDelta: CGFloat, isHorizontal: Bool, isRightToLeft: Bool
  ) -> CGFloat {
    isHorizontal && isRightToLeft ? -physicalDelta : physicalDelta
  }
}

struct BrowserSplitPageView: View {
  let store: BrowserStore
  let engine: BrowserEngine
  let split: BrowserSplit
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    SplitPageView(
      split: split, focusedID: store.session.selectedSpace.selectedTabID,
      onFocus: { focus($0) },
      onWeightsChange: { store.setSplitWeights($0, at: $1, splitID: split.id) }
    ) { id in
      SplitPaneToolbar(store: store, tabID: id, engine: engine)
    } pane: { id in
      if let failure = store.rendererFailures[id] {
        FailedPageView(store: store, failure: failure)
      } else if engine.pages[id] != nil {
        InspectorPage(
          engine: engine, tabID: id, autofocus: id == store.session.selectedSpace.selectedTabID
        )
        .overlay { SplitDropZone(store: store, targetID: id) }
      } else {
        ProgressView(ShellL10n.string("Loading profile…"))
      }
    }
    .padding(2)
    .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: split.root)
  }

  private func focus(_ id: UUID) {
    guard store.session.selectedSpace.selectedTabID != id else { return }
    store.focusSplitTab(id)
  }
}

struct PrivateSplitPageView: View {
  let store: BrowserStore
  let session: PrivatePageSession
  let split: BrowserSplit

  var body: some View {
    SplitPageView(
      split: split, focusedID: store.session.selectedSpace.selectedTabID,
      onFocus: { store.focusSplitTab($0) },
      onWeightsChange: { store.setSplitWeights($0, at: $1, splitID: split.id) }
    ) { id in
      SplitPaneToolbar(store: store, tabID: id, engine: nil)
    } pane: { id in
      PrivateInspectorPage(session: session, tabID: id, inSplit: true)
        .overlay { SplitDropZone(store: store, targetID: id) }
    }
    .padding(2)
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
    if let monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
    guard window != nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
      guard let self, event.window === self.window,
        self.bounds.contains(self.convert(event.locationInWindow, from: nil))
      else { return event }
      self.onFocus?()
      return event
    }
  }

  isolated deinit {
    if let monitor { NSEvent.removeMonitor(monitor) }
  }
}
