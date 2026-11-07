// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import ShaarEngineABI
import SwiftUI
import Testing

@testable import ArcusisBrowser

@MainActor final class DOMFixtureTransport: ShaarDOMTransport {
  var continuation: AsyncStream<ShaarDOMMessage>.Continuation?
  var commands: [ShaarDOMCommand] = []
  var undoDocuments: [[String: Any]] = []
  var searchNodeIDs: [Int] = [4]
  var describedNodes: [Int: [String: Any]] = [:]
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

  static func twentyThousandNodeDocument() -> [String: Any] {
    var nextID = 2
    var sections: [[String: Any]] = []
    for sectionIndex in 0..<200 {
      let sectionID = nextID
      nextID += 1
      let childCount = sectionIndex == 199 ? 98 : 99
      let children: [[String: Any]] = (0..<childCount).map { _ in
        defer { nextID += 1 }
        return ["nodeId": nextID, "nodeType": 1, "nodeName": "SPAN", "nodeValue": ""]
      }
      sections.append([
        "nodeId": sectionID, "nodeType": 1, "nodeName": "SECTION", "nodeValue": "",
        "children": children,
      ])
    }
    return [
      "root": [
        "nodeId": 1, "nodeType": 9, "nodeName": "#document", "nodeValue": "",
        "children": sections,
      ]
    ]
  }

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
    case .search: return ["searchId": "s1", "resultCount": searchNodeIDs.count]
    case .searchResults: return ["nodeIds": searchNodeIDs]
    case .describe(let id):
      if let node = describedNodes[id] { return ["node": node] }
      return [:]
    case .outerHTML: return ["outerHTML": "<main id=\"app\">Dashboard</main>"]
    case .move(let id, let parent, let before):
      if let next = ShaarDOMFixtureDocument.moving(document, id: id, to: parent, before: before) {
        undoDocuments.append(document)
        document = next
      }
      return [:]
    case .undo:
      if let previous = undoDocuments.popLast() { document = previous }
      return [:]
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

enum ShaarDOMFixtureDocument {
  static func moving(_ document: [String: Any], id: Int, to parent: Int, before: Int?)
    -> [String: Any]?
  {
    guard var root = document["root"] as? [String: Any] else { return nil }
    guard let node = detach(from: &root, id: id) else { return nil }
    guard attach(&root, node: node, parent: parent, before: before) else { return nil }
    var copy = document
    copy["root"] = root
    return copy
  }

  private static func detach(from fields: inout [String: Any], id: Int) -> [String: Any]? {
    if let node = detach(list: "children", from: &fields, id: id) { return node }
    if let node = detach(list: "shadowRoots", from: &fields, id: id) { return node }
    guard var frame = fields["contentDocument"] as? [String: Any] else { return nil }
    guard let node = detach(from: &frame, id: id) else { return nil }
    fields["contentDocument"] = frame
    return node
  }

  private static func detach(list key: String, from fields: inout [String: Any], id: Int)
    -> [String: Any]?
  {
    guard var list = fields[key] as? [[String: Any]] else { return nil }
    if let index = list.firstIndex(where: { ($0["nodeId"] as? Int) == id }) {
      let node = list.remove(at: index)
      fields[key] = list
      return node
    }
    for index in list.indices {
      if let node = detach(from: &list[index], id: id) {
        fields[key] = list
        return node
      }
    }
    return nil
  }

  private static func attach(
    _ fields: inout [String: Any], node: [String: Any], parent: Int, before: Int?
  ) -> Bool {
    if (fields["nodeId"] as? Int) == parent {
      var children = fields["children"] as? [[String: Any]] ?? []
      if let before, let index = children.firstIndex(where: { ($0["nodeId"] as? Int) == before }) {
        children.insert(node, at: index)
      } else {
        children.append(node)
      }
      fields["children"] = children
      return true
    }
    if attach(list: "children", in: &fields, node: node, parent: parent, before: before) {
      return true
    }
    if attach(list: "shadowRoots", in: &fields, node: node, parent: parent, before: before) {
      return true
    }
    guard var frame = fields["contentDocument"] as? [String: Any] else { return false }
    guard attach(&frame, node: node, parent: parent, before: before) else { return false }
    fields["contentDocument"] = frame
    return true
  }

  private static func attach(
    list key: String, in fields: inout [String: Any], node: [String: Any], parent: Int,
    before: Int?
  ) -> Bool {
    guard var list = fields[key] as? [[String: Any]] else { return false }
    for index in list.indices {
      if attach(&list[index], node: node, parent: parent, before: before) {
        fields[key] = list
        return true
      }
    }
    return false
  }
}

@Suite @MainActor struct ShaarDOMTreeModelTests {
  @Test func twentyThousandNodeFixtureIsVisible() async {
    let fixture = DOMFixtureTransport()
    fixture.document = DOMFixtureTransport.twentyThousandNodeDocument()
    let model = ShaarDOMTreeModel(target: target(), transport: fixture)
    model.open()
    for _ in 0..<100 where model.rootID == nil && model.failure == nil { await Task.yield() }
    #expect(model.failure == nil)
    #expect(model.nodes.count == 20_000)
    #expect(model.rows.count == 20_000)
    model.close()
  }

  private func moveCount(_ commands: [ShaarDOMCommand]) -> Int {
    commands.reduce(0) { count, command in
      if case .move = command { return count + 1 }
      return count
    }
  }

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
    #expect(model.selector(for: 5) == "h1")
    #expect(
      model.xpath(for: 5)
        == "/*[local-name()='html'][1]/*[local-name()='body'][1]/*[local-name()='main'][1]/*[local-name()='h1'][1]"
    )
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
    #expect(model.nodes[5]?.parentID == 4)
    await model.undo()
    #expect(!model.canUndo)
    model.updateTarget(target(), committed: true)
    #expect(model.nodes.isEmpty && model.selectedID == nil)
    model.close()
  }

  @Test func dropInsideMovesToTheNewParentAndUndoRestoresIt() async {
    let fixture = DOMFixtureTransport()
    let model = ShaarDOMTreeModel(target: target(), transport: fixture)
    model.open()
    for _ in 0..<20 where model.rootID == nil { await Task.yield() }
    #expect(model.nodes[5]?.parentID == 4)
    let inside = ShaarDOMDrop.destination(
      draggedID: 5, rowID: 3, kind: .inside, nodes: model.nodes)
    #expect(inside?.parentID == 3)
    #expect(inside?.before == nil)
    await model.move(5, to: 3)
    #expect(fixture.commands.contains(.move(5, 3, nil)))
    #expect(model.nodes[5]?.parentID == 3)
    #expect(model.nodes[3]?.childrenIDs.contains(5) == true)
    #expect(model.nodes[4]?.childrenIDs.contains(5) == false)
    #expect(model.nodes[6]?.parentID == 5)
    await model.undo()
    #expect(model.nodes[5]?.parentID == 4)
    #expect(model.nodes[3]?.childrenIDs.contains(5) == false)
    model.close()
  }

  @Test func dropRejectsANodeInsideItsDescendant() async {
    let fixture = DOMFixtureTransport()
    let model = ShaarDOMTreeModel(target: target(), transport: fixture)
    model.open()
    for _ in 0..<20 where model.rootID == nil { await Task.yield() }
    #expect(ShaarDOMDrop.kind(nodeType: 1, height: 24, y: 12) == .inside)
    #expect(ShaarDOMDrop.kind(nodeType: 1, height: 24, y: 2) == .before)
    #expect(ShaarDOMDrop.kind(nodeType: 3, height: 24, y: 12) == .before)
    let before = ShaarDOMDrop.destination(
      draggedID: 8, rowID: 5, kind: .before, nodes: model.nodes)
    #expect(before?.parentID == 4)
    #expect(before?.before == 5)
    #expect(
      ShaarDOMDrop.destination(draggedID: 4, rowID: 5, kind: .inside, nodes: model.nodes) == nil)
    let movesBefore = moveCount(fixture.commands)
    await model.move(4, to: 5)
    #expect(moveCount(fixture.commands) == movesBefore)
    #expect(model.nodes[4]?.parentID == 3)
    model.close()
  }

  @Test func searchCyclesEveryMatchAndReportsTheCount() async throws {
    _ = NSApplication.shared
    let fixture = DOMFixtureTransport()
    fixture.searchNodeIDs = [8, 5, 4]
    let model = ShaarDOMTreeModel(target: target(), transport: fixture)
    model.open()
    for _ in 0..<20 where model.rootID == nil { await Task.yield() }
    #expect(!model.expanded.contains(3))
    model.search = "button"
    await model.performSearch()
    #expect(model.matchOrder == [8, 5, 4])
    #expect(model.matches == [8, 5, 4])
    #expect(model.matchIndex == 0)
    #expect(model.selectedID == 8)
    #expect(model.matchCountLabel == counted(1, of: 3))
    #expect(model.expanded.isSuperset(of: [1, 2, 3, 4, 7]))
    #expect(model.rows.contains { $0.id == 8 })
    let inspector = InspectorModel(target: target(), engine: nil)
    defer { inspector.close() }
    inspector.open()
    let countedImage = try VisualCapture.pngOffscreen(
      ShaarDOMTreePanel(model: model, inspector: inspector, openChromium: {}),
      size: NSSize(width: 720, height: 480))

    await model.toggleExpanded(3)
    #expect(!model.rows.contains { $0.id == 5 })
    await model.stepSearchMatch(forward: true)
    #expect(model.matchIndex == 1)
    #expect(model.selectedID == 5)
    #expect(model.matchCountLabel == counted(2, of: 3))
    #expect(model.expanded.contains(3))
    #expect(model.expanded.contains(4))
    #expect(model.rows.contains { $0.id == 5 })

    await model.stepSearchMatch(forward: true)
    #expect(model.selectedID == 4)
    #expect(model.matchCountLabel == counted(3, of: 3))
    await model.stepSearchMatch(forward: true)
    #expect(model.matchIndex == 0)
    #expect(model.selectedID == 8)
    #expect(model.matchCountLabel == counted(1, of: 3))

    await model.stepSearchMatch(forward: false)
    #expect(model.matchIndex == 2)
    #expect(model.selectedID == 4)
    #expect(model.matchCountLabel == counted(3, of: 3))

    model.search = "   "
    await model.performSearch()
    #expect(model.matchOrder.isEmpty)
    #expect(model.matchCountLabel == nil)
    #expect(model.matches.isEmpty)
    let clearedImage = try VisualCapture.pngOffscreen(
      ShaarDOMTreePanel(model: model, inspector: inspector, openChromium: {}),
      size: NSSize(width: 720, height: 480))
    #expect(!countedImage.isEmpty)
    #expect(!clearedImage.isEmpty)
    await model.stepSearchMatch(forward: true)
    #expect(model.selectedID == 4)
    model.close()
  }

  @Test func searchRevealsAHitThatWasNotLoaded() async {
    let fixture = DOMFixtureTransport()
    fixture.searchNodeIDs = [99]
    fixture.describedNodes[99] = [
      "nodeId": 99, "parentId": 3, "nodeType": 1, "nodeName": "SPAN", "nodeValue": "",
      "childNodeCount": 0, "attributes": ["id", "shaar-live-element"],
    ]
    let model = ShaarDOMTreeModel(target: target(), transport: fixture)
    model.open()
    for _ in 0..<20 where model.rootID == nil { await Task.yield() }
    #expect(model.nodes[99] == nil)
    model.search = "#shaar-live-element"
    await model.performSearch()
    #expect(model.matchOrder == [99])
    #expect(model.selectedID == 99)
    #expect(model.matchCountLabel == counted(1, of: 1))
    #expect(model.nodes[3]?.childrenIDs.contains(99) == true)
    #expect(model.expanded.contains(3))
    #expect(model.rows.contains { $0.id == 99 })
    model.close()
  }

  private func counted(_ index: Int, of count: Int) -> String {
    ShellL10n.format("%d of %d", arguments: [.integer(index), .integer(count)])
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

  @Test func copyPathsMatchInspectorForALaterSibling() async {
    let fixture = DOMFixtureTransport()
    fixture.document = laterSiblingDocument()
    let model = ShaarDOMTreeModel(target: target(), transport: fixture)
    model.open()
    for _ in 0..<20 where model.rootID == nil { await Task.yield() }
    #expect(model.selector(for: 4) == "#notes")
    #expect(model.xpath(for: 4) == "//*[@id='notes']")
    #expect(model.selector(for: 5) == "section:nth-of-type(2)")
    #expect(
      model.xpath(for: 5)
        == "/*[local-name()='html'][1]/*[local-name()='body'][1]/*[local-name()='section'][2]"
    )
    #expect(model.selector(for: 6) == "[data-testid=later]")
    #expect(
      model.xpath(for: 6)
        == "/*[local-name()='html'][1]/*[local-name()='body'][1]/*[local-name()='section'][3]"
    )
    #expect(model.selector(for: 8) == "#a\\'b")
    #expect(model.xpath(for: 8) == "//*[@id=\"a'b\"]")
    model.close()
  }

  @Test func partialDocumentSliceDoesNotInventASiblingIndex() async {
    let fixture = DOMFixtureTransport()
    fixture.document = [
      "root": [
        "nodeId": 1, "nodeType": 9, "nodeName": "#document", "nodeValue": "",
        "children": [
          [
            "nodeId": 2, "nodeType": 1, "nodeName": "HTML", "nodeValue": "",
            "children": [
              [
                "nodeId": 3, "nodeType": 1, "nodeName": "BODY", "nodeValue": "",
                "childNodeCount": 4,
                "children": [
                  ["nodeId": 5, "nodeType": 1, "nodeName": "SECTION", "nodeValue": ""]
                ],
              ]
            ],
          ]
        ],
      ]
    ]
    let model = ShaarDOMTreeModel(target: target(), transport: fixture)
    model.open()
    for _ in 0..<20 where model.rootID == nil { await Task.yield() }
    #expect(model.selector(for: 5).isEmpty)
    #expect(model.xpath(for: 5).isEmpty)
    model.close()
  }

  private func laterSiblingDocument() -> [String: Any] {
    [
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
                    "nodeId": 4, "nodeType": 1, "nodeName": "SECTION", "nodeValue": "",
                    "attributes": ["id", "notes"],
                  ],
                  ["nodeId": 5, "nodeType": 1, "nodeName": "SECTION", "nodeValue": ""],
                  [
                    "nodeId": 6, "nodeType": 1, "nodeName": "SECTION", "nodeValue": "",
                    "attributes": ["data-testid", "later"],
                  ],
                  [
                    "nodeId": 8, "nodeType": 1, "nodeName": "DIV", "nodeValue": "",
                    "attributes": ["id", "a'b"],
                  ],
                ],
              ]
            ],
          ]
        ],
      ]
    ]
  }

  @Test func copyPathLoadsMissingChildrenAndRendersOffscreen() async throws {
    _ = NSApplication.shared
    let complete = DOMFixtureTransport()
    let populated = ShaarDOMTreeModel(target: target(), transport: complete)
    populated.open()
    for _ in 0..<20 where populated.rootID == nil { await Task.yield() }
    await populated.prepareCopyPath(for: 6)
    #expect(!complete.commands.contains(.children(1)))
    #expect(!complete.commands.contains(.children(2)))
    #expect(!complete.commands.contains(.children(3)))
    #expect(!complete.commands.contains(.children(4)))
    #expect(!complete.commands.contains(.children(5)))

    let inspector = InspectorModel(target: target(), engine: nil)
    defer { inspector.close() }
    #expect(await inspector.pathsForDOMNode(5) == nil)
    inspector.open()
    #expect(await inspector.pathsForDOMNode(0) == nil)
    #expect(await inspector.pathsForDOMNode(5) == nil)
    let wide = try VisualCapture.pngOffscreen(
      ShaarDOMTreePanel(model: populated, inspector: inspector, openChromium: {}),
      size: NSSize(width: 720, height: 480))
    let narrow = try VisualCapture.pngOffscreen(
      ShaarDOMTreePanel(model: populated, inspector: inspector, openChromium: {}),
      size: NSSize(width: 400, height: 640))
    #expect(!wide.isEmpty)
    #expect(!narrow.isEmpty)
    populated.close()

    let partialTransport = DOMFixtureTransport()
    partialTransport.document = [
      "root": [
        "nodeId": 1, "nodeType": 9, "nodeName": "#document", "nodeValue": "",
        "children": [
          [
            "nodeId": 2, "nodeType": 1, "nodeName": "HTML", "nodeValue": "",
            "children": [
              [
                "nodeId": 3, "nodeType": 1, "nodeName": "BODY", "nodeValue": "",
                "childNodeCount": 4,
                "children": [
                  ["nodeId": 5, "nodeType": 1, "nodeName": "SECTION", "nodeValue": ""]
                ],
              ]
            ],
          ]
        ],
      ]
    ]
    let partial = ShaarDOMTreeModel(target: target(), transport: partialTransport)
    partial.open()
    for _ in 0..<20 where partial.rootID == nil { await Task.yield() }
    await partial.prepareCopyPath(for: 5)
    #expect(partialTransport.commands.contains(.children(3)))
    #expect(partial.selector(for: 5).isEmpty)
    partial.close()
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
