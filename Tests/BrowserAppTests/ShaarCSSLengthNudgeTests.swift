// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct ShaarCSSLengthNudgeTests {
  @Test func hostRendersOffscreenAndArrowsNudgeAHiddenLengthField() throws {
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let hostImage = try VisualCapture.pngOffscreen(
      ShaarCSSLengthNudgeHost(), size: NSSize(width: 40, height: 40))
    #expect(!hostImage.isEmpty)

    let window = hiddenWindow()
    defer { window.close() }
    let field = lengthField("10px")
    window.contentView?.addSubview(field)
    #expect(window.makeFirstResponder(field))
    let up = try #require(arrow(126, flags: [], window: window))
    #expect(up.specialKey == .upArrow)
    #expect(up.window === window)
    #expect(ShaarCSSLengthNudge.consume(up) == nil)
    #expect(editedText(window) == "11px")

    replaceText(window, "10px")
    let shift = try #require(arrow(126, flags: [.shift], window: window))
    #expect(ShaarCSSLengthNudge.consume(shift) == nil)
    #expect(editedText(window) == "20px")

    replaceText(window, "10px")
    let option = try #require(arrow(125, flags: [.option], window: window))
    #expect(ShaarCSSLengthNudge.consume(option) == nil)
    #expect(editedText(window) == "9.9px")

    replaceText(window, "10px")
    let command = try #require(arrow(126, flags: [.command], window: window))
    #expect(ShaarCSSLengthNudge.consume(command) === command)
    #expect(editedText(window) == "10px")

    let control = try #require(arrow(125, flags: [.control], window: window))
    #expect(ShaarCSSLengthNudge.consume(control) === control)

    let letter = try #require(arrow(0, flags: [], window: window))
    #expect(ShaarCSSLengthNudge.consume(letter) === letter)

    replaceText(window, "auto")
    let ignored = try #require(arrow(126, flags: [], window: window))
    #expect(ShaarCSSLengthNudge.consume(ignored) === ignored)
    #expect(editedText(window) == "auto")

    let labeled = labeledEditor(window, text: "4px")
    #expect(window.makeFirstResponder(labeled))
    let labeledUp = try #require(arrow(126, flags: [], window: window))
    #expect(ShaarCSSLengthNudge.consume(labeledUp) == nil)
    #expect(labeled.string == "5px")

    let plain = NSTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
    plain.string = "8px"
    window.contentView?.addSubview(plain)
    #expect(window.makeFirstResponder(plain))
    let plainUp = try #require(arrow(126, flags: [], window: window))
    #expect(ShaarCSSLengthNudge.consume(plainUp) === plainUp)
    #expect(plain.string == "8px")

    #expect(window.makeFirstResponder(nil))
    let nowhere = try #require(arrow(126, flags: [], window: window))
    #expect(ShaarCSSLengthNudge.consume(nowhere) === nowhere)
    #expect(NSApp.keyWindow === previous)
  }
}

@MainActor private func hiddenWindow() -> NSWindow {
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
    styleMask: [], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
  return window
}

@MainActor private func lengthField(_ text: String) -> NSTextField {
  let field = NSTextField(string: text)
  field.placeholderString = InspectorL10n.string("value")
  field.frame = NSRect(x: 8, y: 28, width: 120, height: 24)
  return field
}

@MainActor private func labeledEditor(_ window: NSWindow, text: String) -> NSTextView {
  let editor = NSTextView(frame: NSRect(x: 8, y: 8, width: 120, height: 24))
  editor.string = text
  editor.setAccessibilityLabel(InspectorL10n.string("CSS value"))
  window.contentView?.addSubview(editor)
  return editor
}

@MainActor private func replaceText(_ window: NSWindow, _ text: String) {
  if let editor = window.firstResponder as? NSTextView {
    editor.string = text
    editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
  } else if let field = window.firstResponder as? NSTextField {
    field.stringValue = text
  }
}

@MainActor private func editedText(_ window: NSWindow) -> String? {
  if let editor = window.firstResponder as? NSTextView { return editor.string }
  if let field = window.firstResponder as? NSTextField { return field.stringValue }
  return nil
}

@MainActor private func arrow(
  _ keyCode: UInt16, flags: NSEvent.ModifierFlags, window: NSWindow
) -> NSEvent? {
  let characters = arrowCharacters(keyCode)
  return NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: flags,
    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
    context: nil, characters: characters, charactersIgnoringModifiers: characters,
    isARepeat: false, keyCode: keyCode)
}

private func arrowCharacters(_ keyCode: UInt16) -> String {
  let scalar: UnicodeScalar
  switch keyCode {
  case 126: scalar = UnicodeScalar(NSUpArrowFunctionKey)!
  case 125: scalar = UnicodeScalar(NSDownArrowFunctionKey)!
  default: return "a"
  }
  return String(scalar)
}
