// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarNetworkVisualTests: XCTestCase {
  func testNetworkStatesRenderOffscreenInBothAppearances() async throws {
    guard ProcessInfo.processInfo.environment["SHAAR_NETWORK_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen Network capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1124")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let rulesEvidence = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1157")
    try FileManager.default.createDirectory(at: rulesEvidence, withIntermediateDirectories: true)
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/dashboard")!)
    let inspector = InspectorModel(target: target, engine: nil)
    let requestID = "orders-1"
    let fixture: [ShaarDevToolsEvent] = [
      .network(
        .init(
          id: UUID(), method: "GET", url: "http://localhost:3000/dashboard", status: 200,
          mimeType: "text/html", encodedBytes: 4_096, time: 0.18)),
      .network(
        .init(
          id: UUID(), method: "GET", url: "http://localhost:3000/app.js", status: 200,
          mimeType: "application/javascript", encodedBytes: 24_576, time: 0.22)),
      .network(
        .init(
          id: UUID(), method: "GET", url: "http://localhost:3000/logo.svg", status: 200,
          mimeType: "image/svg+xml", encodedBytes: 2_048, time: 0.28)),
      .network(
        .init(
          id: UUID(), method: "POST", url: "http://localhost:3000/api/orders?view=recent",
          status: nil, requestID: requestID, phase: .request, time: 0.3,
          requestHeaders: [.init(name: "Content-Type", value: "application/json")],
          payload: "{\"limit\":10}")),
      .network(
        .init(
          id: UUID(), method: "", url: "", status: 503, requestID: requestID,
          phase: .response, mimeType: "application/json", time: 0.48,
          responseHeaders: [.init(name: "Content-Type", value: "application/json")],
          responseBody: "{\"error\":\"Service unavailable\",\"retry\":true}")),
      .network(
        .init(
          id: UUID(), method: "", url: "", status: nil, requestID: requestID,
          phase: .finished, encodedBytes: 672, time: 0.51)),
    ]
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      try capture(
        LegacyNetworkPending(), named: "before-network-\(suffix)", scheme: scheme,
        appearance: appearance, root: root)
      let unavailable = ShaarDevToolsModel(target: target)
      unavailable.section = .network
      unavailable.open(inspector: inspector)
      try capture(
        ShaarDevToolsPanel(model: unavailable, inspector: inspector, openChromium: {}),
        named: "after-network-unavailable-\(suffix)", scheme: scheme,
        appearance: appearance, root: root)
      unavailable.close()

      let empty = ShaarDevToolsModel(
        target: target, transport: ShaarDevToolsFixtureTransport(fixture: []))
      empty.section = .network
      empty.open(inspector: inspector)
      for _ in 0..<30 where !empty.streamAvailable { await Task.yield() }
      XCTAssertTrue(empty.streamAvailable)
      try capture(
        ShaarDevToolsPanel(model: empty, inspector: inspector, openChromium: {}),
        named: "after-network-empty-\(suffix)", scheme: scheme,
        appearance: appearance, root: root)
      empty.close()

      let populated = ShaarDevToolsModel(
        target: target, transport: ShaarDevToolsFixtureTransport(fixture: fixture))
      populated.section = .network
      populated.open(inspector: inspector)
      for _ in 0..<30 where populated.events.count < fixture.count { await Task.yield() }
      XCTAssertEqual(populated.events.count, fixture.count)
      try capture(
        ShaarDevToolsPanel(model: populated, inspector: inspector, openChromium: {}),
        named: "after-network-results-\(suffix)", scheme: scheme,
        appearance: appearance, root: root)
      populated.network.selectedID = requestID
      populated.network.statusFilter = .serverError
      populated.network.conditions.throttle = .slow3G
      populated.network.conditions.cacheDisabled = true
      populated.network.detailTab = .preview
      try capture(
        ShaarDevToolsPanel(model: populated, inspector: inspector, openChromium: {}),
        named: "after-network-tools-\(suffix)", scheme: scheme,
        appearance: appearance, root: root)
      populated.network.statusFilter = .any
      populated.network.conditions.throttle = .none
      populated.network.conditions.cacheDisabled = false
      for tab in ShaarNetworkModel.DetailTab.allCases {
        populated.network.detailTab = tab
        try capture(
          ShaarDevToolsPanel(model: populated, inspector: inspector, openChromium: {}),
          named: "after-network-\(tab.rawValue.lowercased())-\(suffix)", scheme: scheme,
          appearance: appearance, root: root)
      }
      populated.close()

      let rulesTransport = ShaarNetworkRulesFixtureTransport()
      let rulesRoot = FileManager.default.temporaryDirectory
        .appending(path: "shaar-network-rules-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: rulesRoot) }
      let withRules = ShaarDevToolsModel(
        target: target,
        transport: ShaarDevToolsFixtureTransport(fixture: fixture),
        rulesTransport: rulesTransport,
        rulesStore: ShaarNetworkRuleStore(root: rulesRoot))
      withRules.section = .network
      withRules.open(inspector: inspector)
      for _ in 0..<30 where withRules.events.count < fixture.count { await Task.yield() }
      let request = try XCTUnwrap(
        withRules.network.requests(from: withRules.events)
          .first { $0.id == requestID })
      withRules.network.selectedID = requestID
      withRules.rules.create(from: request)
      withRules.rules.draft?.enabled = true
      withRules.rules.draft?.status = 200
      withRules.rules.draft?.bodyText = "{\"orders\":[],\"source\":\"local fixture\"}"
      try await withRules.rules.saveDraft()
      let saved = try XCTUnwrap(withRules.rules.rules.first)
      withRules.rules.edit(saved)
      try capture(
        ShaarDevToolsPanel(model: withRules, inspector: inspector, openChromium: {}),
        named: "after-network-rules-\(suffix)", scheme: scheme,
        appearance: appearance, root: rulesEvidence)
      let projectFolder = rulesRoot.appending(path: "local-dashboard")
      try FileManager.default.createDirectory(
        at: projectFolder, withIntermediateDirectories: true)
      try await withRules.rules.useProjectRoot(projectFolder.path)
      withRules.rules.create(from: request)
      withRules.rules.draft?.enabled = true
      withRules.rules.draft?.bodyText = "{\"orders\":[],\"source\":\"local fixture\"}"
      try await withRules.rules.saveDraft()
      withRules.rules.edit(try XCTUnwrap(withRules.rules.rules.first))
      try capture(
        ShaarDevToolsPanel(model: withRules, inspector: inspector, openChromium: {}),
        named: "project-network-rules-\(suffix)", scheme: scheme,
        appearance: appearance, root: rulesEvidence)
      withRules.close()

      let unavailableRules = ShaarDevToolsModel(
        target: target, transport: ShaarDevToolsFixtureTransport(fixture: fixture))
      unavailableRules.section = .network
      unavailableRules.open(inspector: inspector)
      for _ in 0..<30 where unavailableRules.events.count < fixture.count { await Task.yield() }
      unavailableRules.rules.showingRules = true
      try capture(
        ShaarDevToolsPanel(model: unavailableRules, inspector: inspector, openChromium: {}),
        named: "after-network-rules-unavailable-\(suffix)", scheme: scheme,
        appearance: appearance, root: rulesEvidence)
      unavailableRules.close()
    }
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  private func capture<V: View>(
    _ panel: V, named name: String, scheme: ColorScheme, appearance: NSAppearance.Name,
    root: URL
  ) throws {
    let view = VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        Text("localhost:3000/dashboard")
          .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
        Divider()
        Text("Dashboard").font(.system(size: 24, weight: .semibold))
        Text("Inspect the local build while you work.")
          .font(.system(size: 13)).foregroundStyle(.secondary)
        Spacer()
      }
      .padding(22)
      .frame(height: 180)
      Divider()
      panel.frame(height: 439)
    }
    .frame(width: 1040, height: 620)
    .background(Color(nsColor: .textBackgroundColor))
    .environment(\.colorScheme, scheme)
    let image = try VisualCapture.renderOffscreen(
      view, size: NSSize(width: 1040, height: 620), appearance: appearance,
      to: root.appending(path: "\(name).png"))
    XCTAssertEqual(image.pixelsWide, 1040)
    XCTAssertEqual(image.pixelsHigh, 620)
  }
}

private struct LegacyNetworkPending: View {
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 20) {
        Image(systemName: "chevron.left.forwardslash.chevron.right")
        Text("Elements").foregroundStyle(.secondary)
        Text("Console").foregroundStyle(.secondary)
        Text("Network").fontWeight(.semibold)
        Spacer()
        Image(systemName: "ellipsis")
        Image(systemName: "xmark")
      }
      .font(.system(size: 11))
      .padding(.horizontal, 14)
      .frame(height: 36)
      Divider()
      Text("Network requests will appear here when the engine stream is available")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      Text("›  Console command line arrives with the Console panel")
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .frame(height: 34)
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }
}
