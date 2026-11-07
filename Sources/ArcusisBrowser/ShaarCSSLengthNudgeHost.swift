// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI

struct ShaarCSSLengthNudgeHost: NSViewRepresentable {
  func makeNSView(context: Context) -> ShaarCSSLengthNudgeView { ShaarCSSLengthNudgeView() }
  func updateNSView(_ nsView: ShaarCSSLengthNudgeView, context: Context) {}
}

final class ShaarCSSLengthNudgeView: NSView {
  private var monitor: Any?

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if window !== newWindow { detach() }
    super.viewWillMove(toWindow: newWindow)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    detach()
    guard window != nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      self?.apply(event) ?? event
    }
  }

  private func apply(_ event: NSEvent) -> NSEvent? {
    guard let window, event.window === window else { return event }
    return ShaarCSSLengthNudge.consume(event)
  }

  private func detach() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }

  isolated deinit { detach() }
}

@MainActor
enum ShaarCSSLengthNudge {
  static func consume(_ event: NSEvent) -> NSEvent? {
    guard let delta = delta(for: event), let editor = fieldEditor(event) else { return event }
    guard isCSSValue(editor) else { return event }
    let caret = editor.selectedRange().location
    guard caret != NSNotFound,
      let edit = ShaarCSSLength.edit(editor.string, caret: caret, by: delta)
    else { return event }
    editor.insertText(edit.replacement, replacementRange: edit.range)
    return nil
  }

  private static func delta(for event: NSEvent) -> Decimal? {
    let key: ShaarElementsKey
    switch event.specialKey {
    case .upArrow: key = .up
    case .downArrow: key = .down
    default: return nil
    }
    guard
      case .nudgeLength(let delta) = ShaarElementsShortcuts.action(
        for: ShaarElementsKeyPress(key: key, modifiers: modifiers(of: event)),
        context: .lengthField
      )
    else { return nil }
    return delta
  }

  private static func modifiers(of event: NSEvent) -> Set<ShaarElementsModifier> {
    let flags = event.modifierFlags
    var modifiers: Set<ShaarElementsModifier> = []
    if flags.contains(.command) { modifiers.insert(.command) }
    if flags.contains(.shift) { modifiers.insert(.shift) }
    if flags.contains(.option) { modifiers.insert(.option) }
    if flags.contains(.control) { modifiers.insert(.control) }
    return modifiers
  }

  private static func fieldEditor(_ event: NSEvent) -> NSTextView? {
    let responder = event.window?.firstResponder
    if let editor = responder as? NSTextView { return editor }
    if let field = responder as? NSTextField { return field.currentEditor() as? NSTextView }
    return nil
  }

  private static func isCSSValue(_ editor: NSTextView) -> Bool {
    if labels(around: editor).contains(where: ShaarCSSLength.isLengthFieldLabel) { return true }
    guard let field = editor.delegate as? NSTextField else { return false }
    return field.placeholderString == InspectorL10n.string("value")
  }

  private static func labels(around editor: NSTextView) -> [String] {
    var labels: [String] = []
    if let field = editor.delegate as? NSTextField {
      appendLabel(field.accessibilityLabel(), to: &labels)
    }
    var view: NSView? = editor
    var depth = 0
    while let current = view, depth < 8 {
      appendLabel(current.accessibilityLabel(), to: &labels)
      view = current.superview
      depth += 1
    }
    return labels
  }

  private static func appendLabel(_ label: String?, to labels: inout [String]) {
    guard let label, !label.isEmpty else { return }
    labels.append(label)
  }
}
