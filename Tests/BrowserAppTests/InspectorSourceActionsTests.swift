// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

struct InspectorSourceActionsTests {
  @Test @MainActor func cancelledOpenDoesNotStartInspectorRequest() async throws {
    let inspector = InspectorModel(
      target: .init(tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!),
      engine: nil)
    inspector.open()
    defer { inspector.close() }
    try inspector.receive(InspectorPanelTests.fixtureSelection())

    let opening = Task { @MainActor in await inspector.sourceActions.open() }
    opening.cancel()
    await opening.value

    #expect(inspector.sourceActions.failure == nil)
    #expect(inspector.sourceActions.location == nil)
  }

  @Test @MainActor func cancelledAgentCopyDoesNotStartInspectorRequest() async throws {
    let inspector = InspectorModel(
      target: .init(tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!),
      engine: nil)
    inspector.open()
    defer { inspector.close() }
    try inspector.receive(InspectorPanelTests.fixtureSelection())

    let copying = Task { @MainActor in await inspector.sourceActions.copyForAgent() }
    copying.cancel()
    await copying.value

    #expect(inspector.sourceActions.failure == nil)
    #expect(inspector.sourceActions.location == nil)
  }

  @Test @MainActor func backendFailuresUseLocalizedSourceRecoveryCopy() {
    let error = NSError(domain: "DevTools", code: 1, userInfo: [NSLocalizedDescriptionKey: "The engine refused."])
    #expect(
      InspectorSourceActions.failureMessage(for: error)
        == InspectorL10n.string("Could not get the source details. Try again."))
    let known = InspectorFailure("This source is no longer available.")
    #expect(
      InspectorSourceActions.failureMessage(for: known)
        == InspectorL10n.display(known.localizedDescription))
  }

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
