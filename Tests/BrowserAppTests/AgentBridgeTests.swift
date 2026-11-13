// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Foundation
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor
final class AgentBridgeTests: XCTestCase {
  func testOlderStatusRefreshCannotReplaceTheLatestReply() {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.test/")!)
    var replies: [AgentBridgeModel.Reply] = []
    let model = AgentBridgeModel(target: target) { operation, _, reply in
      if operation == .status { replies.append(reply) }
    }

    model.refresh()
    model.refresh()
    replies[1](
      [
        "schemaVersion": 1, "enabled": true, "port": 9222,
        "wsEndpoint": "ws://127.0.0.1:9222/devtools/browser/id", "connectionCount": 1,
      ], nil)
    replies[0](["schemaVersion": 1, "enabled": false, "port": 0, "connectionCount": 0], nil)

    XCTAssertTrue(model.status.enabled)
    XCTAssertTrue(model.isConnected)
  }

  func testAgentBridgeSectionTitlesAreVoiceOverHeadings() {
    XCTAssertEqual(AgentBridgeAccessibility.headingTraits, .isHeader)
  }

  func testAgentBridgeExplainsThatItNeedsAWebPage() {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(fileURLWithPath: "/tmp/example.html"))
    let model = AgentBridgeModel(target: target) { _, _, _ in
      XCTFail("A non-web target must not call the Agent Bridge")
    }

    model.enable()

    XCTAssertEqual(model.failure, ShellL10n.string("Agent control requires a web page."))
  }

  func testBackendFailuresUseLocalizedRecoveryCopy() {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.test/")!)
    let backendError = NSError(
      domain: "AgentBridgeTests", code: 9,
      userInfo: [NSLocalizedDescriptionKey: "Raw English agent bridge error."])
    let expected = ShellL10n.string("The Agent Bridge request failed. Try again.")

    let statusModel = AgentBridgeModel(target: target) { _, _, reply in
      reply(nil, backendError)
    }
    statusModel.refresh()
    XCTAssertEqual(statusModel.failure, expected)

    let enableModel = AgentBridgeModel(target: target) { _, _, reply in
      reply(nil, backendError)
    }
    enableModel.enable()
    XCTAssertEqual(enableModel.failure, expected)

    let disconnectModel = AgentBridgeModel(target: target) { operation, _, reply in
      if operation == .enable {
        reply(
          [
            "schemaVersion": 1, "enabled": true, "port": 9222,
            "wsEndpoint": "ws://127.0.0.1:9222/devtools/browser/id",
            "connectionCount": 0, "token": String(repeating: "a", count: 43),
          ], nil)
      } else {
        reply(nil, backendError)
      }
    }
    disconnectModel.enable()
    disconnectModel.disable()
    XCTAssertEqual(disconnectModel.failure, expected)
    XCTAssertTrue(disconnectModel.revocationUnconfirmed)
  }

  func testStatusRejectsSecretsAndInvalidPorts() throws {
    XCTAssertThrowsError(
      try AgentBridgeStatus.decode([
        "schemaVersion": 1, "enabled": true, "port": 9222,
        "wsEndpoint": "ws://127.0.0.1:9222/devtools/browser/id",
        "connectionCount": 1, "token": "leak",
      ]))
    XCTAssertThrowsError(
      try AgentBridgeStatus.decode([
        "schemaVersion": 1, "enabled": true, "port": 0, "connectionCount": 0,
      ]))
    XCTAssertThrowsError(
      try AgentBridgeStatus.decode([
        "schemaVersion": 1, "enabled": true, "port": 9222,
        "wsEndpoint": "ws://evil.test:9222/devtools/browser/id", "connectionCount": 0,
      ]))
    XCTAssertThrowsError(
      try AgentBridgeStatus.decode([
        "schemaVersion": 1, "enabled": false, "port": 9222,
        "connectionCount": 1,
      ]))
  }

  func testStatusRejectsNestedAndTraversalWebSocketPaths() {
    for path in ["/devtools/browser/../json/version", "/devtools/browser/id/extra"] {
      XCTAssertThrowsError(
        try AgentBridgeStatus.decode([
          "schemaVersion": 1, "enabled": true, "port": 9222,
          "wsEndpoint": "ws://127.0.0.1:9222\(path)", "connectionCount": 1,
        ]))
    }
    XCTAssertNoThrow(
      try AgentBridgeStatus.decode([
        "schemaVersion": 1, "enabled": true, "port": 9222,
        "wsEndpoint": "ws://127.0.0.1:9222/devtools/browser/id_123-abc", "connectionCount": 1,
      ]))
  }

  func testConnectionStateAndTargetChangeClearCredential() throws {
    let first = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.test/a")!)
    let model = AgentBridgeModel(
      target: first,
      request: { operation, _, reply in
        guard operation == .enable else { return }
        reply(
          [
            "schemaVersion": 1, "enabled": true, "port": 9222,
            "wsEndpoint": "ws://127.0.0.1:9222/devtools/browser/id",
            "connectionCount": 1, "token": String(repeating: "a", count: 43),
          ], nil)
      })
    model.enable()
    XCTAssertTrue(model.isConnected)
    XCTAssertTrue(model.hasOneTimeToken)
    let token = String(repeating: "a", count: 43)
    XCTAssertEqual(model.connections.map(\.title), ["Local agent 1"])
    XCTAssertTrue(
      model.setupCommand(for: .claude)?.contains("--wsEndpoint=ws://127.0.0.1:9222") == true)
    XCTAssertTrue(
      model.setupCommand(for: .codex)?.contains("--wsHeaders='{\"Authorization\":\"Bearer ") == true
    )
    let cursor = try XCTUnwrap(model.setupCommand(for: .cursor))
    let cursorJSON = try XCTUnwrap(cursor.data(using: .utf8))
    let cursorObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: cursorJSON) as? [String: Any])
    let servers = try XCTUnwrap(cursorObject["mcpServers"] as? [String: Any])
    let shaar = try XCTUnwrap(servers["shaar-agent"] as? [String: Any])
    let args = try XCTUnwrap(shaar["args"] as? [String])
    XCTAssertTrue(args.contains("--wsEndpoint=ws://127.0.0.1:9222/devtools/browser/id"))
    XCTAssertTrue(args.contains { $0.contains(token) })
    XCTAssertEqual(
      model.documentedInvocation,
      "npx -y chrome-devtools-mcp@latest --wsEndpoint=ws://127.0.0.1:9222/devtools/browser/id --wsHeaders='{\"Authorization\":\"Bearer <token>\"}'"
    )
    XCTAssertFalse(model.documentedInvocation?.contains(token) == true)
    model.receive(enabled: true, connectionCount: 2)
    XCTAssertEqual(model.connections.map(\.title), ["Local agent 1", "Local agent 2"])
    model.update(
      target: SiteControlTarget(
        tabID: first.tabID, profileID: first.profileID,
        url: URL(string: "https://other.test/")!), committed: true)
    XCTAssertTrue(model.needsBanner)
    XCTAssertTrue(model.revocationUnconfirmed)
    XCTAssertFalse(model.hasOneTimeToken)
  }

  func testClosingBridgeCancelsItsClipboardCleanup() async throws {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.test/")!)
    let bridge = AgentBridgeModel(target: target) { operation, _, reply in
      guard operation == .enable else { return }
      reply(
        [
          "schemaVersion": 1, "enabled": true, "port": 9222,
          "wsEndpoint": "ws://127.0.0.1:9222/devtools/browser/id",
          "connectionCount": 0, "token": String(repeating: "a", count: 43),
        ], nil)
    }
    bridge.enable()
    XCTAssertTrue(bridge.hasOneTimeToken)
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("AgentBridgeTests-\(UUID())"))
    bridge.copySetup(for: .claude, pasteboard: pasteboard, clearAfter: .milliseconds(20))
    let copiedCommand = try XCTUnwrap(pasteboard.string(forType: .string))

    bridge.close()
    try await Task.sleep(for: .milliseconds(60))

    XCTAssertEqual(pasteboard.string(forType: .string), copiedCommand)
  }

  func testNavigationDuringEnableRevokesLateGrant() {
    let first = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.test/a")!)
    var pending: AgentBridgeModel.Reply?
    var operations: [AgentBridgeOperation] = []
    let model = AgentBridgeModel(target: first) { operation, _, reply in
      operations.append(operation)
      if operation == .enable { pending = reply }
    }
    model.enable()
    model.update(
      target: SiteControlTarget(
        tabID: first.tabID, profileID: first.profileID,
        url: URL(string: "https://other.test/")!), committed: true)
    pending?(
      [
        "schemaVersion": 1, "enabled": true, "port": 9222,
        "wsEndpoint": "ws://127.0.0.1:9222/devtools/browser/id",
        "connectionCount": 0, "token": String(repeating: "a", count: 43),
      ], nil)
    XCTAssertEqual(operations, [.enable, .disable])
    XCTAssertFalse(model.status.enabled)
    XCTAssertFalse(model.hasOneTimeToken)
  }

  func testOlderStatusRefreshCannotOverwriteTheLatestReply() {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.test/")!)
    var replies: [AgentBridgeModel.Reply] = []
    let model = AgentBridgeModel(target: target) { operation, _, reply in
      if operation == .status { replies.append(reply) }
    }

    model.refresh()
    model.refresh()
    replies[1](
      [
        "schemaVersion": 1, "enabled": true, "port": 9222,
        "wsEndpoint": "ws://127.0.0.1:9222/devtools/browser/id", "connectionCount": 2,
      ], nil)
    replies[0](
      ["schemaVersion": 1, "enabled": false, "connectionCount": 0], nil)

    XCTAssertTrue(model.status.enabled)
    XCTAssertEqual(model.status.connectionCount, 2)
  }

  func testFailedDisconnectKeepsWarningUntilConfirmed() {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.test/")!)
    var disableReply: AgentBridgeModel.Reply?
    let model = AgentBridgeModel(target: target) { operation, _, reply in
      if operation == .enable {
        reply(
          [
            "schemaVersion": 1, "enabled": true, "port": 9222,
            "wsEndpoint": "ws://127.0.0.1:9222/devtools/browser/id",
            "connectionCount": 1, "token": String(repeating: "a", count: 43),
          ], nil)
      } else if operation == .disable {
        disableReply = reply
      }
    }
    model.enable()
    model.disable()
    XCTAssertTrue(model.needsBanner)
    XCTAssertTrue(model.revocationUnconfirmed)
    disableReply?(nil, AgentBridgeFailure.invalidReply)
    XCTAssertTrue(model.needsBanner)
    model.disable()
    disableReply?(["schemaVersion": 1], nil)
    XCTAssertFalse(model.needsBanner)
  }

  func testOlderRevocationFailureCannotClearNewerPendingRevocation() {
    let first = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.test/")!)
    var disableReplies: [AgentBridgeModel.Reply] = []
    let model = AgentBridgeModel(target: first) { operation, _, reply in
      if operation == .enable {
        reply(
          [
            "schemaVersion": 1, "enabled": true, "port": 9222,
            "wsEndpoint": "ws://127.0.0.1:9222/devtools/browser/id",
            "connectionCount": 1, "token": String(repeating: "a", count: 43),
          ], nil)
      } else if operation == .disable {
        disableReplies.append(reply)
      }
    }

    model.enable()
    model.disable()
    model.update(
      target: SiteControlTarget(
        tabID: first.tabID, profileID: first.profileID,
        url: URL(string: "https://other.test/")!), committed: true)
    XCTAssertEqual(disableReplies.count, 2)

    disableReplies[0](nil, AgentBridgeFailure.invalidReply)
    XCTAssertTrue(model.busy)
    XCTAssertTrue(model.revocationUnconfirmed)
    XCTAssertNil(model.failure)

    disableReplies[1](["schemaVersion": 1], nil)
    XCTAssertFalse(model.needsBanner)
  }

  func testOffscreenBeforeAndAfterScreenshots() throws {
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.test/")!)
    let inspector = InspectorModel(target: target, engine: nil)
    inspector.open()
    defer { inspector.close() }
    let bridge = AgentBridgeModel(target: target) { operation, _, reply in
      if operation == .enable {
        reply(
          [
            "schemaVersion": 1, "enabled": true, "port": 9222,
            "wsEndpoint": "ws://127.0.0.1:9222/devtools/browser/fixture",
            "connectionCount": 0, "token": String(repeating: "a", count: 43),
          ], nil)
      }
    }
    let before = try renderOffscreen(
      InspectorPanel(model: inspector), size: CGSize(width: 320, height: 500))
    let consent = try renderOffscreen(
      AgentBridgeControls(model: bridge), size: CGSize(width: 340, height: 180))
    bridge.enable()
    let after = try renderOffscreen(
      AgentBridgeControls(model: bridge), size: CGSize(width: 340, height: 504))
    bridge.receive(enabled: true, connectionCount: 1)
    let agents = try renderOffscreen(
      AgentBridgeControls(model: bridge), size: CGSize(width: 340, height: 530))
    let banner = try renderOffscreen(
      AgentBridgeBanner(model: bridge), size: CGSize(width: 700, height: 34))
    XCTAssertGreaterThan(before.count, 2_000)
    XCTAssertGreaterThan(consent.count, 2_000)
    XCTAssertGreaterThan(after.count, 2_000)
    XCTAssertGreaterThan(agents.count, 2_000)
    XCTAssertGreaterThan(banner.count, 1_000)
    XCTAssertTrue(NSApp.keyWindow === previous)
    if let path = ProcessInfo.processInfo.environment["SHAAR_1085_SCREENSHOT_DIR"] {
      let directory = URL(fileURLWithPath: path, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try before.write(to: directory.appending(path: "before-inspector.png"))
      try consent.write(to: directory.appending(path: "after-consent.png"))
      try after.write(to: directory.appending(path: "after-agent-controls.png"))
      try agents.write(to: directory.appending(path: "after-connected-agents.png"))
      try banner.write(to: directory.appending(path: "after-connected-banner.png"))
    }
  }

  private func renderOffscreen(_ view: some View, size: CGSize) throws -> Data {
    let window = NSWindow(
      contentRect: CGRect(origin: .zero, size: size), styleMask: [],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.backgroundColor = .windowBackgroundColor
    let hosting = NSHostingView(
      rootView: view.frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .light))
    window.contentView = hosting
    defer {
      window.contentView = nil
      window.close()
    }
    hosting.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    XCTAssertFalse(window.isVisible)
    return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
  }
}
