// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarFrameworkComponentsVisualTests: XCTestCase {
  func testComponentsPanelRendersOffscreenInBothAppearances() async throws {
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await captureAppearances(to: root, includeVueAndAngular: false)
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  func testComponentsEvidenceCapture() async throws {
    guard ProcessInfo.processInfo.environment["SHAAR_COMPONENTS_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen Components capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1082")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try await captureAppearances(to: root, includeVueAndAngular: true)
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  private func captureAppearances(to root: URL, includeVueAndAngular: Bool) async throws {
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      let withheld = try openShell(url: "https://example.com/")
      withheld.model.section = .components
      try capture(
        panel(withheld), named: "before-components-off-\(suffix)", scheme: scheme,
        appearance: appearance, root: root)
      withheld.model.close()
      withheld.inspector.close()

      let react = try await populatedShell(
        url: "http://127.0.0.1:4173/framework-components/react", script: "react.js",
        selection: "Counter")
      try capture(
        panel(react), named: "after-components-react-\(suffix)", scheme: scheme,
        appearance: appearance, root: root)
      react.model.close()
      react.inspector.close()
      guard includeVueAndAngular else { continue }
      let vue = try await populatedShell(
        url: "http://127.0.0.1:4173/framework-components/vue", script: "vue.js",
        selection: "Counter")
      try capture(
        panel(vue), named: "after-components-vue-\(suffix)", scheme: scheme,
        appearance: appearance, root: root)
      vue.model.close()
      vue.inspector.close()
      let angular = try await populatedShell(
        url: "http://127.0.0.1:4173/framework-components/angular", script: "angular.js",
        selection: "Counter")
      try capture(
        panel(angular), named: "after-components-angular-\(suffix)", scheme: scheme,
        appearance: appearance, root: root)
      angular.model.close()
      angular.inspector.close()
    }
  }

  private func populatedShell(
    url: String, script: String, selection: String
  ) async throws -> OpenShell {
    let shell = try openShell(url: url)
    shell.model.section = .components
    let snapshot = try FrameworkFixture.snapshot(script: script)
    let page = RecordingFrameworkPage()
    page.value = try rawValue(script: script)
    shell.model.framework.attach(page)
    await shell.model.framework.refresh()
    XCTAssertEqual(shell.model.framework.rows.map(\.name), snapshot.rows.map(\.name))
    let selected = try XCTUnwrap(shell.model.framework.nodes.first { $0.name == selection })
    shell.model.framework.select(selected.id)
    return shell
  }

  private func rawValue(script: String) throws -> Any {
    let context = try FrameworkFixture.context(script: script)
    let encoded = context.evaluateScript("JSON.stringify(shaarInspectFramework(globalThis))")
    try FrameworkFixture.requireClean(context)
    let text = try XCTUnwrap(encoded?.toString())
    return try JSONSerialization.jsonObject(with: Data(text.utf8))
  }

  private func openShell(url: String) throws -> OpenShell {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: try XCTUnwrap(URL(string: url)))
    let inspector = InspectorModel(target: target, engine: nil)
    let model = ShaarDevToolsModel(target: target)
    model.open(inspector: inspector)
    return OpenShell(model: model, inspector: inspector)
  }

  private func panel(_ shell: OpenShell) -> some View {
    ShaarDevToolsPanel(model: shell.model, inspector: shell.inspector, openChromium: {})
  }

  private func capture<V: View>(
    _ panel: V, named name: String, scheme: ColorScheme, appearance: NSAppearance.Name,
    root: URL
  ) throws {
    let view =
      panel
      .frame(width: 1040, height: 440)
      .background(Color(nsColor: .windowBackgroundColor))
      .environment(\.colorScheme, scheme)
    let image = try VisualCapture.renderOffscreen(
      view, size: NSSize(width: 1040, height: 440), appearance: appearance,
      to: root.appending(path: "\(name).png"))
    XCTAssertEqual(image.pixelsWide, 1040)
    XCTAssertEqual(image.pixelsHigh, 440)
  }
}

private struct OpenShell {
  let model: ShaarDevToolsModel
  let inspector: InspectorModel
}
