// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineABI
import Testing

@testable import ArcusisBrowser

@MainActor private final class DOMPanelRequesterFixture: ShaarPanelRequesting {
  var operations: [ShaarDevToolsOperation] = []

  func request(
    _ operation: ShaarDevToolsOperation, target: SiteControlTarget, payload: [String: Any]
  ) async throws -> [String: Any] {
    operations.append(operation)
    if operation == .panelOpen { return ["schemaVersion": 1, "leaseID": 7] }
    return ["schemaVersion": 1]
  }
}

@Suite struct ShaarDOMLiveTransportTests {
  @Test func mapsDocumentSearchAndMutationToBoundedDOMCommands() {
    let document = ShaarDOMRequest(.document(depth: 2))
    #expect(document.method == "DOM.getDocument")
    #expect(document.params["depth"] as? Int == 2)
    #expect(document.params["pierce"] as? Bool == true)

    let search = ShaarDOMRequest(.search("main.card"))
    #expect(search.method == "DOM.performSearch")
    #expect(search.params["query"] as? String == "main.card")
    #expect(search.params["includeUserAgentShadowDOM"] as? Bool == true)

    let move = ShaarDOMRequest(.move(4, 2, 7))
    #expect(move.method == "DOM.moveTo")
    #expect(move.params["nodeId"] as? Int == 4)
    #expect(move.params["targetNodeId"] as? Int == 2)
    #expect(move.params["insertBeforeNodeId"] as? Int == 7)

    let html = ShaarDOMRequest(.setHTML(4, "<main>Updated</main>"))
    #expect(html.method == "DOM.setOuterHTML")
    #expect(html.params["outerHTML"] as? String == "<main>Updated</main>")

    let undo = ShaarDOMRequest(.undo)
    #expect(undo.method == "DOM.undo")
    #expect(undo.params.isEmpty)
  }
}

@Suite @MainActor struct ShaarDOMCapabilityTests {
  private let target = SiteControlTarget(
    tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/")!)

  @Test func olderEngineKeepsDOMUnavailableWithoutClosingSharedPanel() async {
    let requester = DOMPanelRequesterFixture()
    let panel = ShaarDevToolsNativeTransport(
      requester: requester, windowID: UUID().uuidString)
    var shell = panel.messages(for: target).makeAsyncIterator()
    #expect(await shell.next() == .streamAvailable)
    let dom = ShaarDOMLiveTransport(panel: panel) { _, _ in throw CancellationError() }
    var stream = dom.messages(for: target).makeAsyncIterator()
    guard case .unavailable? = await stream.next() else {
      Issue.record("Older engine exposed a live DOM tree")
      return
    }
    #expect(!requester.operations.contains(.panelClose))
  }

  @Test func capableEngineEnablesDOMOnSharedPanelLease() async {
    let requester = DOMPanelRequesterFixture()
    let panel = ShaarDevToolsNativeTransport(
      requester: requester, windowID: UUID().uuidString)
    var shell = panel.messages(for: target).makeAsyncIterator()
    #expect(await shell.next() == .streamAvailable)
    let dom = ShaarDOMLiveTransport(panel: panel) { _, _ in [:] }
    var stream = dom.messages(for: target).makeAsyncIterator()
    guard case .available? = await stream.next() else {
      Issue.record("Capable engine did not enable the DOM tree")
      return
    }
    #expect(!requester.operations.contains(.panelClose))
  }
}
