// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarDevToolsShellVisualTests: XCTestCase {
  func testShellBeforeAndAfterRenderOffscreen() throws {
    guard ProcessInfo.processInfo.environment["SHAAR_DEVTOOLS_SHELL_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen shell capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1124")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/dashboard")!)
    let inspector = InspectorModel(target: target, engine: nil)
    let shell = ShaarDevToolsModel(target: target)
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      let before = DevToolsShellEvidencePage(inspector: inspector, shell: nil)
        .frame(width: 1040, height: 620).environment(\.colorScheme, scheme)
      let beforeImage = try VisualCapture.renderOffscreen(
        before, size: NSSize(width: 1040, height: 620), appearance: appearance,
        to: root.appending(path: "before-inspector-\(suffix).png"))
      XCTAssertEqual(beforeImage.pixelsWide, 1040)
      inspector.open()
      shell.open(inspector: inspector)
      let after = DevToolsShellEvidencePage(inspector: inspector, shell: shell)
        .frame(width: 1040, height: 620).environment(\.colorScheme, scheme)
      let afterImage = try VisualCapture.renderOffscreen(
        after, size: NSSize(width: 1040, height: 620), appearance: appearance,
        to: root.appending(path: "after-shell-\(suffix).png"))
      XCTAssertEqual(afterImage.pixelsWide, 1040)
      shell.close()
      inspector.close()
    }
    XCTAssertTrue(NSApp.keyWindow === previous)
  }
}

private struct DevToolsShellEvidencePage: View {
  let inspector: InspectorModel
  let shell: ShaarDevToolsModel?

  var body: some View {
    Group {
      if let shell {
        VStack(spacing: 0) {
          samplePage
          Divider()
          ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {})
            .frame(height: 420)
        }
      } else {
        HStack(spacing: 0) {
          samplePage
          Divider()
          InspectorPanel(model: inspector).frame(width: 320)
        }
      }
    }
    .background(Color(nsColor: .textBackgroundColor))
  }

  private var samplePage: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("localhost:3000/dashboard")
        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
      Divider()
      Text("Dashboard").font(.system(size: 24, weight: .semibold))
      Text("Inspect the local build while you work.")
        .font(.system(size: 13)).foregroundStyle(.secondary)
      Spacer()
    }
    .padding(22)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
