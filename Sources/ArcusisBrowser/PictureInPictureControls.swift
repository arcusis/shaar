// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit

/// Shaar's controls for Chromium's video picture-in-picture window. Chromium draws the video
/// and keeps playing it; a transparent child panel above it adds close, minimize, back to
/// tab, skip back, play/pause and skip forward, and moves and resizes the video window.
/// The engine's own overlay offers neither skipping nor minimizing.
@MainActor
final class PictureInPictureControls {
  /// Commands that reach the page or the engine; minimize and restore stay here.
  enum Command: Equatable {
    case play, pause, close, backToTab
    case skip(TimeInterval)
  }

  static let skipInterval: TimeInterval = 10

  /// The tab whose video the controls drive.
  private(set) var tabID: UUID?
  private(set) weak var videoWindow: NSWindow?
  private(set) var panel: NSPanel?
  /// The video window's frame before it tucked away; nil while it is on screen.
  private(set) var untuckedFrame: CGRect?
  let view = PictureInPictureControlsView()
  var onCommand: ((UUID, Command) -> Void)?
  private var observers: [NSObjectProtocol] = []
  /// Waits for Chromium to show the window it reported.
  private var pendingAttachment: Task<Void, Never>?
  private var gesture: (frame: CGRect, edges: PictureInPictureGeometry.Edges)?

  init() {
    view.onControl = { [weak self] in self?.press($0) }
    view.onGesture = { [weak self] in self?.handle($0) }
  }

  var isAttached: Bool { panel != nil }

  /// Attaches to the tab's window once Chromium shows it; Chromium reports the window as it
  /// opens it.
  func attach(
    tabID: UUID, finding find: @escaping () -> NSWindow?,
    video: @escaping () -> PictureInPictureVideo?
  ) {
    detach()
    self.tabID = tabID
    pendingAttachment = Task { [weak self] in
      for _ in 0..<50 {
        if let window = find() {
          self?.attach(to: window, tabID: tabID, video: video())
          return
        }
        try? await Task.sleep(for: .milliseconds(100))
        if Task.isCancelled { return }
      }
    }
  }

  func attach(to window: NSWindow, tabID: UUID, video: PictureInPictureVideo?) {
    detach()
    self.tabID = tabID
    videoWindow = window
    let panel = makePanel(over: window)
    self.panel = panel
    update(video)
    window.addChildWindow(panel, ordered: .above)
    observe(window)
  }

  func detach(from tabID: UUID) {
    if self.tabID == tabID { detach() }
  }

  func detach() {
    pendingAttachment?.cancel()
    pendingAttachment = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    if let panel {
      videoWindow?.removeChildWindow(panel)
      panel.orderOut(nil)
    }
    panel = nil
    videoWindow = nil
    tabID = nil
    untuckedFrame = nil
    gesture = nil
    view.presentation = .init()
  }

  /// Applies the page's latest report. Until the page reports, skipping stays hidden.
  func update(_ video: PictureInPictureVideo?) {
    view.presentation.isPlaying = video?.isPlaying ?? true
    view.presentation.isLive = video?.isLive ?? true
  }

  func minimize() {
    guard let window = videoWindow, untuckedFrame == nil,
      let screen = (window.screen ?? NSScreen.main)?.visibleFrame
    else { return }
    untuckedFrame = window.frame
    view.presentation.tuckedLeft = PictureInPictureGeometry.tucksLeft(window.frame, in: screen)
    view.presentation.isTucked = true
    window.setFrame(PictureInPictureGeometry.tucked(window.frame, in: screen), display: true)
  }

  func restore() {
    guard let window = videoWindow, let frame = untuckedFrame else { return }
    untuckedFrame = nil
    view.presentation.isTucked = false
    window.setFrame(frame, display: true)
  }

  private func press(_ control: PictureInPictureControlsView.Control) {
    switch control {
    case .minimize: minimize()
    case .restore: restore()
    case .close: send(.close)
    case .backToTab: send(.backToTab)
    case .skipBack: send(.skip(-Self.skipInterval))
    case .skipForward: send(.skip(Self.skipInterval))
    case .playPause: send(view.presentation.isPlaying ? .pause : .play)
    }
  }

  /// Closing returns a tucked window to its place first, so Chromium remembers that place.
  private func send(_ command: Command) {
    guard let tabID else { return }
    if command == .close || command == .backToTab { restore() }
    onCommand?(tabID, command)
  }

  private func handle(_ event: PictureInPictureControlsView.Gesture) {
    guard let window = videoWindow else { return }
    switch event {
    case .began(let edges):
      gesture = (window.frame, edges)
    case .changed(let delta):
      guard let gesture else { return }
      window.setFrame(frame(for: gesture, moved: delta, in: window), display: true)
    case .ended:
      gesture = nil
    }
  }

  private func frame(
    for gesture: (frame: CGRect, edges: PictureInPictureGeometry.Edges), moved delta: CGSize,
    in window: NSWindow
  ) -> CGRect {
    guard !gesture.edges.isEmpty else {
      return gesture.frame.offsetBy(dx: delta.width, dy: delta.height)
    }
    return PictureInPictureGeometry.resized(
      gesture.frame, edges: gesture.edges, by: delta, minimum: window.minSize,
      maximum: window.maxSize)
  }

  private func makePanel(over window: NSWindow) -> NSPanel {
    let panel = NSPanel(
      contentRect: window.frame, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.level = window.level
    panel.collectionBehavior = window.collectionBehavior
    panel.contentView = view
    view.frame = NSRect(origin: .zero, size: window.frame.size)
    view.autoresizingMask = [.width, .height]
    matchVisibility(of: window, panel: panel)
    return panel
  }

  /// The engine keeps its window transparent and click-through in background test runs;
  /// the controls follow so nothing appears on screen.
  private func matchVisibility(of window: NSWindow, panel: NSPanel) {
    let hidden = window.alphaValue == 0
    panel.alphaValue = hidden ? 0 : 1
    panel.ignoresMouseEvents = hidden || window.ignoresMouseEvents
  }

  private func observe(_ window: NSWindow) {
    let center = NotificationCenter.default
    for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
      observers.append(
        center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.followVideoWindow() }
        })
    }
    observers.append(
      center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.detach() }
      })
  }

  private func followVideoWindow() {
    guard let window = videoWindow, let panel else { return }
    panel.setFrame(window.frame, display: true)
    matchVisibility(of: window, panel: panel)
  }
}
