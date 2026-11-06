// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarReproVisualTests: XCTestCase {
  func testReproStatesRenderOffscreen() async throws {
    guard ProcessInfo.processInfo.environment["SHAAR_REPRO_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen repro capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1158")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/page")!)
    let inspector = InspectorModel(target: target, engine: nil)
    let shell = ShaarDevToolsModel(target: target)
    inspector.open()
    shell.open(inspector: inspector)
    shell.section = .sources
    for scheme in [ColorScheme.light, .dark] {
      try render(shell, inspector: inspector, scheme: scheme, label: "before-shell", root: root)
    }
    shell.section = .repro
    for scheme in [ColorScheme.light, .dark] {
      try render(
        shell, inspector: inspector, scheme: scheme, label: "after-unavailable", root: root)
    }
    let bundle = ShaarReproCapture(
      videoMP4: Data([0, 0, 0, 12] + Array("ftypisom".utf8)), durationSeconds: 24,
      dom: ShaarReproDOMNode(
        tag: "body", text: "Fixture", attributes: [:],
        children: [
          ShaarReproDOMNode(tag: "p", text: "Dashboard ready", attributes: [:], children: [])
        ]),
      console: [ShaarConsoleEvent(id: UUID(), level: .log, message: "Ready", source: nil)],
      network: [
        ShaarNetworkEvent(
          id: UUID(), method: "GET", url: "https://example.com/api", status: 200)
      ],
      environment: ShaarReproEnvironment(
        url: target.url.absoluteString, shaarVersion: "test", engineVersion: "fixture",
        operatingSystem: "macOS", userAgent: "Fixture/1", viewportWidth: 1040,
        viewportHeight: 620))
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = try await ShaarReproBundle.save(bundle, target: target, directory: directory)
    let stableFile = directory.appending(path: "Fixture.shaarrepro")
    try FileManager.default.moveItem(at: file, to: stableFile)
    await shell.repro.open(stableFile)
    for scheme in [ColorScheme.light, .dark] {
      try render(shell, inspector: inspector, scheme: scheme, label: "viewer-after", root: root)
    }
    shell.close()
    let readyInspector = InspectorModel(target: target, engine: nil)
    let readyShell = ShaarDevToolsModel(
      target: target, reproTransport: ReadyReproVisualTransport())
    readyShell.open(inspector: readyInspector)
    readyShell.section = .repro
    for scheme in [ColorScheme.light, .dark] {
      try render(
        readyShell, inspector: readyInspector, scheme: scheme, label: "ready-after", root: root,
        directory: root)
    }
    readyShell.close()
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  private func render(
    _ shell: ShaarDevToolsModel, inspector: InspectorModel, scheme: ColorScheme,
    label: String, root: URL, directory: URL? = nil
  ) throws {
    let suffix = scheme == .dark ? "dark" : "light"
    let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
    let view = ShaarDevToolsPanel(
      model: shell, inspector: inspector, openChromium: {}, reproDirectory: directory)
      .frame(width: 1040, height: 420).environment(\.colorScheme, scheme)
    let image = try VisualCapture.renderOffscreen(
      view, size: NSSize(width: 1040, height: 420), appearance: appearance,
      to: root.appending(path: "\(label)-\(suffix).png"))
    XCTAssertEqual(image.pixelsWide, 1040)
  }
}

private struct ReadyReproVisualTransport: ShaarReproTransport {
  let available = true
  func capture(for target: SiteControlTarget, seconds: Int) async throws -> ShaarReproCapture {
    throw CancellationError()
  }
}
