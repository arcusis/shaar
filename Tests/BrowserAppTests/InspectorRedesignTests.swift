// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct InspectorRedesignTests {
  init() { _ = NSApplication.shared }
  @Test func tabsAndCopyMenuStayInsideBothDockWidthsInBothAppearances() async throws {
    let inspector = model()
    defer { inspector.close() }
    var selection = InspectorPanelTests.fixtureSelection()
    selection.display = "inline-block"
    selection.identifier = "save"
    selection.classNames = ["save", "primary"]
    selection.renderedFonts = ["Arial"]
    selection.fontsAvailable = true
    try inspector.receive(selection)
    try inspector.styles.receive(
      rules: [
        .init(
          id: 0, selector: ".save", source: "/styles.css:12",
          declarations: [.init(name: "padding", value: "12px 24px")])
      ],
      computed: [
        (.init(name: "display", value: "inline-block")), .init(name: "padding", value: "12px 24px"),
        .init(name: "font-family", value: "Arial"),
      ],
      selectionID: selection.id, generation: inspector.documentGeneration)
    inspector.aiCopy.append(
      context: InspectorAIFormatterTests.context(), feedback: "Increase the button padding.",
      intent: .change)
    for width in [CGFloat(320), 420] {
      for scheme in [ColorScheme.light, .dark] {
        for (name, tab, menu) in [
          ("design", InspectorModel.Tab.design, false), ("code", .styles, false),
          ("notes", .notes, false), ("copy-menu", .design, true),
        ] {
          inspector.tab = tab
          let layout = InspectorLayoutSnapshot()
          inspector.presentation.copyMenuOpen = menu
          let image = try await capture(inspector, width: width, scheme: scheme, layout: layout)
          #expect(image.count > 4096)
          #expect(layout.tabFrames.count == 6)
          for rect in layout.tabFrames.values {
            #expect(rect.minX >= -0.5 && rect.maxX <= width + 0.5 && rect.height >= 30)
          }
          if menu {
            let rect = layout.copyMenuFrame
            #expect(rect.width > 180 && rect.minX >= 0 && rect.maxX <= width + 0.5)
            #expect(rect.minY >= 0 && rect.maxY <= 960)
          }
          let root = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(
              path: "build/Verification/InspectorRedesign")
          try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
          try image.write(
            to: root.appending(
              path: "unit-\(name)-\(Int(width))-\(scheme == .dark ? "dark" : "light").png"))
        }
      }
    }
  }

  @Test func sectionPreferencesStayWithTabAndCopiesReportCompletion() async throws {
    let inspector = model()
    defer { inspector.close() }
    inspector.presentation.collapsedSections.insert("Design:Typography")
    inspector.presentation.codeSections.insert("Design:Colors")
    inspector.documentChanged(url: URL(string: "https://example.com/next")!, committed: true)
    inspector.close()
    inspector.open()
    #expect(inspector.presentation.collapsedSections.contains("Design:Typography"))
    #expect(inspector.presentation.codeSections.contains("Design:Colors"))
    let other = model()
    defer { other.close() }
    #expect(!other.presentation.collapsedSections.contains("Design:Typography"))
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    inspector.copy("#account", label: "CSS selector", to: board)
    #expect(board.string(forType: .string) == "#account")
    #expect(inspector.presentation.toast == "Copied CSS selector to clipboard")
    inspector.close()
    #expect(inspector.presentation.toast == nil && !inspector.presentation.copyMenuOpen)
  }

  private func model() -> InspectorModel {
    let model = InspectorModel(
      target: .init(tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!),
      engine: nil)
    model.open()
    return model
  }

  private func capture(
    _ model: InspectorModel, width: CGFloat, scheme: ColorScheme, layout: InspectorLayoutSnapshot
  ) async throws
    -> Data
  {
    let previous = NSApp.keyWindow
    let host = NSHostingView(
      rootView: InspectorPanel(model: model, layout: layout).frame(width: width, height: 960)
        .environment(
          \.colorScheme, scheme))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 960), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    window.contentView = host
    defer {
      window.contentView = nil
      window.close()
    }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    #expect(!window.isVisible && NSApp.keyWindow === previous)
    return try #require(bitmap.representation(using: .png, properties: [:]))
  }
}
