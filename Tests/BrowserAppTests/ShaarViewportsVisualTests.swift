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
    let evidence =
      ProcessInfo.processInfo.environment["SHAAR_VIEWPORTS_EVIDENCE"] ?? "Evidence/issue-1159"
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: evidence)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/dashboard")!)
    let inspector = InspectorModel(target: target, engine: nil)
    let imageRoot = FileManager.default.temporaryDirectory
    let phoneImage = try makeFrameImage(
      preset: .iphone15Pro, to: imageRoot.appending(path: "shaar-1159-phone.png"))
    let ipadImage = try makeFrameImage(
      preset: .ipad, to: imageRoot.appending(path: "shaar-1159-ipad.png"))
    let pixelImage = try makeFrameImage(
      preset: .pixel8, to: imageRoot.appending(path: "shaar-1159-pixel.png"))
    let desktopImage = try makeFrameImage(
      preset: .desktop, to: imageRoot.appending(path: "shaar-1159-desktop.png"))
    let wideImage = try makeFrameImage(
      preset: .desktop1440, to: imageRoot.appending(path: "shaar-1159-desktop-1440.png"))
    let landscapeImage = try makeFrameImage(
      preset: .iphone15Pro, orientation: .landscape,
      to: imageRoot.appending(path: "shaar-1159-phone-landscape.png"))
    let fitted = ShaarViewportsFixtureTransport(frames: [
      deviceFrame(.iphone15Pro, url: target.url, png: phoneImage),
      deviceFrame(.ipad, url: target.url, png: ipadImage),
      deviceFrame(.pixel8, url: target.url, png: pixelImage),
      deviceFrame(.desktop, url: target.url, png: desktopImage),
    ])
    let rotatedPhone = deviceFrame(.iphone15Pro, url: target.url, png: landscapeImage)
      .rotated(keepingImage: true)
    let rotated = ShaarViewportsFixtureTransport(frames: [
      ShaarViewportFrame(
        id: rotatedPhone.id, preset: rotatedPhone.preset, url: rotatedPhone.url,
        pngData: landscapeImage, safeArea: rotatedPhone.safeArea,
        orientation: rotatedPhone.orientation),
      deviceFrame(.ipad, url: target.url, png: ipadImage),
      deviceFrame(.desktop, url: target.url, png: desktopImage),
      deviceFrame(.desktop1440, url: target.url, png: wideImage),
    ])
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      let pending = ShaarDevToolsModel(target: target)
      pending.open(inspector: inspector)
      pending.section = .viewports
      try capture(
        panel: pending, inspector: inspector, named: "after-viewports-unavailable-\(suffix)",
        scheme: scheme, appearance: appearance, root: root)
      pending.close()

      let live = ShaarDevToolsModel(target: target, viewportsTransport: fitted)
      live.viewports.zoomToFit = true
      live.open(inspector: inspector)
      live.section = .viewports
      for _ in 0..<80 where live.viewports.frames.count != 4 { await Task.yield() }
      XCTAssertEqual(live.viewports.frames.count, 4)
      try capture(
        panel: live, inspector: inspector, named: "after-viewports-fit-\(suffix)",
        scheme: scheme, appearance: appearance, root: root)
      live.close()

      let pinned = ShaarDevToolsModel(
        target: target,
        viewportsTransport: ShaarViewportsFixtureTransport(
          frames: [
            deviceFrame(.iphone15Pro, url: target.url, png: phoneImage),
            deviceFrame(.ipad, url: target.url, png: ipadImage),
            deviceFrame(.pixel8, url: target.url, png: pixelImage),
            deviceFrame(.desktop, url: target.url, png: desktopImage),
          ], capabilities: ShaarViewportCapabilities()))
      pinned.viewports.zoomToFit = true
      pinned.open(inspector: inspector)
      pinned.section = .viewports
      for _ in 0..<80 where pinned.viewports.frames.count != 4 { await Task.yield() }
      XCTAssertEqual(pinned.viewports.frames.count, 4)
      XCTAssertFalse(pinned.viewports.capabilities.colorScheme)
      try capture(
        panel: pinned, inspector: inspector, named: "after-viewports-pinned-\(suffix)",
        scheme: scheme, appearance: appearance, root: root)
      pinned.close()

      let wide = ShaarDevToolsModel(target: target, viewportsTransport: rotated)
      wide.viewports.zoomToFit = true
      wide.open(inspector: inspector)
      wide.section = .viewports
      for _ in 0..<80 where wide.viewports.frames.count != 4 { await Task.yield() }
      XCTAssertEqual(wide.viewports.frames.first?.orientation, .landscape)
      try capture(
        panel: wide, inspector: inspector, named: "after-viewports-rotated-\(suffix)",
        scheme: scheme, appearance: appearance, root: root)
      wide.close()
    }
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  private func deviceFrame(
    _ preset: ShaarViewportPreset, url: URL, png: Data
  ) -> ShaarViewportFrame {
    ShaarViewportFrame(
      id: UUID(), preset: preset, url: url, pngData: png, safeArea: preset.defaultInsets)
  }

  private func makeFrameImage(
    preset: ShaarViewportPreset, orientation: ShaarViewportOrientation = .portrait, to url: URL
  ) throws -> Data {
    let width = CGFloat(orientation == .portrait ? preset.width : preset.height)
    let height = CGFloat(orientation == .portrait ? preset.height : preset.width)
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
