// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineABI
import Testing

@testable import ArcusisBrowser

@MainActor final class DOMFixtureTransport: ShaarDOMTransport {
  var continuation: AsyncStream<ShaarDOMMessage>.Continuation?
  var commands: [ShaarDOMCommand] = []
  var document: [String: Any] = [
    "root": [
      "nodeId": 1, "nodeType": 9, "nodeName": "#document", "nodeValue": "",
      "children": [
        [
          "nodeId": 2, "nodeType": 1, "nodeName": "HTML", "nodeValue": "",
          "children": [
            [
              "nodeId": 3, "nodeType": 1, "nodeName": "BODY", "nodeValue": "",
              "children": [
                [
                  "nodeId": 4, "nodeType": 1, "nodeName": "MAIN", "nodeValue": "",
                  "attributes": ["class", "dashboard", "id", "app"],
                  "children": [
                    [
                      "nodeId": 5, "nodeType": 1, "nodeName": "H1", "nodeValue": "",
                      "children": [
                        [
                          "nodeId": 6, "nodeType": 3, "nodeName": "#text", "nodeValue": "Dashboard",
                        ]
                      ],
                    ]
                  ],
                  "shadowRoots": [
                    [
                      "nodeId": 7, "nodeType": 11, "nodeName": "#document-fragment",
                      "nodeValue": "",
                      "children": [
                        [
                          "nodeId": 8, "nodeType": 1, "nodeName": "BUTTON", "nodeValue": "",
                          "attributes": ["class", "primary"],
                        ]
                      ],
                    ]
                  ],
                ]
              ],
            ]
          ],
        ]
      ],
    ]
  ]

  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarDOMMessage> {
    AsyncStream { continuation in
      self.continuation = continuation
      continuation.yield(.available)
    }
  }

  func execute(_ command: ShaarDOMCommand, for target: SiteControlTarget) async throws -> [String:
    Any]
  {
    commands.append(command)
    switch command {
    case .document: return document
    case .search: return ["searchId": "s1", "resultCount": 1]
    case .searchResults: return ["nodeIds": [4]]
    case .outerHTML: return ["outerHTML": "<main id=\"app\">Dashboard</main>"]
    default: return [:]
    }
  }

  func send(_ mutation: String, sequence: UInt64 = 2) {
    let scope = ShaarNavigationScope(profileID: "profile-a")
    let event = ShaarCopiedEvent(
      sequence: sequence, kind: 14, profileID: Data("profile-a".utf8),
      sessionID: Data(), windowID: Data("window-a".utf8),
      tabID: Data("tab-a".utf8), payloadJSON: Data(mutation.utf8))
    if let decoded = ShaarDOMEventRouter.decode(
      event, scope: scope, windowID: "window-a", tabID: "tab-a", leaseID: 7)
    {
      continuation?.yield(.event(decoded))
    }
  }
}

@Suite @MainActor struct ShaarDOMTreeModelTests {
  private func target() -> SiteControlTarget {
    SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.test")!)
  }

  @Test func pendingProductionTransportShowsNoFixtureTree() async {
    let model = ShaarDOMTreeModel(target: target(), transport: ShaarDOMPendingTransport())
    model.open()
    await Task.yield()
    #expect(!model.available)
    #expect(model.rows.isEmpty)
    model.close()
  }

  @Test func fixtureTreeSearchEditUndoAndNavigation() async throws {
    let fixture = DOMFixtureTransport()
    let model = ShaarDOMTreeModel(target: target(), transport: fixture)
    model.open()
    for _ in 0..<20 where model.rootID == nil { await Task.yield() }
    #expect(model.available && model.rootID == 1)
    #expect(model.nodes[7]?.relation == .shadowRoot)
    model.select(5)
    #expect(model.breadcrumbs.map(\.id) == [1, 2, 3, 4, 5])
    #expect(model.selector(for: 5).contains("h1:nth-of-type(1)"))
    model.search = "main"
    await model.performSearch()
    #expect(model.matches == [4])
    model.select(4)
    await model.setAttribute("class", value: "dashboard live")
    #expect(model.canUndo)
    #expect(fixture.commands.contains(.setAttribute(4, "class", "dashboard live")))
    await model.toggleClass("dashboard")
    await model.setHTML("<main>Updated</main>")
    await model.move(5, to: 4, before: 7)
    #expect(fixture.commands.contains(.setHTML(4, "<main>Updated</main>")))
    #expect(fixture.commands.contains(.move(5, 4, 7)))
    await model.undo()
    #expect(!model.canUndo)
    model.updateTarget(target(), committed: true)
    #expect(model.nodes.isEmpty && model.selectedID == nil)
    model.close()
  }

  @Test func projectedMutationChangesTreeWithoutReload() async {
    let fixture = DOMFixtureTransport()
    let model = ShaarDOMTreeModel(target: target(), transport: fixture)
    model.open()
    for _ in 0..<20 where model.rootID == nil { await Task.yield() }
    fixture.send(
      #"{"schemaVersion":1,"kind":"panelEvent","eventID":23,"leaseID":7,"data":{"nodeId":4,"name":"data-live","value":"yes","truncated":false}}"#
    )
    for _ in 0..<20
    where model.nodes[4]?.attributes.contains(where: { $0.name == "data-live" }) != true {
      await Task.yield()
    }
    #expect(
      model.nodes[4]?.attributes.contains(where: { $0.name == "data-live" && $0.value == "yes" })
        == true)
    fixture.send(
      #"{"schemaVersion":1,"kind":"panelEvent","eventID":22,"leaseID":7,"data":{"parentNodeId":4,"nodeId":5,"truncated":false}}"#,
      sequence: 3)
    for _ in 0..<20 where model.nodes[5] != nil { await Task.yield() }
    #expect(model.nodes[5] == nil && model.nodes[6] == nil)
    fixture.send(
      #"{"schemaVersion":1,"kind":"panelEvent","eventID":25,"leaseID":7,"data":{"parentNodeId":4,"nodes":[{"nodeId":9,"nodeType":1,"nodeName":"P","nodeValue":""}],"truncated":false}}"#,
      sequence: 4)
    for _ in 0..<20 where model.nodes[9] == nil { await Task.yield() }
    #expect(model.nodes[4]?.childrenIDs == [9, 7])
    #expect(model.nodes[7]?.relation == .shadowRoot)
    model.close()
  }

  @Test func malformedDocumentShowsErrorInsteadOfBlankTree() async {
    let fixture = DOMFixtureTransport()
    fixture.document = [:]
    let model = ShaarDOMTreeModel(target: target(), transport: fixture)
    model.open()
    for _ in 0..<20 where model.failure == nil { await Task.yield() }
    #expect(model.available && model.rootID == nil && model.failure != nil)
    model.close()
  }
}
