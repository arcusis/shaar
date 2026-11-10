// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarStackingViewVisualTests: XCTestCase {
  func testStackingViewRendersOffscreenInBothAppearances() throws {
    guard ProcessInfo.processInfo.environment["SHAAR_STACKING_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen stacking capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1486")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let empty = makeShell()
    let populated = makeShell()

    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      try render(
        empty, name: "before-\(suffix)", appearance: appearance, scheme: scheme, root: root,
        snapshot: nil)
      try render(
        populated, name: "after-\(suffix)", appearance: appearance, scheme: scheme, root: root,
        snapshot: StackingCapture.snapshot)
    }
    populated.close()
    empty.close()
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  private func makeShell() -> ShaarDevToolsModel {
    let defaults = UserDefaults(suiteName: "ShaarStackingCapture.\(UUID().uuidString)")!
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://127.0.0.1/stacking")!)
    return ShaarDevToolsModel(target: target, layoutDefaults: defaults)
  }

  private func render(
    _ shell: ShaarDevToolsModel, name: String, appearance: NSAppearance.Name, scheme: ColorScheme,
    root: URL, snapshot: ShaarStackingSnapshot?
  ) throws {
    let inspector = InspectorModel(target: shell.target, engine: nil)
    if !shell.isOpen { shell.open(inspector: inspector) }
    shell.section = .stacking
    if let snapshot {
      shell.stacking.attach(
        capture: { snapshot },
        select: { _ in true })
      shell.stacking.present(snapshot, mode: .zIndex)
      shell.stacking.camera = ShaarStackingProjection.fitted(
        slabs: shell.stacking.slabs, in: NSSize(width: 600, height: 560), orbit: .orbit)
      shell.stacking.select(6)
    }
    let panel = ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {})
      .frame(width: 980, height: 640)
      .environment(\.colorScheme, scheme)
    try VisualCapture.renderOffscreen(
      panel, size: NSSize(width: 980, height: 640), appearance: appearance,
      to: root.appending(path: "\(name).png"))
    inspector.close()
  }
}

private enum StackingCapture {
  static let snapshot = ShaarStackingSnapshot(
    elements: [
      row(1, "html", bounds: CGRect(x: 0, y: 0, width: 720, height: 480), depth: 0),
      row(2, "body", parent: 1, bounds: CGRect(x: 0, y: 0, width: 720, height: 480), depth: 1),
      row(
        3, "div#page", parent: 2, bounds: CGRect(x: 24, y: 24, width: 520, height: 360), depth: 2,
        position: "relative"),
      row(
        4, "div#behind", parent: 3, bounds: CGRect(x: 40, y: 48, width: 220, height: 120), depth: 3,
        position: "absolute", zIndex: "-1"),
      row(
        5, "div#card", parent: 3, bounds: CGRect(x: 80, y: 90, width: 260, height: 150), depth: 3,
        position: "absolute"),
      row(
        6, "div#modal", parent: 3, bounds: CGRect(x: 160, y: 130, width: 240, height: 140),
        depth: 3,
        position: "absolute", zIndex: "10"),
      row(
        7, "div#faded", parent: 3, bounds: CGRect(x: 40, y: 250, width: 140, height: 64), depth: 3,
        opacity: "0.45"),
    ], clipped: false)

  static func row(
    _ nodeID: Int, _ name: String, parent: Int? = nil, bounds: CGRect, depth: Int,
    position: String = "static", zIndex: String = "auto", opacity: String = "1"
  ) -> ShaarStackingElement {
    ShaarStackingElement(
      nodeID: nodeID, parentID: parent, name: name, depth: depth, bounds: bounds,
      style: ShaarStackingStyle(position: position, zIndex: zIndex, opacity: opacity),
      parentDisplay: "block")
  }
}
