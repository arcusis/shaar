// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarEngineABI

private final class DOMSubmitting: ShaarDevToolsSubmitting, @unchecked Sendable {
  private let lock = NSLock()
  private var last: ShaarDevToolsRequest?
  var request: ShaarDevToolsRequest? {
    lock.lock()
    defer { lock.unlock() }
    return last
  }
  func submit(
    _ request: ShaarDevToolsRequest,
    completion: @escaping @Sendable (Result<Data, ShaarEngineError>) -> Void
  ) throws -> UInt64 {
    lock.lock()
    last = request
    lock.unlock()
    return 1
  }
}

@Suite("Shaar DOM adapter")
struct DevToolsDOMTests {
  private let scope = ShaarNavigationScope(profileID: "profile-a")

  @Test func nestedDocumentDecodesShadowRootsAndSameOriginFrameDocument() throws {
    let payload =
      try JSONSerialization.jsonObject(
        with: Data(
          ##"{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document","nodeValue":"","children":[{"nodeId":2,"nodeType":1,"nodeName":"HTML","nodeValue":"","attributes":["lang","en"],"shadowRoots":[{"nodeId":3,"nodeType":11,"nodeName":"#document-fragment","nodeValue":"","children":[{"nodeId":4,"nodeType":1,"nodeName":"BUTTON","nodeValue":""}]}],"contentDocument":{"nodeId":5,"nodeType":9,"nodeName":"#document","nodeValue":""}}]}}"##
            .utf8)) as! [String: Any]
    let snapshot = try #require(ShaarDOMSnapshot.decode(payload))
    #expect(snapshot.rootID == 1)
    #expect(snapshot.nodes.count == 5)
    #expect(snapshot.nodes.first { $0.id == 2 }?.childrenIDs == [3, 5])
    #expect(snapshot.nodes.first { $0.id == 3 }?.relation == .shadowRoot)
    #expect(snapshot.nodes.first { $0.id == 5 }?.relation == .frameDocument)
    #expect(snapshot.nodes.first { $0.id == 2 }?.attributes.first?.name == "lang")
  }

  @Test func projectedMutationRequiresExactLeaseScopeAndFields() throws {
    let payload =
      #"{"schemaVersion":1,"kind":"panelEvent","eventID":21,"leaseID":7,"data":{"parentNodeId":2,"previousNodeId":0,"node":{"nodeId":3,"nodeType":1,"nodeName":"DIV","nodeValue":"","attributes":["class","card"]},"truncated":false}}"#
    let event = ShaarCopiedEvent(
      sequence: 8, kind: 14, profileID: Data("profile-a".utf8), sessionID: Data(),
      windowID: Data("window-a".utf8), tabID: Data("tab-a".utf8),
      payloadJSON: Data(payload.utf8))
    let mutation = try #require(
      ShaarDOMEventRouter.decode(
        event, scope: scope, windowID: "window-a", tabID: "tab-a", leaseID: 7))
    guard case .childInserted(let parent, let previous, let node) = mutation.mutation else {
      Issue.record("Expected child insertion")
      return
    }
    #expect(parent == 2 && previous == 0 && node.id == 3)
    #expect(
      ShaarDOMEventRouter.decode(
        event, scope: scope, windowID: "window-a", tabID: "tab-a", leaseID: 8) == nil)
    #expect(
      ShaarDOMEventRouter.decode(
        event, scope: scope, windowID: "window-a", tabID: "tab-a", leaseID: 7,
        afterSequence: 8) == nil)
    let unknown = ShaarCopiedEvent(
      sequence: 9, kind: 14, profileID: Data("profile-a".utf8), sessionID: Data(),
      windowID: Data("window-a".utf8), tabID: Data("tab-a".utf8),
      payloadJSON: Data(
        payload.replacingOccurrences(
          of: #""truncated":false"#, with: #""truncated":false,"secret":"x""#
        ).utf8))
    #expect(
      ShaarDOMEventRouter.decode(
        unknown, scope: scope, windowID: "window-a", tabID: "tab-a", leaseID: 7) == nil)
  }

  @Test func fixedDOMCommandsUseInspectorCapability() throws {
    let submitting = DOMSubmitting()
    let adapter = try #require(ShaarDevToolsAdapter(implementation: .shaar, engine: submitting))
    let commands: [ShaarDevToolsCommand] = [
      .domRequestChildNodes, .domSetAttributeValue, .domRemoveAttribute,
      .domSetNodeValue, .domRemoveNode, .domSetOuterHTML, .domMoveTo,
      .domMarkUndoableState, .domUndo, .domPerformSearch,
      .domGetSearchResults, .domDiscardSearchResults,
      .overlayHighlightNode, .overlayHideHighlight, .domResolveNode,
      .runtimeCallFunctionOn, .domGetOuterHTML,
    ]
    for command in commands {
      _ = try adapter.call(
        capability: .inspector, command: command, scope: scope,
        windowID: "window-a", tabID: "tab-a"
      ) { _ in }
      let data = try #require(submitting.request?.payload)
      let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(payload["command"] as? UInt32 == command.rawValue)
      #expect(payload["capability"] as? UInt32 == 1)
      #expect(throws: ShaarEngineError.self) {
        try adapter.call(
          capability: .developer, command: command, scope: scope,
          windowID: "window-a", tabID: "tab-a"
        ) { _ in }
      }
    }
  }
}
