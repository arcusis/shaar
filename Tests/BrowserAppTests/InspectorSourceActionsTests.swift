// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

struct InspectorSourceActionsTests {
  @Test func parsesSourceLocationsAndBuildsEditorURLs() throws {
    let location = try #require(InspectorSourceLocation.parse(" /workspace/App.swift:18:4 "))
    #expect(location.path == "/workspace/App.swift")
    #expect(location.line == 18)
    #expect(location.column == 4)
    #expect(location.editorURL(.vscode)?.absoluteString == "vscode://file/workspace/App.swift:18:4")
    #expect(location.editorURL(.idea)?.scheme == "idea")
    #expect(location.editorURL(.idea)?.host == "open")
    let ideaComponents = try #require(
      location.editorURL(.idea).flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
    #expect(ideaComponents.queryItems?.map(\.name) == ["file", "line", "column"])
    #expect(location.editorURL(.showOnly) == nil)
  }

  @Test func rejectsMalformedOrUnsafeSourceLocations() {
    for value in [
      "relative/App.swift:18", "/workspace/App.swift:0", "/workspace/App.swift:18:0",
      "/workspace/App.swift:12345678", "/workspace/App.swift?secret=1:18",
      "/workspace/App.swift#fragment:18", "/workspace/App.swift:18\n/other.swift",
      "C:\\workspace\\App.swift:18", "file:///workspace/App.swift:18:4:7",
    ] {
      #expect(InspectorSourceLocation.parse(value) == nil, "\(value)")
    }
  }
}
