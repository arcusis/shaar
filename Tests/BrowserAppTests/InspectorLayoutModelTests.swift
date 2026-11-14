// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import JavaScriptCore
import Testing
@testable import ArcusisBrowser

@Suite @MainActor
struct InspectorLayoutModelTests {
  @Test func resetCancelsAndClearsQueuedLayoutWork() async throws {
    let url = try #require(URL(string: "https://example.test"))
    let inspector = InspectorModel(
      target: SiteControlTarget(tabID: UUID(), profileID: UUID(), url: url), engine: nil)
    let model = inspector.layout

    await model.disableAll()
    let queued = try #require(model.tail)
    #expect(!queued.isCancelled)

    model.reset()

    #expect(queued.isCancelled)
    #expect(model.tail == nil)
  }

  @Test func distinctLongElementIDsReceiveDistinctContainerKeys() throws {
    let context = try #require(JSContext())
    let setup = #"""
      globalThis.NodeFilter = {SHOW_ELEMENT: 1};
      globalThis.getComputedStyle = element => ({display: element.display || 'block'});
      const root = {
        nodeType: 1, localName: 'body', id: '', children: [], classList: [],
        closest() { return null; }
      };
      for (const [id, display] of [
        ['x'.repeat(80) + 'first', 'grid'], ['x'.repeat(80) + 'second', 'flex']
      ]) {
        root.children.push({
          nodeType: 1, localName: 'section', id, display, children: [], classList: [],
          parentElement: root, closest() { return null; }
        });
      }
      globalThis.document = {
        body: root,
        createTreeWalker() {
          const nodes = [root, ...root.children];
          let index = 1;
          return {currentNode: root, nextNode() { return nodes[index++] || null; }};
        },
        querySelectorAll() { return []; }
      };
      """#
    #expect(context.evaluateScript(setup)?.toBool() == true)
    #expect(context.evaluateScript(InspectorLayoutModel.install)?.toBool() == true)
    let json = try #require(
      context.evaluateScript("JSON.stringify(__shaarInspectorLayout.read())")?.toString().data(
        using: .utf8))
    let rows = try #require(JSONSerialization.jsonObject(with: json) as? [[String: Any]])

    #expect(rows.count == 2)
    let keys = Set(rows.compactMap { $0["key"] as? String })
    #expect(keys.count == 2)
    #expect(rows.compactMap { $0["kind"] as? String } == ["grid", "flex"])
    let keysByKind: [String: String] = Dictionary(
      uniqueKeysWithValues: rows.compactMap { row in
        guard let kind = row["kind"] as? String, let key = row["key"] as? String else {
          return nil
        }
        return (kind, key)
      })
    #expect(context.evaluateScript("document.body.children.reverse()") != nil)
    let reorderedJSON = try #require(
      context.evaluateScript("JSON.stringify(__shaarInspectorLayout.read())")?.toString().data(
        using: .utf8))
    let reorderedRows = try #require(
      JSONSerialization.jsonObject(with: reorderedJSON) as? [[String: Any]])
    let reorderedKeysByKind: [String: String] = Dictionary(
      uniqueKeysWithValues: reorderedRows.compactMap { row in
        guard let kind = row["kind"] as? String, let key = row["key"] as? String else {
          return nil
        }
        return (kind, key)
      })
    #expect(reorderedKeysByKind == keysByKind)
  }
}
