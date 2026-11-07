// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

enum ShaarEventListenerScript {
  static let remove = """
    function(type, listener, useCapture) {
      this.removeEventListener(type, listener, useCapture);
    }
    """
  static let setPassive = """
    function(type, listener, useCapture, passive) {
      this.removeEventListener(type, listener, {capture: useCapture});
      this.addEventListener(type, listener, {capture: useCapture, passive: passive});
    }
    """
  static let setOnce = """
    function(type, listener, useCapture, passive, once) {
      this.removeEventListener(type, listener, {capture: useCapture});
      this.addEventListener(type, listener, {capture: useCapture, passive: passive, once: once});
    }
    """
}

enum ShaarEventListenerRequest {
  static func listeners(objectID: String) -> (String, [String: Any]) {
    ("DOMDebugger.getEventListeners", ["objectId": objectID, "depth": 1, "pierce": false])
  }

  static func resolve(nodeID: Int) -> (String, [String: Any]) {
    ("DOM.resolveNode", ["nodeId": nodeID])
  }

  static func release(objectID: String) -> (String, [String: Any]) {
    ("Runtime.releaseObject", ["objectId": objectID])
  }

  static func remove(_ listener: ShaarEventListener, nodeObjectID: String) -> (
    String, [String: Any]
  )? {
    edit(
      listener, nodeObjectID: nodeObjectID, declaration: ShaarEventListenerScript.remove,
      passive: nil, once: nil)
  }

  static func setPassive(
    _ listener: ShaarEventListener, nodeObjectID: String, passive: Bool
  ) -> (String, [String: Any])? {
    edit(
      listener, nodeObjectID: nodeObjectID, declaration: ShaarEventListenerScript.setPassive,
      passive: passive, once: nil)
  }

  static func setOnce(
    _ listener: ShaarEventListener, nodeObjectID: String, once: Bool
  ) -> (String, [String: Any])? {
    edit(
      listener, nodeObjectID: nodeObjectID, declaration: ShaarEventListenerScript.setOnce,
      passive: listener.passive, once: once)
  }

  private static func edit(
    _ listener: ShaarEventListener, nodeObjectID: String, declaration: String, passive: Bool?,
    once: Bool?
  ) -> (String, [String: Any])? {
    guard let handlerObjectID = listener.handlerObjectID,
      !nodeObjectID.isEmpty, !handlerObjectID.isEmpty, listener.type.utf8.count <= 256,
      nodeObjectID.utf8.count <= 512, handlerObjectID.utf8.count <= 512
    else { return nil }
    var arguments: [[String: Any]] = [
      ["value": listener.type],
      ["objectId": handlerObjectID],
      ["value": listener.capture],
    ]
    if let passive { arguments.append(["value": passive]) }
    if let once { arguments.append(["value": once]) }
    return (
      "Runtime.callFunctionOn",
      [
        "objectId": nodeObjectID,
        "functionDeclaration": declaration,
        "returnByValue": true,
        "arguments": arguments,
      ]
    )
  }
}

/// Reads listeners through the Inspector session.
@MainActor
final class ShaarEventListenersLiveTransport: ShaarEventListenersTransport {
  typealias Call =
    @MainActor (String, [String: Any], SiteControlTarget) async throws -> [String: Any]

  private let call: Call
  /// Reloads the document and maps stale frontend ids onto the ids that replace them.
  var rebind: (@MainActor ([Int], SiteControlTarget) async -> [Int: Int])?

  convenience init(engine: BrowserEngine) {
    self.init { [weak engine] method, params, target in
      guard let engine else { throw CancellationError() }
      let connection = InspectorConnection(engine: engine)
      return try await connection.call(method, params: params, target: target)
    }
  }

  convenience init(session: PrivatePageSession) {
    self.init { [weak session] method, params, target in
      guard let session else { throw CancellationError() }
      let connection = InspectorConnection(session: session)
      return try await connection.call(method, params: params, target: target)
    }
  }

  init(call: @escaping Call) { self.call = call }

  func listeners(nodeID: Int, ancestors: [Int], target: SiteControlTarget) async throws
    -> [ShaarEventListener]
  {
    do {
      return try await collect(
        nodeID: nodeID, ancestors: ancestors, target: target, tolerateMissingAncestors: false)
    } catch {
      guard ShaarEventListenerNodeLookup.isMissingNode(error), let rebind else { throw error }
      let mapped = await rebind([nodeID] + ancestors, target)
      guard let rebound = mapped[nodeID] else { throw error }
      let reboundAncestors = ancestors.compactMap { mapped[$0] }
      return try await collect(
        nodeID: rebound, ancestors: reboundAncestors, target: target,
        tolerateMissingAncestors: true)
    }
  }

  private func collect(
    nodeID: Int, ancestors: [Int], target: SiteControlTarget, tolerateMissingAncestors: Bool
  ) async throws -> [ShaarEventListener] {
    var found = try await listeners(on: nodeID, ancestor: false, target: target)
    for ancestor in ancestors {
      do {
        found += try await listeners(on: ancestor, ancestor: true, target: target)
      } catch {
        if tolerateMissingAncestors, ShaarEventListenerNodeLookup.isMissingNode(error) {
          continue
        }
        throw error
      }
    }
    return found
  }

  func remove(_ listener: ShaarEventListener, target: SiteControlTarget) async throws {
    let nodeObjectID = try await nodeObjectID(for: listener.nodeID, target: target)
    defer { Task { await release(nodeObjectID, target: target) } }
    try await edit(
      ShaarEventListenerRequest.remove(listener, nodeObjectID: nodeObjectID), target: target)
    if let handler = listener.handlerObjectID { await release(handler, target: target) }
  }

  func setPassive(_ listener: ShaarEventListener, passive: Bool, target: SiteControlTarget)
    async throws
  {
    let nodeObjectID = try await nodeObjectID(for: listener.nodeID, target: target)
    defer { Task { await release(nodeObjectID, target: target) } }
    try await edit(
      ShaarEventListenerRequest.setPassive(listener, nodeObjectID: nodeObjectID, passive: passive),
      target: target)
  }

  func setOnce(_ listener: ShaarEventListener, once: Bool, target: SiteControlTarget) async throws {
    let nodeObjectID = try await nodeObjectID(for: listener.nodeID, target: target)
    defer { Task { await release(nodeObjectID, target: target) } }
    try await edit(
      ShaarEventListenerRequest.setOnce(listener, nodeObjectID: nodeObjectID, once: once),
      target: target)
  }

  private func listeners(on nodeID: Int, ancestor: Bool, target: SiteControlTarget) async throws
    -> [ShaarEventListener]
  {
    let objectID = try await nodeObjectID(for: nodeID, target: target)
    defer { Task { await release(objectID, target: target) } }
    let request = ShaarEventListenerRequest.listeners(objectID: objectID)
    let payload = try await call(request.0, request.1, target)
    return ShaarEventListenerDecoding.listeners(
      from: payload, nodeID: nodeID, onAncestor: ancestor, nodeObjectID: nil)
  }

  private func nodeObjectID(for nodeID: Int, target: SiteControlTarget) async throws -> String {
    let resolved = try await call("DOM.resolveNode", ["nodeId": nodeID], target)
    guard let objectID = (resolved["object"] as? [String: Any])?["objectId"] as? String,
      !objectID.isEmpty
    else { throw ShaarEventListenersUnavailable() }
    return objectID
  }

  private func edit(_ request: (String, [String: Any])?, target: SiteControlTarget) async throws {
    guard let request else { throw ShaarEventListenersUnavailable() }
    _ = try await call(request.0, request.1, target)
  }

  private func release(_ objectID: String, target: SiteControlTarget) async {
    let request = ShaarEventListenerRequest.release(objectID: objectID)
    _ = try? await call(request.0, request.1, target)
  }
}

enum ShaarEventListenerNodeLookup {
  static func isMissingNode(_ error: Error) -> Bool {
    error.localizedDescription.localizedCaseInsensitiveContains("no node with given id")
  }
}
