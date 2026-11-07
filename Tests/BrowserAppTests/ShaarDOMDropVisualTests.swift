// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct ShaarDOMDropVisualTests {
  @Test func dropMarkersDifferOffscreen() async throws {
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let inside = try await png(preview: ShaarDOMDropPreview(rowID: 3, kind: .inside))
    let before = try await png(preview: ShaarDOMDropPreview(rowID: 3, kind: .before))
    #expect(inside != before)
    #expect(NSApp.keyWindow === previous)
  }

  @Test func writesOffscreenEvidenceWhenRequested() async throws {
    guard ProcessInfo.processInfo.environment["SHAAR_DOM_DROP_CAPTURE"] == "1" else { return }
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1275")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for scheme in [ColorScheme.light, ColorScheme.dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      try await capture(
        nil, named: "before-tree-\(suffix)", scheme: scheme, appearance: appearance, root: root)
      try await capture(
        ShaarDOMDropPreview(rowID: 3, kind: .inside),
        named: "after-inside-\(suffix)", scheme: scheme, appearance: appearance, root: root)
      try await capture(
        ShaarDOMDropPreview(rowID: 3, kind: .before),
        named: "after-before-\(suffix)", scheme: scheme, appearance: appearance, root: root)
    }
  }

  private func png(preview: ShaarDOMDropPreview) async throws -> Data {
    let view = try await panel(preview: preview).frame(width: 860, height: 520)
    return try VisualCapture.pngOffscreen(view, size: NSSize(width: 860, height: 520))
  }

  private func capture(
    _ preview: ShaarDOMDropPreview?, named name: String, scheme: ColorScheme,
    appearance: NSAppearance.Name, root: URL
  ) async throws {
    let view = try await panel(preview: preview)
      .frame(width: 860, height: 520)
      .environment(\.colorScheme, scheme)
    _ = try VisualCapture.renderOffscreen(
      view, size: NSSize(width: 860, height: 520), appearance: appearance,
      to: root.appending(path: "\(name).png"))
  }

  private func panel(preview: ShaarDOMDropPreview?) async throws -> ShaarDOMTreePanel {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.test")!)
    let inspector = InspectorModel(target: target, engine: nil)
    inspector.open()
    let model = ShaarDOMTreeModel(target: target, transport: DOMFixtureTransport())
    model.open()
    for _ in 0..<30 where model.rootID == nil { await Task.yield() }
    #expect(model.nodes[3] != nil)
    return ShaarDOMTreePanel(
      model: model, inspector: inspector, openChromium: {}, dropPreview: preview)
  }
}
