// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI

enum SavePromptCopy {
  static func title(for request: SavePromptRequest) -> String {
    switch request.kind {
    case .password:
      if request.update { return PanelsL10n.string("Update saved password?") }
      return PanelsL10n.string("Save password?")
    case .card:
      return PanelsL10n.string("Save card?")
    case .address:
      return PanelsL10n.string("Save address?")
    }
  }
}

@MainActor
enum SavePromptPlacement {
  static let offscreen = NSPoint(x: -32000, y: -32000)

  static func browserIsOnScreen(_ window: NSWindow?) -> Bool {
    guard let window, window.isVisible else { return false }
    return NSScreen.screens.contains { $0.frame.intersects(window.frame) }
  }

  static func clampedOrigin(
    _ origin: NSPoint, panelSize: NSSize, visibleFrame: NSRect
  ) -> NSPoint {
    let maxX = max(visibleFrame.minX, visibleFrame.maxX - panelSize.width)
    let maxY = max(visibleFrame.minY, visibleFrame.maxY - panelSize.height)
    return NSPoint(
      x: min(max(origin.x, visibleFrame.minX), maxX),
      y: min(max(origin.y, visibleFrame.minY), maxY))
  }

  static func place(_ panel: NSPanel, relativeTo window: NSWindow?) {
    guard browserIsOnScreen(window), let window, let content = window.contentView else {
      panel.setFrameOrigin(offscreen)
      return
    }
    guard
      let screen = window.screen
        ?? NSScreen.screens.first(where: { $0.frame.intersects(window.frame) })
    else {
      panel.setFrameOrigin(offscreen)
      return
    }
    let page = content.convert(content.bounds, to: nil)
    let screenFrame = window.convertToScreen(page)
    let size = panel.frame.size
    let origin = NSPoint(
      x: screenFrame.maxX - size.width - 16, y: screenFrame.maxY - size.height - 72)
    panel.setFrameOrigin(clampedOrigin(origin, panelSize: size, visibleFrame: screen.visibleFrame))
  }
}

@MainActor
enum SavePromptButtons {
  static func textFields(_ view: NSView?) -> [NSTextField] {
    guard let view else { return [] }
    let own = (view as? NSTextField).map { [$0] } ?? []
    return own + view.subviews.flatMap(textFields)
  }

  static func find(_ view: NSView?, identifier: String) -> NSButton? {
    guard let view else { return nil }
    if let button = view as? NSButton, button.identifier?.rawValue == identifier { return button }
    for child in view.subviews {
      if let match = find(child, identifier: identifier) { return match }
    }
    return nil
  }
}

/// One non-activating bubble for Chromium's password, card, and address save offers.
/// The class name is the surface the platform parity probe records.
final class ShaarSavePromptPanel: NSPanel {
  static let saveIdentifier = "shaar.save-prompt.save"
  static let dismissIdentifier = "shaar.save-prompt.dismiss"
  static let neverIdentifier = "shaar.save-prompt.never"

  private(set) var shownRequestID = ""
  private var onDecision: ((SavePromptRequest.Decision) -> Void)?

  init() {
    super.init(
      contentRect: NSRect(x: -32000, y: -32000, width: 360, height: 196),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    isFloatingPanel = true
    becomesKeyOnlyIfNeeded = true
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    isMovable = false
    hasShadow = true
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
    backgroundColor = .windowBackgroundColor
    isOpaque = true
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  func show(
    _ request: SavePromptRequest, onDecision: @escaping (SavePromptRequest.Decision) -> Void
  ) {
    self.onDecision = onDecision
    shownRequestID = request.id
    contentView = SavePromptContent.make(request, target: self)
    setContentSize(NSSize(width: 360, height: 196))
  }

  @objc func savePromptSave(_ sender: Any?) { finish(.save) }
  @objc func savePromptDismiss(_ sender: Any?) { finish(.dismiss) }
  @objc func savePromptNever(_ sender: Any?) { finish(.never) }

  private func finish(_ decision: SavePromptRequest.Decision) {
    let callback = onDecision
    onDecision = nil
    callback?(decision)
  }
}

@MainActor
/// Fills the bubble so an offscreen capture includes the window background.
final class SavePromptSurface: NSView {
  override var isOpaque: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    dirtyRect.fill()
  }
}

@MainActor
enum SavePromptContent {
  static func make(_ request: SavePromptRequest, target: AnyObject) -> NSView {
    let root = SavePromptSurface(frame: NSRect(x: 0, y: 0, width: 360, height: 196))
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.addArrangedSubview(label(SavePromptCopy.title(for: request), size: 17, weight: .semibold))
    if !request.detail.isEmpty {
      stack.addArrangedSubview(
        label(request.detail, size: 13, weight: .regular, color: .secondaryLabelColor))
    }
    stack.addArrangedSubview(
      label(
        request.origin.absoluteString,
        size: 13, weight: .medium))
    stack.addArrangedSubview(buttonRow(request, target: target))
    root.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
    ])
    return root
  }

  private static func label(
    _ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor = .labelColor
  ) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.maximumNumberOfLines = 3
    field.baseWritingDirection = .leftToRight
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
  }

  private static func buttonRow(_ request: SavePromptRequest, target: AnyObject) -> NSView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.spacing = 8
    row.translatesAutoresizingMaskIntoConstraints = false
    let dismiss = button(
      PanelsL10n.string("Not now"), identifier: ShaarSavePromptPanel.dismissIdentifier,
      action: #selector(ShaarSavePromptPanel.savePromptDismiss(_:)), target: target)
    row.addArrangedSubview(dismiss)
    if request.allowsNever {
      row.addArrangedSubview(
        button(
          PanelsL10n.string("Never for this site"),
          identifier: ShaarSavePromptPanel.neverIdentifier,
          action: #selector(ShaarSavePromptPanel.savePromptNever(_:)), target: target))
    }
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    row.addArrangedSubview(spacer)
    row.addArrangedSubview(
      button(
        PanelsL10n.string("Save"), identifier: ShaarSavePromptPanel.saveIdentifier,
        action: #selector(ShaarSavePromptPanel.savePromptSave(_:)), target: target))
    return row
  }

  private static func button(
    _ title: String, identifier: String, action: Selector, target: AnyObject
  ) -> NSButton {
    let button = NSButton(title: title, target: target, action: action)
    button.identifier = NSUserInterfaceItemIdentifier(identifier)
    button.bezelStyle = .rounded
    button.setContentHuggingPriority(.required, for: .horizontal)
    return button
  }
}

/// Keeps the single save bubble attached to the browser window that owns the offer.
@MainActor
final class SavePromptPresenter {
  private var panel: ShaarSavePromptPanel?

  func sync(
    request: SavePromptRequest?, browserWindow: NSWindow?,
    onDecision: @escaping (String, SavePromptRequest.Decision) -> Void
  ) {
    guard let request else {
      close()
      return
    }
    let panel = self.panel ?? ShaarSavePromptPanel()
    self.panel = panel
    if panel.shownRequestID != request.id {
      panel.show(request) { decision in onDecision(request.id, decision) }
    }
    SavePromptPlacement.place(panel, relativeTo: browserWindow)
    if !panel.isVisible { panel.orderFront(nil) }
  }

  func close() {
    panel?.orderOut(nil)
    panel = nil
  }
}

struct SavePromptAnchor: NSViewRepresentable {
  @Bindable var store: BrowserStore

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    view.isHidden = true
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    guard let presenter = store.engine?.savePromptPresenter else { return }
    presenter.sync(
      request: store.savePrompt,
      browserWindow: view.window,
      onDecision: { [weak store] id, decision in
        store?.resolveSavePrompt(id, decision: decision)
      })
  }
}
