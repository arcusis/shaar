// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite struct InspectorAgentTests {
  @Test func compactPayloadIsBoundedAndOmitsPrivateData() {
    var context = InspectorAIFormatterTests.context()
    context.url = "https://user:password@example.com/page?token=secret#fragment"
    context.text = String(repeating: "Public text ", count: 1000)
    context.html = .init(
      tag: "button",
      children: [
        .init(tag: "input", attributes: [.init(name: "value", value: "hidden-secret")]),
        .init(text: String(repeating: "Safe ", count: 1000)),
      ])
    let payload = InspectorAgentPayload.markdown(
      context, locator: "page.getByRole(\"button\", { name: \"Save\" })")
    #expect(payload.utf8.count <= 4096)
    #expect(payload.contains("https://example.com/page"))
    #expect(payload.contains("React: SaveButton"))
    #expect(payload.contains("/src/SaveButton.tsx:12"))
    #expect(payload.contains("page.getByRole"))
    #expect(payload.contains("Role: button"))
    #expect(payload.contains("Box: 180 × 48"))
    #expect(!payload.contains("token=secret"))
    #expect(!payload.contains("hidden-secret"))
    #expect(!payload.contains("<input"))
    #expect(!payload.contains("Full computed styles"))
  }

  @Test func sourceLocationAndEditorURLValidateLocalFiles() {
    let source = InspectorSourceLocation.parse("/src/Card.tsx:12:3")
    #expect(source?.path == "/src/Card.tsx")
    #expect(source?.line == 12)
    #expect(source?.column == 3)
    #expect(InspectorSourceLocation.parse("https://example.com/app.js:12") == nil)
    #expect(InspectorSourceLocation.parse("javascript:alert(1)") == nil)
    #expect(InspectorSourceLocation.parse("/src/Card.tsx:0") == nil)
    #expect(source?.editorURL(.vscode)?.absoluteString == "vscode://file/src/Card.tsx:12:3")
    #expect(source?.editorURL(.cursor)?.absoluteString == "cursor://file/src/Card.tsx:12:3")
    #expect(source?.editorURL(.zed)?.absoluteString == "zed://file/src/Card.tsx:12:3")
    #expect(
      source?.editorURL(.idea)?.absoluteString == "idea://open?file=/src/Card.tsx&line=12&column=3")
    #expect(source?.editorURL(.showOnly) == nil)
    #expect(InspectorSourceLocation.parse("file:///src/Card.tsx:12")?.line == 12)
  }
}
