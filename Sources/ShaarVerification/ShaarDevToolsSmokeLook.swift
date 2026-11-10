// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit

@testable import ArcusisBrowser

/// Small visual and keyboard defects in one DevTools panel. One row per kind.
@MainActor enum ShaarDevToolsSmokeLook {
  static func survey(
    panel: String, contentIdentifier: String?, in root: NSView, failure: String?,
    report: ShaarDevToolsSmokeReport
  ) {
    guard let contentIdentifier,
      let content = ShaarDevToolsSmokeAccess.element(identifier: contentIdentifier, in: root)
        as? NSView
    else { return }
    var clip: String?
    var tiny: String?
    var faint: String?
    var unlabeled: String?
    var spinner: String?
    var labels = 0
    var text = ""
    walk(content) { view in
      let gathered = collectedText(view)
      labels += gathered.count
      text += gathered.text
      if clip == nil { clip = clippedText(view) }
      if tiny == nil { tiny = tinyText(view) }
      if faint == nil { faint = faintText(view) }
      if unlabeled == nil { unlabeled = unnamedControl(view) }
      if spinner == nil { spinner = spinning(view) }
    }
    if clip == nil { clip = tabOutsideShell(panel: panel, in: root) }
    if let clip { report.fail("look/clip/\(panel)", clip, severity: .polish) }
    if let tiny { report.fail("look/text/\(panel)", tiny, severity: .polish) }
    if let faint { report.fail("look/contrast/\(panel)", faint, severity: .polish) }
    if let unlabeled { report.fail("look/label/\(panel)", unlabeled, severity: .polish) }
    if let spinner { report.fail("look/spinner/\(panel)", spinner, severity: .polish) }
    recordHiddenError(panel: panel, failure: failure, text: text, labels: labels, report: report)
  }

  static func focus(panel: String, in root: NSView, report: ShaarDevToolsSmokeReport) {
    for identifier in focusIdentifiers(panel) {
      guard let object = ShaarDevToolsSmokeAccess.element(identifier: identifier, in: root),
        let field = textField(in: object), field.acceptsFirstResponder, let window = field.window
      else { continue }
      if window.makeFirstResponder(field) || window.firstResponder === field { continue }
      report.fail(
        "look/focus/\(panel)", "\(identifier) refused keyboard focus", severity: .polish)
      return
    }
  }

  static func recordBlank(panel: String, in root: NSView, report: ShaarDevToolsSmokeReport) {
    let name = "look/blank/\(panel)"
    guard !report.contains(name) else { return }
    guard
      let shell = ShaarDevToolsSmokeAccess.element(
        identifier: "shaar.devtools.shell", in: root) as? NSView
    else { return }
    var labels = 0
    var text = ""
    walk(shell) { view in
      let gathered = collectedText(view)
      labels += gathered.count
      text += gathered.text
    }
    guard labels >= 4, !explainsEmptiness(text) else { return }
    let sample = text.replacingOccurrences(of: "\n", with: " ")
    let preview = sample.count > 80 ? String(sample.prefix(80)) : sample
    report.fail(
      name, "The list is empty and nothing says why. First text: \(preview)", severity: .wrong)
  }

  private static func recordHiddenError(
    panel: String, failure: String?, text: String, labels: Int, report: ShaarDevToolsSmokeReport
  ) {
    guard let failure, !failure.isEmpty, labels >= 4 else { return }
    let needle = failure.prefix(24).lowercased()
    guard !needle.isEmpty, !text.lowercased().contains(needle) else { return }
    report.fail(
      "look/error/\(panel)", "Error is not shown: \(failure.prefix(120))", severity: .wrong)
  }

  private static func focusIdentifiers(_ panel: String) -> [String] {
    switch panel {
    case "Console":
      ["shaar.devtools.consoleSearch", "shaar.devtools.consoleCommand"]
    case "Network":
      ["shaar.devtools.networkSearch"]
    case "Elements":
      ["shaar.devtools.domSearch"]
    case "Inspector":
      ["shaar.devtools.computedFilter"]
    default:
      []
    }
  }

  private static func tabOutsideShell(panel: String, in root: NSView) -> String? {
    let tabID = "shaar.devtools.\(panel.lowercased())"
    guard let tab = ShaarDevToolsSmokeAccess.element(identifier: tabID, in: root) as? NSView,
      let shell = ShaarDevToolsSmokeAccess.element(
        identifier: "shaar.devtools.shell", in: root) as? NSView,
      tab.bounds.width > 1
    else { return nil }
    let shellFrame = shell.convert(shell.bounds, to: nil)
    let tabFrame = tab.convert(tab.bounds, to: nil)
    guard !shellFrame.intersects(tabFrame) else { return nil }
    return "The \(panel) tab sits outside the DevTools shell"
  }

  private static func clippedText(_ view: NSView) -> String? {
    guard let field = view as? NSTextField, !field.isHiddenOrHasHiddenAncestor else { return nil }
    guard field.bounds.width > 8, field.bounds.height > 0, field.bounds.height < 28 else {
      return nil
    }
    guard field.cell?.wraps != true, field.cell?.isScrollable != true else { return nil }
    guard view.enclosingScrollView == nil else { return nil }
    let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.count > 3, let font = field.font else { return nil }
    let width = (text as NSString).size(withAttributes: [.font: font]).width
    guard width > field.bounds.width + 4 else { return nil }
    return "“\(text.prefix(40))” is wider than its field"
  }

  private static func tinyText(_ view: NSView) -> String? {
    guard let field = view as? NSTextField, !field.isHiddenOrHasHiddenAncestor,
      let size = field.font?.pointSize, size > 0, size < 9
    else { return nil }
    let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    return "“\(text.prefix(24))” is \(size) pt"
  }

  private static func faintText(_ view: NSView) -> String? {
    guard let field = view as? NSTextField, !field.isHiddenOrHasHiddenAncestor,
      let foreground = field.textColor, let faded = opaque(foreground)
    else { return nil }
    let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if faded.alphaComponent < 0.35 {
      return "“\(text.prefix(24))” is nearly transparent"
    }
    guard let ratio = contrast(faded, background(behind: field)), ratio < 2.5 else { return nil }
    return String(format: "“%@” contrast is %.1f:1", String(text.prefix(24)), ratio)
  }

  private static func unnamedControl(_ view: NSView) -> String? {
    guard let button = view as? NSButton, !button.isHiddenOrHasHiddenAncestor,
      button.bounds.width > 8, button.bounds.height > 8, button.title.isEmpty
    else { return nil }
    if let label = button.accessibilityLabel(), !label.isEmpty { return nil }
    if let tip = button.toolTip, !tip.isEmpty { return nil }
    if let help = button.accessibilityHelp(), !help.isEmpty { return nil }
    if descendantHasText(button) { return nil }
    return "A \(Int(button.bounds.width))×\(Int(button.bounds.height)) button has no name"
  }

  private static func spinning(_ view: NSView) -> String? {
    guard let progress = view as? NSProgressIndicator, progress.isIndeterminate,
      !progress.isHiddenOrHasHiddenAncestor, progress.bounds.width > 2, progress.alphaValue > 0
    else { return nil }
    return "A spinner is still turning"
  }

  private static func explainsEmptiness(_ text: String) -> Bool {
    let lower = text.lowercased()
    if lower.contains("no ") || lower.contains("nothing") || lower.contains("empty") { return true }
    if lower.contains("unavailable") { return true }
    return lower.contains(" none") || lower.hasPrefix("none")
  }

  private static func collectedText(_ view: NSView) -> (count: Int, text: String) {
    var count = 0
    var text = ""
    if let field = view as? NSTextField {
      let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      if !value.isEmpty {
        text += value + "\n"
        count += 1
      }
    }
    if let label = view.accessibilityLabel()?.trimmingCharacters(in: .whitespacesAndNewlines),
      !label.isEmpty
    {
      text += label + "\n"
      count += 1
    }
    return (count, text)
  }

  private static func descendantHasText(_ view: NSView) -> Bool {
    if let field = view as? NSTextField, !field.stringValue.isEmpty { return true }
    if let label = view.accessibilityLabel(), !label.isEmpty { return true }
    return view.subviews.contains { descendantHasText($0) }
  }

  private static func textField(in object: NSObject) -> NSTextField? {
    if let field = object as? NSTextField { return field }
    guard let view = object as? NSView else { return nil }
    for child in view.subviews {
      if let field = textField(in: child) { return field }
    }
    return nil
  }

  private static func background(behind view: NSView) -> NSColor? {
    if let field = view as? NSTextField, field.drawsBackground,
      let color = field.backgroundColor, opaque(color) != nil
    {
      return color
    }
    var current = view.superview
    while let view = current {
      if let cgColor = view.layer?.backgroundColor, let color = NSColor(cgColor: cgColor),
        let painted = opaque(color)
      {
        return painted
      }
      current = view.superview
    }
    return nil
  }

  private static func contrast(_ foreground: NSColor, _ background: NSColor?) -> CGFloat? {
    guard let background, let first = luminance(foreground), let second = luminance(background)
    else { return nil }
    let lighter = max(first, second)
    let darker = min(first, second)
    return (lighter + 0.05) / (darker + 0.05)
  }

  private static func luminance(_ color: NSColor) -> CGFloat? {
    guard let rgb = opaque(color) else { return nil }
    return (0.2126 * channel(rgb.redComponent)) + (0.7152 * channel(rgb.greenComponent))
      + (0.0722 * channel(rgb.blueComponent))
  }

  private static func channel(_ value: CGFloat) -> CGFloat {
    if value <= 0.04045 { return value / 12.92 }
    return pow((value + 0.055) / 1.055, 2.4)
  }

  private static func opaque(_ color: NSColor) -> NSColor? {
    guard let rgb = color.usingColorSpace(.sRGB), rgb.alphaComponent > 0 else { return nil }
    return rgb
  }

  private static func walk(_ view: NSView, visit: (NSView) -> Void) {
    visit(view)
    for child in view.subviews { walk(child, visit: visit) }
  }
}
