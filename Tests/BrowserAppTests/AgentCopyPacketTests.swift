// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import JavaScriptCore
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct AgentCopyPacketTests {
  @Test func redactsSecretsAndKeepsOrdinaryText() throws {
    let jwt =
      "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
    let html = """
      <div>Hi<script>secret()</script><input value="secret-value"><p>ada@example.com \(jwt)</p></div>
      """
    let built = try build([
      "page": [
        "url": "https://user:secret@example.com/path?q=1&token=abcdef123",
        "html": html,
        "source": "",
        "scope": "page",
        "consoleErrors": ["Bearer fixture-token"],
        "failedRequests": [
          [
            "method": "GET",
            "url": "https://example.com/missing",
            "status": 404,
            "requestHeaders": [
              ["name": "Authorization", "value": "Bearer fixture-token"],
              ["name": "Cookie", "value": "session=abc"],
              ["name": "Proxy-Authorization", "value": "Basic abcdefgh"],
            ],
            "responseHeaders": [
              ["name": "Set-Cookie", "value": "secret=cookie-value"]
            ],
          ]
        ],
        "consoleRecording": true,
      ],
      "matchedStyles": [:],
      "screenshotBytes": 0,
    ])
    let markdown = built.markdown
    #expect(!markdown.contains("fixture-token"))
    #expect(!markdown.contains("secret-value"))
    #expect(!markdown.contains("secret()"))
    #expect(!markdown.contains("session=abc"))
    #expect(!markdown.contains("cookie-value"))
    #expect(!markdown.contains(jwt))
    #expect(markdown.contains("ada@example.com"))
    #expect(markdown.contains("q=1"))
    #expect(markdown.contains("token=[redacted]"))
    #expect(markdown.contains("[redacted]@example.com"))
    #expect(markdown.contains("Authorization: [redacted]"))
    #expect(markdown.contains("Cookie: [redacted]"))
    #expect(markdown.contains("Set-Cookie: [redacted]"))
    #expect(markdown.contains("Proxy-Authorization: [redacted]"))
    #expect(markdown.contains("Bearer [redacted]"))
    #expect(AgentCopyGuard.accepts(markdown))
    #expect(!markdown.contains("iVBOR"))
  }

  @Test func laterRuleWinsTheColor() throws {
    let built = try build(
      [
        "page": [
          "url": "https://example.com/card",
          "html": "<div id=\"card\">Card title</div>",
          "source": "/src/Card.tsx:12",
          "scope": "element",
          "consoleErrors": [],
          "failedRequests": [],
          "consoleRecording": false,
        ],
        "matchedStyles": [
          "matchedCSSRules": [
            [
              "rule": [
                "selectorList": ["selectors": [["text": "#card"]]],
                "origin": "regular",
                "style": [
                  "cssProperties": [
                    ["name": "color", "value": "red"],
                    ["name": "padding", "value": "8px"],
                    ["name": "background", "value": "white", "disabled": true],
                  ]
                ],
              ]
            ],
            [
              "rule": [
                "selectorList": ["selectors": [["text": "#card.special"]]],
                "origin": "regular",
                "style": ["cssProperties": [["name": "color", "value": "blue"]]],
              ]
            ],
          ]
        ],
        "screenshotBytes": 32,
      ], png: Data(count: 32))
    #expect(built.markdown.contains("color: blue"))
    #expect(built.markdown.contains("padding: 8px"))
    #expect(!built.markdown.contains("color: red"))
    #expect(!built.markdown.contains("background"))
    #expect(built.markdown.contains("/src/Card.tsx:12"))
    #expect(built.markdown.contains("none recorded (no buffer was running)"))
    #expect(built.markdown.contains("PNG attached, 32 bytes."))
    #expect(built.bytes == built.markdown.utf8.count + 32)
    #expect(built.ruleCount == 2)
  }

  @Test func boundsThePacketAndDropsControls() throws {
    let html =
      String(repeating: "a", count: 10_000)
      + "<script>secret()</script><input value=\"secret-value\">"
    let built = try build([
      "page": [
        "url": "https://example.com/",
        "html": html,
        "scope": "page",
        "consoleErrors": [],
        "failedRequests": [],
        "consoleRecording": false,
      ],
      "stylesOmitted": true,
      "matchedStyles": [:],
      "screenshotBytes": 0,
    ])
    #expect(built.markdown.utf8.count <= 12_000)
    #expect(built.markdown.contains("styles omitted"))
    #expect(built.markdown.contains("Screenshot: omitted."))
    #expect(!built.markdown.contains("secret-value"))
    #expect(!built.markdown.contains("<script"))
    #expect(!built.markdown.contains("<input"))
    let trimmed = try trim(
      "<div>Hi<script>secret()</script><input value=\"secret-value\"><b>Ok</b></div>")
    #expect(trimmed.contains("Ok"))
    #expect(!trimmed.contains("secret"))
    #expect(!trimmed.contains("<input"))
    #expect(!trimmed.contains("<script"))
  }

  @Test func guardRejectsUnredactedSecrets() {
    #expect(AgentCopyGuard.accepts("Authorization: [redacted]\n"))
    #expect(!AgentCopyGuard.accepts("Authorization: secret\n"))
    #expect(!AgentCopyGuard.accepts("Set-Cookie: secret=cookie-value\n"))
    #expect(AgentCopyGuard.accepts("note bearer [redacted]\n"))
    #expect(!AgentCopyGuard.accepts("note bearer abcdefghij\n"))
    #expect(AgentCopyGuard.accepts("https://x/?token=[redacted]\n"))
    #expect(!AgentCopyGuard.accepts("https://x/?token=abcdef\n"))
    #expect(AgentCopyGuard.accepts("ada@example.com\n"))
  }

  @Test func sizeTextIsLocaleStable() {
    #expect(AgentCopySize.text(for: 0) == "0 B")
    #expect(AgentCopySize.text(for: 512) == "512 B")
    #expect(AgentCopySize.text(for: 1024) == "1.0 KB")
    #expect(AgentCopySize.text(for: 1536) == "1.5 KB")
    #expect(AgentCopySize.text(for: 20_480) == "20 KB")
  }

  @Test func selectorAllowListRejectsFreeText() {
    #expect(AgentCopySelector.accepted("#card") == "#card")
    #expect(AgentCopySelector.accepted("#A_1") == "#A_1")
    #expect(AgentCopySelector.accepted("div") == nil)
    #expect(AgentCopySelector.accepted("#") == nil)
    #expect(AgentCopySelector.accepted("#ok card") == nil)
    #expect(AgentCopySelector.accepted("body #card") == nil)
  }

  @Test func scriptMakesNoNetworkCalls() throws {
    let source = try AgentCopyScript.source()
    #expect(!source.contains("fetch("))
    #expect(!source.contains("XMLHttpRequest"))
    #expect(!source.contains("WebSocket"))
    #expect(source.contains("ShaarAgentCopy.buildJSON"))
  }

  @Test func panelRendersOffscreenInBothAppearances() throws {
    let ready = AgentCopyPanelState(
      scope: .element, busy: false, sizeText: "1.5 KB", byteCount: 1536, failure: nil, notice: nil,
      canCopy: true,
      preview:
        "# Agent packet\nScope: element\nPage: https://example.com/\n## Source\n/src/Card.tsx:12\n",
      ruleCount: 2, errorCount: 1, requestCount: 1, consoleRecording: true, stylesOmitted: false,
      source: "/src/Card.tsx:12", screenshotBytes: 128)
    let png = try VisualCapture.pngOffscreen(
      panel(ready), size: NSSize(width: 420, height: 520))
    #expect(png.count > 100)
    let directory = URL(filePath: "build/agent-copy-panels")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var building = AgentCopyPanelState.empty
    building.busy = true
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      let suffix = appearance == .aqua ? "light" : "dark"
      _ = try VisualCapture.renderOffscreen(
        panel(ready), size: NSSize(width: 420, height: 520), appearance: appearance,
        to: directory.appending(path: "panel-\(suffix).png"))
      _ = try VisualCapture.renderOffscreen(
        panel(building), size: NSSize(width: 420, height: 520), appearance: appearance,
        to: directory.appending(path: "panel-building-\(suffix).png"))
    }
  }

  private func panel(_ state: AgentCopyPanelState) -> some View {
    AgentCopyPanel(
      state: state, onScope: { _ in }, onCopy: {}, onHand: {}, onRefresh: {}, onClose: {})
  }

  private func build(_ input: [String: Any], png: Data? = nil) throws -> AgentCopyBuilt {
    try AgentCopyEngine.build(script: AgentCopyScript.source(), input: input, png: png)
  }

  private func trim(_ html: String) throws -> String {
    let context = JSContext()
    var thrown: String?
    context?.exceptionHandler = { _, value in thrown = value?.toString() }
    context?.evaluateScript(try AgentCopyScript.source())
    context?.setObject(html, forKeyedSubscript: "shaarAgentCopyInput" as NSString)
    let value = context?.evaluateScript("ShaarAgentCopy.trimHTML(shaarAgentCopyInput)")?.toString()
    if let thrown { throw InspectorFailure(thrown) }
    return value ?? ""
  }
}
