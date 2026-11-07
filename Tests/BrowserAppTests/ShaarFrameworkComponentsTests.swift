// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import JavaScriptCore
import Testing

@testable import ArcusisBrowser

@Suite struct ShaarFrameworkComponentsTests {
  @Test func reactVueAndAngularFixturesExposeComponentTrees() throws {
    let react = try FrameworkFixture.snapshot(script: "react.js")
    let vue = try FrameworkFixture.snapshot(script: "vue.js")
    let angular = try FrameworkFixture.snapshot(script: "angular.js")
    try expectTree(react, framework: .react, components: FrameworkFixture.reactComponents)
    try expectTree(vue, framework: .vue, components: FrameworkFixture.vueComponents)
    try expectTree(angular, framework: .angular, components: FrameworkFixture.angularComponents)
  }

  @Test func reactContainerKeyStillReadsTheTreeAfterTheHookIsRemoved() throws {
    let context = try FrameworkFixture.context(script: "react.js")
    context.evaluateScript("delete window.__REACT_DEVTOOLS_GLOBAL_HOOK__")
    let snapshot = try FrameworkFixture.snapshot(in: context)
    try expectTree(snapshot, framework: .react, components: FrameworkFixture.reactComponents)
  }

  @Test func componentSnapshotDoesNotInvokePropAccessors() throws {
    let context = try FrameworkFixture.context(script: "react.js")
    context.evaluateScript(
      """
      globalThis.inspectorGetterCalls = 0;
      const counter = document.getElementById('react-app')
        ['__reactContainer$fixture'].current.child.child.sibling;
      const getter = () => { globalThis.inspectorGetterCalls += 1; return 'unexpected'; };
      Object.defineProperty(counter.memoizedProps, 'lazy', { enumerable: true, get: getter });
      const nested = {};
      Object.defineProperty(nested, 'danger', { enumerable: true, get: getter });
      counter.memoizedProps.nested = nested;
      const list = [1];
      Object.defineProperty(list, '1', { enumerable: true, get: getter });
      counter.memoizedProps.list = list;
      """)
    try FrameworkFixture.requireClean(context)
    let snapshot = try FrameworkFixture.snapshot(in: context)
    let counter = try #require(snapshot.nodes.first { $0.name == "Counter" })
    let props = Dictionary(uniqueKeysWithValues: counter.props.map { ($0.name, $0.value) })
    #expect(props["lazy"] == "[Accessor]")
    #expect(props["nested"] == "{\"danger\":\"[Accessor]\"}")
    #expect(props["list"] == "[1, [Accessor]]")
    #expect(context.evaluateScript("globalThis.inspectorGetterCalls")?.toInt32() == 0)
  }

  @Test func plainPageHasNoFrameworkTree() throws {
    let snapshot = try FrameworkFixture.snapshot(script: nil)
    #expect(snapshot.framework == nil)
    #expect(snapshot.nodes.isEmpty)
    #expect(snapshot.rows.isEmpty)
  }

  @Test func highlightDrawsRemovesAndIgnoresAStaleEpoch() throws {
    let context = try FrameworkFixture.context(script: "react.js")
    let snapshot = try FrameworkFixture.snapshot(in: context)
    let counter = try #require(snapshot.nodes.first { $0.name == "Counter" })
    let show = try #require(ShaarFrameworkPageScript.highlightExpression(id: counter.id, epoch: 2))
    #expect(context.evaluateScript(show)?.toBool() == true)
    let marked = context.evaluateScript(
      "document.getElementById('shaar-framework-highlight').getAttribute('data-shaar-highlight')"
    )?.toString()
    #expect(marked == counter.id)
    let stale = try #require(ShaarFrameworkPageScript.highlightExpression(id: nil, epoch: 1))
    #expect(context.evaluateScript(stale)?.toBool() == false)
    #expect(highlightExists(in: context))
    let clear = try #require(ShaarFrameworkPageScript.highlightExpression(id: nil, epoch: 3))
    #expect(context.evaluateScript(clear)?.toBool() == true)
    #expect(!highlightExists(in: context))
    try FrameworkFixture.requireClean(context)
  }

  @Test func highlightExpressionRejectsMaliciousIdentifiers() {
    #expect(ShaarFrameworkPageScript.highlightExpression(id: "1);alert(1)", epoch: 1) == nil)
    #expect(ShaarFrameworkPageScript.highlightExpression(id: "12ab", epoch: 1) == nil)
    #expect(ShaarFrameworkPageScript.highlightExpression(id: "", epoch: 1) == nil)
    #expect(ShaarFrameworkPageScript.highlightExpression(id: "1", epoch: 0) == nil)
    #expect(ShaarFrameworkPageScript.highlightExpression(id: "1", epoch: 1_000_000_000) == nil)
    #expect(
      ShaarFrameworkPageScript.highlightExpression(id: nil, epoch: 2)
        == "globalThis.__shaarHighlightFrameworkComponent?.(null,2)")
    #expect(
      ShaarFrameworkPageScript.highlightExpression(id: "12", epoch: 3)
        == "globalThis.__shaarHighlightFrameworkComponent?.(\"12\",3)")
  }

  @Test func parserRejectsOversizedCyclesAndBadIdentifiers() {
    let oversized = (1...81).map { FrameworkFixture.node(String($0)) }
    expectParseFailure(FrameworkFixture.payload(nodes: oversized), reason: "nodes")
    expectParseFailure(
      FrameworkFixture.payload(nodes: [FrameworkFixture.node("12ab")]), reason: "node")
    expectParseFailure(
      FrameworkFixture.payload(nodes: [
        FrameworkFixture.node("1", parent: "2", name: "A"),
        FrameworkFixture.node("2", parent: "1", name: "B"),
      ]), reason: "orphan")
    var chain: [[String: Any]] = []
    for index in 1...14 {
      let parent: Any = index == 1 ? NSNull() : String(index - 1)
      chain.append(FrameworkFixture.node(String(index), parent: parent, name: "Level"))
    }
    expectParseFailure(FrameworkFixture.payload(nodes: chain), reason: "depth")
    let repeated = ShaarFrameworkNode(
      id: "1", parentID: nil, name: "App", key: nil, props: [], state: [])
    #expect(throws: ShaarFrameworkFailure(reason: "cycle")) {
      _ = try ShaarFrameworkSnapshotParser.rows(for: [repeated, repeated])
    }
    expectParseFailure(
      ["schema": true, "framework": NSNull(), "nodes": [Any]()], reason: "schema")
  }

  @Test func accessAllowsLoopbackAndASessionHostOnly() throws {
    #expect(try allows("http://localhost:3000/app", enabled: nil))
    #expect(try allows("http://127.0.0.1:4173/framework-components/react", enabled: nil))
    #expect(try allows("http://[::1]/app", enabled: nil))
    #expect(try allows("http://shop.localhost/app", enabled: nil))
    #expect(try !allows("https://example.com/", enabled: nil))
    #expect(try !allows("https://localhost.example/", enabled: nil))
    #expect(try !allows("file:///tmp/app.html", enabled: nil))
    #expect(try allows("https://example.com/docs", enabled: "example.com"))
    #expect(try !allows("https://other.example/docs", enabled: "example.com"))
    #expect(ShaarFrameworkAccess.host(try #require(URL(string: "http://[::1]:8080/"))) == "::1")
  }

  @Test @MainActor func remotePageDoesNotEvaluateUntilTheSiteIsEnabled() async throws {
    let page = RecordingFrameworkPage()
    let model = ShaarFrameworkComponentsModel()
    model.attach(page)
    model.updateAccess(url: try #require(URL(string: "https://example.com/app")))
    await model.refresh()
    #expect(page.expressions.isEmpty)
    #expect(model.inspected)
    #expect(!model.allowed)
    #expect(model.rows.isEmpty)
    model.enableCurrentSite()
    page.value = FrameworkFixture.payload(nodes: [], framework: NSNull())
    await model.refresh()
    #expect(model.allowed)
    #expect(page.expressions.count == 1)
    #expect(page.expressions[0].contains("shaarInspectFramework"))
    model.updateAccess(url: try #require(URL(string: "https://other.example/app")))
    let calls = page.expressions.count
    await model.refresh()
    #expect(!model.allowed)
    #expect(page.expressions.count == calls)
  }

  @Test @MainActor func staleRefreshCannotReplaceANewerTree() async throws {
    let page = DelayedFrameworkPage(
      slow: FrameworkFixture.payload(
        nodes: [FrameworkFixture.node("1", name: "Slow")], framework: "vue"),
      fast: FrameworkFixture.payload(
        nodes: [FrameworkFixture.node("1", name: "Fast")], framework: "react"))
    let model = ShaarFrameworkComponentsModel()
    model.attach(page)
    model.updateAccess(url: try #require(URL(string: "http://localhost:3000/")))
    let first = Task { await model.refresh() }
    for _ in 0..<50 where page.calls == 0 { await Task.yield() }
    #expect(page.calls == 1)
    await model.refresh()
    await first.value
    #expect(model.framework == .react)
    #expect(model.rows.map(\.name) == ["Fast"])
  }

  @Test @MainActor func malformedHighlightIdentifierIsNotEvaluated() async throws {
    let page = RecordingFrameworkPage()
    let model = ShaarFrameworkComponentsModel()
    model.attach(page)
    model.updateAccess(url: try #require(URL(string: "http://127.0.0.1/")))
    await model.highlight("1);alert(1)")
    #expect(page.expressions.isEmpty)
    await model.highlight(nil)
    #expect(page.expressions.count == 1)
    #expect(page.expressions[0].contains("(null,"))
  }

  private func expectTree(
    _ snapshot: ShaarFrameworkSnapshot, framework: ShaarFrameworkKind,
    components: [FrameworkFixture.Component]
  ) throws {
    #expect(snapshot.framework == framework)
    #expect(snapshot.rows.map(\.name) == components.map(\.name))
    #expect(snapshot.rows.map(\.key) == components.map(\.key))
    for (node, expected) in zip(snapshot.nodes, components) {
      #expect(node.name == expected.name)
      #expect(
        Dictionary(uniqueKeysWithValues: node.props.map { ($0.name, $0.value) }) == expected.props)
      #expect(
        Dictionary(uniqueKeysWithValues: node.state.map { ($0.name, $0.value) }) == expected.state)
    }
  }

  private func expectParseFailure(_ value: [String: Any], reason: String) {
    #expect(throws: ShaarFrameworkFailure(reason: reason)) {
      try ShaarFrameworkSnapshotParser.parse(value)
    }
  }

  private func allows(_ address: String, enabled: String?) throws -> Bool {
    let url = try #require(URL(string: address))
    return ShaarFrameworkAccess.allows(url: url, enabledHost: enabled)
  }

  private func highlightExists(in context: JSContext) -> Bool {
    context.evaluateScript("document.getElementById('shaar-framework-highlight') != null")?.toBool()
      == true
  }
}

enum FrameworkFixture {
  struct Component {
    var name: String
    var key: String?
    var props: [String: String]
    var state: [String: String]
  }

  static let reactComponents = [
    Component(name: "App", key: nil, props: ["title": "Local"], state: ["state 1": "true"]),
    Component(name: "Header", key: "title", props: ["title": "Local"], state: [:]),
    Component(name: "Counter", key: nil, props: ["start": "0"], state: ["state 1": "2"]),
  ]
  static let vueComponents = [
    Component(name: "App", key: nil, props: ["title": "Local"], state: ["ready": "true"]),
    Component(name: "Header", key: nil, props: ["title": "Local"], state: [:]),
    Component(name: "Counter", key: nil, props: ["start": "0"], state: ["count": "2"]),
  ]
  static let angularComponents = [
    Component(name: "App", key: nil, props: [:], state: ["ready": "true"]),
    Component(name: "Header", key: nil, props: ["title": "Local"], state: [:]),
    Component(name: "Counter", key: nil, props: ["start": "0"], state: ["count": "2"]),
  ]

  static func snapshot(script name: String?) throws -> ShaarFrameworkSnapshot {
    try snapshot(in: context(script: name))
  }

  static func context(script name: String?) throws -> JSContext {
    let context = try #require(JSContext())
    context.evaluateScript(domShim)
    try requireClean(context)
    if let name {
      context.evaluateScript(try String(contentsOf: fixtureURL(name), encoding: .utf8))
      try requireClean(context)
    }
    context.evaluateScript(ShaarFrameworkPageScript.inspect)
    try requireClean(context)
    return context
  }

  static func snapshot(in context: JSContext) throws -> ShaarFrameworkSnapshot {
    let encoded = context.evaluateScript("JSON.stringify(shaarInspectFramework(globalThis))")
    try requireClean(context)
    let text = try #require(encoded?.toString())
    let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
    return try ShaarFrameworkSnapshotParser.parse(object)
  }

  static func payload(nodes: [[String: Any]], framework: Any = "react") -> [String: Any] {
    ["schema": 1, "framework": framework, "nodes": nodes]
  }

  static func node(_ id: String, parent: Any = NSNull(), name: String = "App") -> [String: Any] {
    ["id": id, "parentID": parent, "name": name, "props": [Any](), "state": [Any]()]
  }

  static func requireClean(_ context: JSContext) throws {
    if let exception = context.exception {
      throw ShaarFrameworkFailure(reason: exception.toString() ?? "javascript")
    }
  }

  private static func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Tests/Fixtures/framework-components/\(name)")
  }

  private static let domShim = """
    function shaarMakeElement(tag) {
      const element = {
        nodeType: 1,
        localName: String(tag).toLowerCase(),
        id: "",
        textContent: "",
        style: { cssText: "" },
        attributes: {},
        childNodes: [],
        parentNode: null,
      };
      element.appendChild = function (child) {
        child.parentNode = element;
        element.childNodes.push(child);
        return child;
      };
      element.setAttribute = function (name, value) {
        element.attributes[String(name)] = String(value);
      };
      element.getAttribute = function (name) {
        if (!Object.prototype.hasOwnProperty.call(element.attributes, name)) return null;
        return element.attributes[name];
      };
      element.getBoundingClientRect = function () {
        return { left: 8, top: 12, width: 120, height: 24, right: 128, bottom: 36 };
      };
      element.remove = function () {
        const parent = element.parentNode;
        if (!parent) return;
        const index = parent.childNodes.indexOf(element);
        if (index >= 0) parent.childNodes.splice(index, 1);
        element.parentNode = null;
      };
      Object.defineProperty(element, "children", {
        get: function () { return element.childNodes; },
      });
      return element;
    }
    function shaarWalk(node, visit) {
      if (!node || node.nodeType !== 1) return;
      visit(node);
      const children = node.childNodes || [];
      for (let index = 0; index < children.length; index += 1) shaarWalk(children[index], visit);
    }
    const document = {
      nodeType: 9,
      createElement: shaarMakeElement,
      getElementById: function (id) {
        let found = null;
        shaarWalk(document.documentElement, function (element) {
          if (found == null && element.id === id) found = element;
        });
        return found;
      },
      getElementsByTagName: function (tag) {
        const found = [];
        const want = String(tag).toLowerCase();
        shaarWalk(document.documentElement, function (element) {
          if (want === "*" || element.localName === want) found.push(element);
        });
        return found;
      },
      querySelectorAll: function (selector) {
        const found = [];
        if (selector !== "[ng-version]") return found;
        shaarWalk(document.documentElement, function (element) {
          if (element.getAttribute("ng-version") != null) found.push(element);
        });
        return found;
      },
    };
    const shaarHTML = shaarMakeElement("html");
    const shaarBody = shaarMakeElement("body");
    shaarHTML.appendChild(shaarBody);
    document.documentElement = shaarHTML;
    document.body = shaarBody;
    globalThis.document = document;
    globalThis.window = globalThis;
    """
}

@MainActor final class RecordingFrameworkPage: ShaarFrameworkPageEvaluating {
  var expressions: [String] = []
  var value: Any?
  func evaluateFramework(_ expression: String) async throws -> Any? {
    expressions.append(expression)
    return value
  }
}

@MainActor final class DelayedFrameworkPage: ShaarFrameworkPageEvaluating {
  var calls = 0
  private let slow: Any
  private let fast: Any
  init(slow: Any, fast: Any) {
    self.slow = slow
    self.fast = fast
  }
  func evaluateFramework(_ expression: String) async throws -> Any? {
    calls += 1
    if calls == 1 {
      try await Task.sleep(for: .milliseconds(80))
      return slow
    }
    return fast
  }
}
