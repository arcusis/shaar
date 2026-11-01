// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import JavaScriptCore
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct InspectorPanelTests {
  private var target: SiteControlTarget {
    .init(tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/inspect")!)
  }

  @Test func shippingPickerScriptParsesAsJavaScript() throws {
    let context = try #require(JSContext())
    let parse = try #require(
      context.evaluateScript("source => { new Function(source); return true; }"))
    #expect(parse.call(withArguments: [InspectorPageScript.install])?.toBool() == true)
    #expect(context.exception == nil)
  }

  @Test func selectionValidationAndNavigationRetireNativeState() async throws {
    let model = InspectorModel(target: target, engine: nil)
    #expect(!model.isOpen)
    #expect(throws: InspectorFailure.self) { try model.receive(selection()) }
    model.open()
    model.open()
    try model.receive(selection())
    #expect(model.mode == .locked && model.selection?.dimensions == "180 × 48")
    #expect(model.selection?.contrastGrade == "AAA")
    model.pick()
    model.navigate("invalid")
    model.selectAncestor(-1)
    model.documentChanged(url: URL(string: "https://example.com/next")!, committed: true)
    #expect(model.target.url.path == "/next")
    #expect(model.mode == .picking && model.selection == nil)
    try model.receive(selection(locked: false))
    #expect(model.mode == .picking)
    await model.refresh()
    model.close()
    model.close()
    #expect(model.mode == .closed && model.selection == nil)
    await #expect(throws: InspectorFailure.self) { _ = try await model.evaluate("true") }
  }

  @Test func panelRendersRealSelectionAcrossColorFormatsAndContrastLimits() async throws {
    let model = InspectorModel(target: target, engine: nil)
    model.open()
    defer { model.close() }
    let previous = NSApp.keyWindow
    var appearances: [Data] = []
    for scheme in [ColorScheme.light, .dark] {
      for format in InspectorColor.Format.allCases {
        model.colorFormat = format
        var value = selection(limit: format == .oklch ? "Gradient background" : nil)
        value.renderedFonts = ["Arial"]
        value.pageFonts = ["Arial", "Georgia"]
        value.fontsAvailable = format != .rgb
        try model.receive(value)
        let image = try await render(InspectorPanel(model: model), scheme: scheme)
        #expect(image.count > 4_096)
        appearances.append(image)
      }
    }
    #expect(appearances[0] != appearances[3])
    model.documentChanged(url: target.url, committed: true)
    #expect(try await render(InspectorPanel(model: model), scheme: .light).count > 4_096)
    #expect(NSApp.keyWindow === previous)
  }

  @Test func invalidRendererPacketsCannotReplaceValidSelection() throws {
    let model = InspectorModel(target: target, engine: nil)
    model.open()
    defer { model.close() }
    let good = selection()
    try model.receive(good)
    let malformed = InspectorSelection(
      id: -1, revision: 0, locked: true, tag: "button", label: "button", component: nil,
      css: "button", xpath: "//button", playwright: "page.locator('button')",
      jsPath: "document.body",
      frames: [], ancestors: [], box: good.box, typography: good.typography,
      colors: good.colors, foreground: good.foreground, backdrop: good.backdrop, contrastLimit: nil)
    #expect(throws: InspectorFailure.self) { try model.receive(malformed) }
    #expect(model.selection == good)
  }

  private func selection(locked: Bool = true, limit: String? = nil) -> InspectorSelection {
    .init(
      id: 8, revision: 1, locked: locked, tag: "button", label: "button.save",
      component: "SaveButton",
      css: ".save", xpath: "/html/body/button",
      playwright: "page.getByRole('button', {name:'Save'})",
      jsPath: "document.querySelector('.save')", frames: ["iframe"],
      ancestors: [
        .init(id: 1, label: "html"), .init(id: 2, label: "body"), .init(id: 3, label: "main"),
        .init(id: 8, label: "button.save"),
      ],
      box: .init(
        width: 180, height: 48, contentWidth: 136, contentHeight: 24,
        margin: ["8px", "12px", "8px", "12px"], border: Array(repeating: "2px", count: 4),
        padding: ["10px", "20px", "10px", "20px"]),
      typography: .init(
        family: "Arial, sans-serif", size: "16px", weight: "600", lineHeight: "24px",
        letterSpacing: "0.25px", preview: "Save changes"),
      colors: [
        .init(label: "Text", value: .init(css: "black", rgba: [0, 0, 0, 1])),
        .init(label: "Background", value: .init(css: "white", rgba: [1, 1, 1, 1])),
        .init(label: "Border", value: .init(css: "rgba(0,0,0,.5)", rgba: [0, 0, 0, 0.5])),
      ],
      foreground: .init(css: "black", rgba: [0, 0, 0, 1]),
      backdrop: .init(css: "white", rgba: [1, 1, 1, 1]), contrastLimit: limit)
  }

  private func render(_ panel: some View, scheme: ColorScheme) async throws -> Data {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 1000), styleMask: [], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    let hosting = NSHostingView(
      rootView: panel.frame(width: 320, height: 1000).environment(\.colorScheme, scheme))
    window.contentView = hosting
    defer {
      window.contentView = nil
      window.close()
    }
    hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(30))
    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    #expect(!window.isVisible)
    return try #require(bitmap.representation(using: .png, properties: [:]))
  }
}
