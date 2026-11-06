// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarViewportsVisualTests: XCTestCase {
  func testUnavailableAndFixtureViewsRenderOffscreen() async throws {
    guard ProcessInfo.processInfo.environment["SHAAR_VIEWPORTS_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen Viewports capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1159")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/dashboard")!)
    let inspector = InspectorModel(target: target, engine: nil)
    let imageRoot = FileManager.default.temporaryDirectory
    let phoneImage = try makeFrameImage(
      preset: .iphone15Pro, to: imageRoot.appending(path: "shaar-1159-phone.png"))
    let pixelImage = try makeFrameImage(
      preset: .pixel8, to: imageRoot.appending(path: "shaar-1159-pixel.png"))
    let desktopImage = try makeFrameImage(
      preset: .desktop, to: imageRoot.appending(path: "shaar-1159-desktop.png"))
    let fixture = ShaarViewportsFixtureTransport(frames: [
      ShaarViewportFrame(
        id: UUID(), preset: .iphone15Pro, url: target.url, pngData: phoneImage,
        safeArea: .init(top: 59, right: 0, bottom: 34, left: 0)),
      ShaarViewportFrame(
        id: UUID(), preset: .pixel8, url: target.url, pngData: pixelImage,
        safeArea: .init(top: 24, right: 0, bottom: 24, left: 0)),
      ShaarViewportFrame(id: UUID(), preset: .desktop, url: target.url, pngData: desktopImage),
    ])
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      let pending = ShaarDevToolsModel(target: target)
      pending.section = .viewports
      pending.open(inspector: inspector)
      try capture(
        panel: pending, inspector: inspector, named: "after-viewports-unavailable-\(suffix)",
        scheme: scheme, appearance: appearance, root: root)
      pending.close()

      let live = ShaarDevToolsModel(target: target, viewportsTransport: fixture)
      live.section = .viewports
      live.open(inspector: inspector)
      for _ in 0..<30 where live.viewports.frames.count != 3 { await Task.yield() }
      XCTAssertEqual(live.viewports.frames.count, 3)
      try capture(
        panel: live, inspector: inspector, named: "after-viewports-results-\(suffix)",
        scheme: scheme, appearance: appearance, root: root)
      live.close()
    }
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  private func makeFrameImage(preset: ShaarViewportPreset, to url: URL) throws -> Data {
    let width = CGFloat(preset.width)
    let height = CGFloat(preset.height)
    let page = VStack(alignment: .leading, spacing: 16) {
      Text("Dashboard").font(.system(size: 28, weight: .semibold))
      Text("Revenue").font(.system(size: 14)).foregroundStyle(.secondary)
      Text("$24,680").font(.system(size: 32, weight: .semibold))
      RoundedRectangle(cornerRadius: 7).fill(Color.blue.opacity(0.18)).frame(height: 80)
      Spacer()
    }
    .padding(.horizontal, 28)
    .padding(.top, max(28, CGFloat(preset.defaultInsets.top + 20)))
    .frame(width: width, height: height, alignment: .topLeading)
    .background(Color(nsColor: .textBackgroundColor))
    _ = try VisualCapture.renderOffscreen(
      page, size: NSSize(width: width, height: height), appearance: .aqua, to: url)
    return try Data(contentsOf: url)
  }

  private func capture(
    panel: ShaarDevToolsModel, inspector: InspectorModel, named name: String,
    scheme: ColorScheme, appearance: NSAppearance.Name, root: URL
  ) throws {
    let view = ShaarDevToolsPanel(model: panel, inspector: inspector, openChromium: {})
      .frame(width: 1040, height: 440)
      .environment(\.colorScheme, scheme)
    let image = try VisualCapture.renderOffscreen(
      view, size: NSSize(width: 1040, height: 440), appearance: appearance,
      to: root.appending(path: "\(name).png"))
    XCTAssertEqual(image.pixelsWide, 1040)
    XCTAssertEqual(image.pixelsHigh, 440)
  }
}
