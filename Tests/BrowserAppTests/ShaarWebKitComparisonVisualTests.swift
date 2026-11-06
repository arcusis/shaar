// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarWebKitComparisonVisualTests: XCTestCase {
  func testComparisonMockRendersOffscreenInBothAppearances() throws {
    guard ProcessInfo.processInfo.environment["SHAAR_WEBKIT_COMPARISON_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen comparison mock capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1245")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/dashboard")!)
    let inspector = InspectorModel(target: target, engine: nil)
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      let chromiumURL = FileManager.default.temporaryDirectory
        .appending(path: "shaar-comparison-\(UUID().uuidString).png")
      defer { try? FileManager.default.removeItem(at: chromiumURL) }
      try VisualCapture.renderOffscreen(
        samplePage.environment(\.colorScheme, scheme),
        size: NSSize(width: 900, height: 600), appearance: appearance,
        to: chromiumURL)
      let preview = ShaarWebKitComparisonPreview(
        chromiumPNG: try Data(contentsOf: chromiumURL),
        webKitHTML: webKitHTML, viewport: CGSize(width: 900, height: 600),
        differenceTiles: [CGRect(x: 500, y: 110, width: 192, height: 64)],
        webKitErrors: ["Unsupported CSS backdrop-filter value"])
      let shell = ShaarDevToolsModel(
        target: target, allowsWebKitComparison: true, comparisonPreview: preview)
      shell.open(inspector: inspector)
      shell.section = .console
      let before = ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {})
        .frame(width: 1040, height: 680)
        .environment(\.colorScheme, scheme)
      try VisualCapture.renderOffscreen(
        before, size: NSSize(width: 1040, height: 680), appearance: appearance,
        to: root.appending(path: "before-panel-\(suffix).png"))
      shell.section = .comparison
      RunLoop.current.run(until: Date().addingTimeInterval(1.0))
      let after = ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {})
        .frame(width: 1040, height: 680)
        .environment(\.colorScheme, scheme)
      try VisualCapture.renderOffscreen(
        after, size: NSSize(width: 1040, height: 680), appearance: appearance,
        to: root.appending(path: "after-comparison-\(suffix).png"))
      let right = InspectorPageLayout(
        model: inspector, shell: shell, openChromium: {}, page: { self.samplePage }
      )
      .frame(width: 1040, height: 680)
      .environment(\.colorScheme, scheme)
      try VisualCapture.renderOffscreen(
        right, size: NSSize(width: 1040, height: 680), appearance: appearance,
        to: root.appending(path: "after-right-\(suffix).png"))
      shell.close()
    }
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  private var samplePage: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("Dashboard").font(.system(size: 42, weight: .semibold))
      Text("Revenue this week").font(.system(size: 17)).foregroundStyle(.secondary)
      Text("$24,680").font(.system(size: 54, weight: .bold))
      RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.18))
        .frame(width: 600, height: 150)
      Spacer()
    }
    .padding(42)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(nsColor: .textBackgroundColor))
  }

  private var webKitHTML: String {
    """
    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>
      body { margin: 0; padding: 42px; font: 17px -apple-system; background: #f8f8f8; }
      h1 { font-size: 42px; margin: 0 0 20px; }
      .revenue { font-size: 54px; font-weight: 700; margin: 20px 0; }
      .chart { width: 600px; height: 150px; border-radius: 12px; background: #b9d8ff; }
      @media (prefers-color-scheme: dark) {
        body { background: #202020; color: white; }
        .chart { background: #193d56; }
      }
    </style>
    <h1>Dashboard</h1><div>Revenue this week</div>
    <div class="revenue">$24,680</div><div class="chart"></div>
    """
  }
}
