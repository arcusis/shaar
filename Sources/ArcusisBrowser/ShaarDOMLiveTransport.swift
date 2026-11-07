// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineABI

struct ShaarDOMRequest {
  let method: String
  let params: [String: Any]

  init(_ command: ShaarDOMCommand) {
    switch command {
    case .document(let depth):
      method = "DOM.getDocument"
      params = ["depth": depth, "pierce": true]
    case .children(let id):
      method = "DOM.requestChildNodes"
      params = ["nodeId": id, "depth": 1, "pierce": true]
    case .search(let query):
      method = "DOM.performSearch"
      params = ["query": query, "includeUserAgentShadowDOM": true]
    case .searchResults(let searchID, let count):
      method = "DOM.getSearchResults"
      params = ["searchId": searchID, "fromIndex": 0, "toIndex": count]
    case .discardSearch(let searchID):
      method = "DOM.discardSearchResults"
      params = ["searchId": searchID]
    case .describe(let id):
      method = "DOM.describeNode"
      params = ["nodeId": id]
    case .describeBackend(let id):
      method = "DOM.describeNode"
      params = ["backendNodeId": id]
    case .highlight(let id):
      method = "Overlay.highlightNode"
      params = [
        "nodeId": id,
        "highlightConfig": [
          "showInfo": true, "contentColor": ["r": 67, "g": 145, "b": 244, "a": 0.22],
        ],
      ]
    case .hideHighlight:
      method = "Overlay.hideHighlight"
      params = [:]
    case .setAttribute(let id, let name, let value):
      method = "DOM.setAttributeValue"
      params = ["nodeId": id, "name": name, "value": value]
    case .removeAttribute(let id, let name):
      method = "DOM.removeAttribute"
      params = ["nodeId": id, "name": name]
    case .setText(let id, let value):
      method = "DOM.setNodeValue"
      params = ["nodeId": id, "value": value]
    case .setHTML(let id, let html):
      method = "DOM.setOuterHTML"
      params = ["nodeId": id, "outerHTML": html]
    case .remove(let id):
      method = "DOM.removeNode"
      params = ["nodeId": id]
    case .move(let id, let parent, let before):
      method = "DOM.moveTo"
      var fields: [String: Any] = ["nodeId": id, "targetNodeId": parent]
      if let before { fields["insertBeforeNodeId"] = before }
      params = fields
    case .markUndo:
      method = "DOM.markUndoableState"
      params = [:]
    case .undo:
      method = "DOM.undo"
      params = [:]
    case .outerHTML(let id):
      method = "DOM.getOuterHTML"
      params = ["nodeId": id]
    }
  }
}

/// Shares the Console/Network panel lease while using the Inspector command
/// session for DOM node IDs. Older engines fail the DOM command probe and keep
/// the fixture-free Elements empty state.
@MainActor
final class ShaarDOMLiveTransport: ShaarDOMTransport {
  typealias CommandCall =
    @MainActor (ShaarDOMCommand, SiteControlTarget) async throws -> [String: Any]

  private let panel: ShaarDevToolsNativeTransport
  private let call: CommandCall
  private var target: SiteControlTarget?
  private var leaseID: UInt32?
  private var streamToken: UUID?

  convenience init(engine: BrowserEngine, panel: ShaarDevToolsNativeTransport) {
    self.init(panel: panel) { [weak engine] command, target in
      guard let engine else { throw CancellationError() }
      let request = ShaarDOMRequest(command)
      let connection = InspectorConnection(engine: engine)
      return try await connection.call(request.method, params: request.params, target: target)
    }
  }

  init(panel: ShaarDevToolsNativeTransport, call: @escaping CommandCall) {
    self.panel = panel
    self.call = call
  }

  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarDOMMessage> {
    let signals = panel.domSignals(for: target)
    let token = UUID()
    streamToken = token
    self.target = target
    leaseID = nil
    return AsyncStream { continuation in
      let task = Task { [weak self] in
        for await signal in signals {
          guard let self, self.streamToken == token, !Task.isCancelled else { break }
          await self.receive(
            signal, target: target, token: token, continuation: continuation)
        }
        continuation.finish()
      }
      continuation.onTermination = { @Sendable [weak self] _ in
        task.cancel()
        Task { @MainActor in
          guard let self, self.streamToken == token else { return }
          self.streamToken = nil
          self.target = nil
          self.leaseID = nil
        }
      }
    }
  }

  func execute(_ command: ShaarDOMCommand, for target: SiteControlTarget) async throws
    -> [String: Any]
  {
    guard self.target == target, leaseID != nil else { throw CancellationError() }
    return try await call(command, target)
  }

  private func receive(
    _ signal: ShaarDOMPanelSignal, target: SiteControlTarget, token: UUID,
    continuation: AsyncStream<ShaarDOMMessage>.Continuation
  ) async {
    guard streamToken == token else { return }
    switch signal {
    case .lease(let id):
      leaseID = id
      do {
        _ = try await execute(.markUndo, for: target)
        guard !Task.isCancelled, streamToken == token,
          self.target == target, leaseID == id
        else { return }
        continuation.yield(.available)
      } catch {
        guard streamToken == token else { return }
        leaseID = nil
        continuation.yield(.unavailable)
      }
    case .event(let event):
      if leaseID == event.leaseID { continuation.yield(.event(event)) }
    case .unavailable:
      leaseID = nil
      continuation.yield(.unavailable)
    }
  }
}
