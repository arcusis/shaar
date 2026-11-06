// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class DeveloperToolsPolishVisualTests: XCTestCase {
  func testDeveloperSurfacesRenderOffscreenInLightAndDark() throws {
    _ = NSApplication.shared
    let previousKeyWindow = NSApp.keyWindow
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/dashboard")!)
    let inspector = InspectorModel(target: target, engine: nil)
    inspector.open()
    defer { inspector.close() }
    let selection = InspectorPanelTests.fixtureSelection()
    try inspector.receive(selection)
    let page = DevelopmentPage.detect(
      url: target.url, markers: .init(resourcePaths: ["/_next/static/chunk.js"]))

    for scheme in [ColorScheme.light, .dark] {
      let bridge = makeBridge(target: target)
      try capture(
        toolbar(page: page, url: target.url), "dev-mode", scheme: scheme,
        size: CGSize(width: 760, height: 60))
      inspector.tab = .design
      inspector.presentation.copyMenuOpen = true
      try capture(InspectorPanel(model: inspector), "source-actions", scheme: scheme)
      inspector.presentation.copyMenuOpen = false
      inspector.tab = .accessibility
      try inspector.receive(InspectorPanelTests.fixtureSelection(locked: false))
      try capture(InspectorPanel(model: inspector), "audit-empty", scheme: scheme)
      try inspector.details.audit.receive(
        auditReport(), generation: inspector.documentGeneration, selectionID: nil)
      try capture(InspectorPanel(model: inspector), "audit-results", scheme: scheme)
      inspector.details.audit.reset()
      inspector.tab = .styles
      try inspector.receive(selection)
      try inspector.styles.receive(
        rules: [
          .init(
            id: 0, selector: ".save", source: "/fixture.css:1",
            declarations: [
              .init(name: "justify-content", value: "center"),
              .init(name: "z-index", value: "2"),
            ])
        ],
        computed: [
          .init(name: "display", value: "block"), .init(name: "position", value: "static"),
        ],
        inactiveHints: [
          "justify-content": "Requires a flex or grid container.",
          "z-index": "Does not apply to static elements outside flex or grid layouts.",
        ], selectionID: selection.id, generation: inspector.documentGeneration)
      try capture(
        InspectorPanel(model: inspector), "inactive-css", scheme: scheme,
        size: CGSize(width: 320, height: 760))
      try capture(
        AgentBridgeControls(model: bridge), "agent-off", scheme: scheme,
        size: CGSize(width: 320, height: 300))
      let connecting = AgentBridgeModel(target: target) { _, _, _ in }
      connecting.enable()
      XCTAssertTrue(connecting.busy)
      try capture(
        AgentBridgeControls(model: connecting), "agent-loading", scheme: scheme,
        size: CGSize(width: 320, height: 300))
      let failed = AgentBridgeModel(target: target) { operation, _, reply in
        if operation == .enable { reply(nil, AgentBridgeFailure.invalidReply) }
      }
      failed.enable()
      XCTAssertNotNil(failed.failure)
      try capture(
        AgentBridgeControls(model: failed), "agent-error", scheme: scheme,
        size: CGSize(width: 320, height: 300))
      bridge.enable()
      bridge.receive(enabled: true, connectionCount: 1)
      try capture(
        AgentBridgeControls(model: bridge), "agent-connected", scheme: scheme,
        size: CGSize(width: 320, height: 330))
      try capture(
        AgentBridgeBanner(model: bridge), "agent-banner", scheme: scheme,
        size: CGSize(width: 760, height: 34))
    }
    XCTAssertTrue(NSApp.keyWindow === previousKeyWindow)
  }

  private func toolbar(page: DevelopmentPage, url: URL) -> some View {
    HStack(spacing: 4) {
      Image(systemName: "arrow.left").frame(width: 28, height: 28)
      Image(systemName: "arrow.right").frame(width: 28, height: 28)
      Spacer()
      Text(url.absoluteString).font(.system(size: 13)).foregroundStyle(.secondary)
      Spacer()
      DevelopmentModeLabel(page: page)
      Image(systemName: "slider.horizontal.3").frame(width: 28, height: 28)
    }
    .padding(.horizontal, 6)
    .frame(height: 34)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func auditReport() -> InspectorAuditModel.Report {
    let finding = InspectorAuditModel.Finding(
      id: "image-alt:0", ruleID: "image-alt", impact: "critical",
      title: "Images must have alternate text", help: "Add an alt attribute.",
      helpURL: "https://dequeuniversity.com/rules/axe/4.14/image-alt",
      target: "#missing-alt", summary: "Element has no alt attribute")
    return .init(scope: "page", violations: 1, incomplete: 1, findings: [finding], truncated: false)
  }

  private func makeBridge(target: SiteControlTarget) -> AgentBridgeModel {
    AgentBridgeModel(target: target) { operation, _, reply in
      if operation == .enable {
        reply(
          [
            "schemaVersion": 1, "enabled": true, "port": 9222,
            "wsEndpoint": "ws://127.0.0.1:9222/devtools/browser/fixture",
            "connectionCount": 0, "token": String(repeating: "a", count: 43),
          ], nil)
      }
    }
  }

  private func capture(
    _ view: some View, _ name: String, scheme: ColorScheme,
    size: CGSize = CGSize(width: 320, height: 620)
  ) throws {
    let phase = ProcessInfo.processInfo.environment["SHAAR_DEVTOOLS_CAPTURE_PHASE"]
    let base = phase == nil ? "build/Verification/DeveloperToolsPolish" : "Evidence/issue-1069"
    let prefix = phase.map { "\($0)-" } ?? ""
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: base)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
    let image = try VisualCapture.renderOffscreen(
      view.frame(width: size.width, height: size.height).environment(\.colorScheme, scheme),
      size: size, appearance: appearance,
      to: root.appending(path: "\(prefix)\(name)-\(scheme == .dark ? "dark" : "light").png"))
    XCTAssertGreaterThan(image.pixelsWide, 200)
    XCTAssertGreaterThan(image.pixelsHigh, 30)
  }
}
