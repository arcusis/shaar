// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit

/// Shaar's controls over Chromium's picture-in-picture video. The view fills the video
/// window: buttons fade in while the pointer is over it, the interior moves the window and
/// the border resizes it. A tucked window shows only a restore strip.
@MainActor
final class PictureInPictureControlsView: NSView {
  enum Control: String, CaseIterable {
    case backToTab = "back-to-tab"
    case minimize, close
    case skipBack = "skip-back"
    case playPause = "play-pause"
    case skipForward = "skip-forward"
    case restore
  }

  enum Gesture {
    case began(PictureInPictureGeometry.Edges)
    /// Pointer travel since the gesture began, in screen points.
    case changed(CGSize)
    case ended
  }

  struct Presentation: Equatable {
    var isPlaying = true
    var isLive = false
    var isTucked = false
    var tuckedLeft = false
  }

  var onControl: ((Control) -> Void)?
  var onGesture: ((Gesture) -> Void)?
  var presentation = Presentation() {
    didSet { if presentation != oldValue { applyPresentation() } }
  }
  /// Whether the buttons show, as they do while the pointer is over the window.
  private(set) var controlsShown = false

  private var buttons: [Control: NSButton] = [:]
  private let controls = FilledView(fill: NSColor.black.withAlphaComponent(0.35))
  private var gestureStart: CGPoint?

  override init(frame: NSRect) {
    super.init(frame: frame)
    controls.alphaValue = 0
    addSubview(controls)
    for control in Control.allCases {
      let button = makeButton(control)
      buttons[control] = button
      (control == .restore ? self : controls).addSubview(button)
    }
    applyPresentation()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// The button for a control, for verification.
  func button(_ control: Control) -> NSButton? { buttons[control] }

  /// Controls a person can use in the current presentation.
  var availableControls: Set<Control> {
    Set(Control.allCases.filter { buttons[$0]?.isHiddenOrHasHiddenAncestor == false })
  }

  func setControlsShown(_ shown: Bool, animated: Bool = true) {
    guard controlsShown != shown, !presentation.isTucked || !shown else { return }
    controlsShown = shown
    let alpha: CGFloat = shown ? 1 : 0
    guard animated else {
      controls.alphaValue = alpha
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.15
      controls.animator().alphaValue = alpha
    }
  }

  override func layout() {
    super.layout()
    controls.frame = bounds
    layoutCorner(.backToTab, x: 8)
    layoutCorner(.close, x: bounds.width - 8 - 28)
    layoutCorner(.minimize, x: bounds.width - 8 - 28 - 4 - 28)
    layoutCenter()
    buttons[.restore]?.frame = restoreFrame
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
        owner: self))
  }

  override func mouseEntered(with event: NSEvent) { setControlsShown(true) }
  override func mouseExited(with event: NSEvent) {
    setControlsShown(false)
    NSCursor.arrow.set()
  }

  override func mouseMoved(with event: NSEvent) {
    setControlsShown(true)
    cursor(for: edges(of: event)).set()
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    if presentation.isTucked {
      onControl?(.restore)
      return
    }
    gestureStart = screenLocation(of: event)
    onGesture?(.began(edges(of: event)))
  }

  override func mouseDragged(with event: NSEvent) {
    guard let start = gestureStart else { return }
    let location = screenLocation(of: event)
    onGesture?(.changed(CGSize(width: location.x - start.x, height: location.y - start.y)))
  }

  override func mouseUp(with event: NSEvent) {
    guard gestureStart != nil else { return }
    gestureStart = nil
    onGesture?(.ended)
  }

  private func applyPresentation() {
    let tucked = presentation.isTucked
    if tucked { setControlsShown(false, animated: false) }
    controls.isHidden = tucked
    buttons[.restore]?.isHidden = !tucked
    buttons[.skipBack]?.isHidden = presentation.isLive
    buttons[.skipForward]?.isHidden = presentation.isLive
    let restore = presentation.tuckedLeft ? "chevron.right" : "chevron.left"
    setSymbol(.restore, restore, label: PanelsL10n.string("Restore Picture in Picture"))
    let playing = presentation.isPlaying
    setSymbol(
      .playPause, playing ? "pause.fill" : "play.fill",
      label: PanelsL10n.string(playing ? "Pause" : "Play"))
    needsLayout = true
  }

  private func layoutCorner(_ control: Control, x: CGFloat) {
    buttons[control]?.frame = NSRect(x: x, y: bounds.height - 8 - 28, width: 28, height: 28)
  }

  /// Skip back, play/pause and skip forward, centered; play/pause alone for live video.
  private func layoutCenter() {
    let size: CGFloat = 44
    let gap: CGFloat = 16
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    buttons[.playPause]?.frame = NSRect(
      x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
    buttons[.skipBack]?.frame = NSRect(
      x: center.x - size / 2 - gap - size, y: center.y - size / 2, width: size, height: size)
    buttons[.skipForward]?.frame = NSRect(
      x: center.x + size / 2 + gap, y: center.y - size / 2, width: size, height: size)
  }

  /// The strip left on screen by a tucked window.
  private var restoreFrame: NSRect {
    let width = PictureInPictureGeometry.tuckedWidth
    let x = presentation.tuckedLeft ? bounds.width - width : 0
    return NSRect(x: x, y: 0, width: width, height: bounds.height)
  }

  private func makeButton(_ control: Control) -> NSButton {
    let button = ControlButton(fill: fill(control), cornerRadius: isCorner(control) ? 6 : 0)
    button.target = self
    button.action = #selector(pressed(_:))
    button.title = ""
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.contentTintColor = .white
    button.identifier = NSUserInterfaceItemIdentifier("pip-\(control.rawValue)")
    let (symbol, label) = Self.symbol(for: control)
    setSymbol(button, symbol, label: label, pointSize: pointSize(control))
    return button
  }

  private func isCorner(_ control: Control) -> Bool {
    [.backToTab, .minimize, .close].contains(control)
  }

  private func fill(_ control: Control) -> NSColor? {
    if control == .restore { return NSColor.black.withAlphaComponent(0.55) }
    return isCorner(control) ? NSColor.white.withAlphaComponent(0.16) : nil
  }

  private func pointSize(_ control: Control) -> CGFloat {
    isCorner(control) || control == .restore ? 13 : 24
  }

  private static func symbol(for control: Control) -> (String, String) {
    switch control {
    case .backToTab: ("pip.exit", PanelsL10n.string("Back to Tab"))
    case .minimize: ("minus", PanelsL10n.string("Minimize"))
    case .close: ("xmark", PanelsL10n.string("Close"))
    case .skipBack: ("gobackward.10", PanelsL10n.string("Skip Back 10 Seconds"))
    case .playPause: ("pause.fill", PanelsL10n.string("Pause"))
    case .skipForward: ("goforward.10", PanelsL10n.string("Skip Forward 10 Seconds"))
    case .restore: ("chevron.left", PanelsL10n.string("Restore Picture in Picture"))
    }
  }

  private func setSymbol(_ control: Control, _ symbol: String, label: String) {
    guard let button = buttons[control] else { return }
    setSymbol(button, symbol, label: label, pointSize: pointSize(control))
  }

  private func setSymbol(_ button: NSButton, _ symbol: String, label: String, pointSize: CGFloat) {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
      .withSymbolConfiguration(configuration)
    button.toolTip = label
    button.setAccessibilityLabel(label)
  }

  @objc private func pressed(_ sender: NSButton) {
    guard let control = buttons.first(where: { $0.value === sender })?.key else { return }
    onControl?(control)
  }

  private func edges(of event: NSEvent) -> PictureInPictureGeometry.Edges {
    PictureInPictureGeometry.edges(
      at: convert(event.locationInWindow, from: nil), in: bounds.size)
  }

  private func screenLocation(of event: NSEvent) -> CGPoint {
    window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
  }

  private func cursor(for edges: PictureInPictureGeometry.Edges) -> NSCursor {
    guard let position = Self.framePosition(edges) else { return .arrow }
    return .frameResize(position: position, directions: .all)
  }

  private static func framePosition(_ edges: PictureInPictureGeometry.Edges)
    -> NSCursor.FrameResizePosition?
  {
    switch edges {
    case [.top, .left]: .topLeft
    case [.top, .right]: .topRight
    case [.bottom, .left]: .bottomLeft
    case [.bottom, .right]: .bottomRight
    case .top: .top
    case .bottom: .bottom
    case .left: .left
    case .right: .right
    default: nil
    }
  }
}

/// A view that fills its bounds with one color.
private final class FilledView: NSView {
  private let fill: NSColor

  init(fill: NSColor) {
    self.fill = fill
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func draw(_ dirtyRect: NSRect) {
    fill.setFill()
    bounds.fill()
  }
}

/// A borderless symbol button over an optional rounded fill.
private final class ControlButton: NSButton {
  private let fill: NSColor?
  private let cornerRadius: CGFloat

  init(fill: NSColor?, cornerRadius: CGFloat) {
    self.fill = fill
    self.cornerRadius = cornerRadius
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func draw(_ dirtyRect: NSRect) {
    if let fill {
      fill.setFill()
      NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }
    super.draw(dirtyRect)
  }
}
