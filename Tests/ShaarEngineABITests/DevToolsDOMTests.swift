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

  @Test func decodeKeepsTheBackendNodeId() {
    let node = ShaarDOMNode.decode(
      [
        "nodeId": 4, "nodeType": 1, "nodeName": "BODY", "nodeValue": "",
        "backendNodeId": NSNumber(value: 52),
      ],
      parentID: 2, relation: .child)
    #expect(node?.backendNodeID == 52)
    let without = ShaarDOMNode.decode(
      ["nodeId": 4, "nodeType": 1, "nodeName": "BODY", "nodeValue": ""],
      parentID: 2, relation: .child)
    #expect(without?.backendNodeID == nil)
  }

  @Test func nodeRejectsBooleanIdentifiersAndTypes() {
    let base: [String: Any] = [
      "nodeId": 4, "nodeType": 1, "nodeName": "BODY", "nodeValue": "",
    ]
    for fields in [
      base.merging(["nodeId": true as Any]) { _, replacement in replacement },
      base.merging(["nodeType": true as Any]) { _, replacement in replacement },
    ] {
      #expect(ShaarDOMNode.decode(fields, parentID: nil, relation: .child) == nil)
    }
    let invalidBackendID = base.merging(["backendNodeId": true as Any]) { _, replacement in
      replacement
    }
    #expect(
      ShaarDOMNode.decode(invalidBackendID, parentID: nil, relation: .child)?.backendNodeID == nil)
  }

  @Test func projectedMutationRejectsBooleanNodeIdentifiers() {
    let base =
      #"{"schemaVersion":1,"kind":"panelEvent","eventID":21,"leaseID":7,"data":{"parentNodeId":2,"previousNodeId":0,"node":{"nodeId":3,"nodeType":1,"nodeName":"DIV","nodeValue":""},"truncated":false}}"#
    for (sequence, payload) in [
      (UInt64(10), base.replacingOccurrences(
        of: #""parentNodeId":2"#, with: #""parentNodeId":true"#)),
      (UInt64(11), base.replacingOccurrences(
        of: #""nodeId":3"#, with: #""nodeId":true"#)),
    ] {
      let event = ShaarCopiedEvent(
        sequence: sequence, kind: 14, profileID: Data("profile-a".utf8), sessionID: Data(),
        windowID: Data("window-a".utf8), tabID: Data("tab-a".utf8),
        payloadJSON: Data(payload.utf8))
      #expect(
        ShaarDOMEventRouter.decode(
          event, scope: scope, windowID: "window-a", tabID: "tab-a", leaseID: 7) == nil)
    }
  }

  @Test func nodeRejectsMalformedExplicitChildCount() {
    for invalidCount in ["unknown" as Any, true as Any] {
      let fields: [String: Any] = [
        "nodeId": 4, "nodeType": 1, "nodeName": "BODY", "nodeValue": "",
        "childNodeCount": invalidCount,
      ]
      #expect(ShaarDOMNode.decode(fields, parentID: 2, relation: .child) == nil)
    }
  }

  @Test func nodeRejectsMalformedExplicitAttributes() {
    let fields: [String: Any] = [
      "nodeId": 4, "nodeType": 1, "nodeName": "BODY", "nodeValue": "",
      "attributes": true,
    ]
    #expect(ShaarDOMNode.decode(fields, parentID: 2, relation: .child) == nil)
  }

  @Test func documentAcceptsBoundedLongInlineStyle() throws {
    func document(_ style: String) -> [String: Any] {
      [
        "root": [
          "nodeId": 1, "nodeType": 9, "nodeName": "#document", "nodeValue": "",
          "children": [
            [
              "nodeId": 2, "nodeType": 1, "nodeName": "DIV", "nodeValue": "",
              "attributes": ["style", style],
            ]
          ],
        ]
      ]
    }

    let style = String(repeating: "color:rgb(1,2,3);", count: 450)
    let snapshot = try #require(ShaarDOMSnapshot.decode(document(style)))
    #expect(snapshot.nodes.first { $0.id == 2 }?.attributes.first?.value == style)
    #expect(ShaarDOMSnapshot.decode(document(String(repeating: "x", count: 16_385))) == nil)
  }

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

  @Test func domEventsRejectBooleanSchemaVersions() {
    let payload =
      #"{"schemaVersion":true,"kind":"panelEvent","eventID":20,"leaseID":7,"data":{"truncated":false}}"#
    let event = ShaarCopiedEvent(
      sequence: 9, kind: 14, profileID: Data("profile-a".utf8), sessionID: Data(),
      windowID: Data("window-a".utf8), tabID: Data("tab-a".utf8),
      payloadJSON: Data(payload.utf8))
    #expect(
      ShaarDOMEventRouter.decode(
        event, scope: scope, windowID: "window-a", tabID: "tab-a", leaseID: 7) == nil)
  }

  @Test func domEventsRejectNumericTruncationFlags() {
    for truncated in ["0", "1"] {
      let payload =
        #"{"schemaVersion":1,"kind":"panelEvent","eventID":20,"leaseID":7,"data":{"truncated":\#(truncated)}}"#
      let event = ShaarCopiedEvent(
        sequence: 10, kind: 14, profileID: Data("profile-a".utf8), sessionID: Data(),
        windowID: Data("window-a".utf8), tabID: Data("tab-a".utf8),
        payloadJSON: Data(payload.utf8))
      #expect(
        ShaarDOMEventRouter.decode(
          event, scope: scope, windowID: "window-a", tabID: "tab-a", leaseID: 7) == nil)
    }
  }

  @Test func projectedChildrenAcceptOneHundredTwentyRows() throws {
    let nodes: [[String: Any]] = (0..<120).map { index in
      [
        "nodeId": index + 10, "nodeType": 1, "nodeName": "DIV", "nodeValue": "",
        "childNodeCount": 1,
        "children": [
          [
            "nodeId": index + 1_000, "nodeType": 3, "nodeName": "#text",
            "nodeValue": "Row \(index)",
          ]
        ],
      ]
    }
    let envelope: [String: Any] = [
      "schemaVersion": 1, "kind": "panelEvent", "eventID": 25, "leaseID": 7,
      "data": ["parentNodeId": 4, "nodes": nodes, "truncated": false],
    ]
    let event = ShaarCopiedEvent(
      sequence: 1, kind: 14, profileID: Data("profile-a".utf8), sessionID: Data(),
      windowID: Data("window-a".utf8), tabID: Data("tab-a".utf8),
      payloadJSON: try JSONSerialization.data(withJSONObject: envelope))
    let decoded = try #require(
      ShaarDOMEventRouter.decode(
        event, scope: scope, windowID: "window-a", tabID: "tab-a", leaseID: 7))
    guard case .childrenSet(let parent, let children) = decoded.mutation else {
      Issue.record("Expected child set")
      return
    }
    #expect(parent == 4)
    #expect(children.count == 240)
    let firstRow = try #require(children.first { $0.id == 10 })
    #expect(firstRow.parentID == 4)
    #expect(firstRow.childrenIDs == [1_000])
    let firstText = try #require(children.first { $0.id == 1_000 })
    #expect(firstText.parentID == 10)
    #expect(firstText.value == "Row 0")
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
