// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import Foundation

/// Keeps every Inspector command bound to its original window and privacy scope.
@MainActor
final class InspectorConnection {
  let runtime: ARCChromiumRuntime
  let windowID: String
  let contextID: String?
  private let owns: (SiteControlTarget) -> Bool
  private let loaded: (UUID) -> Bool

  init(engine: BrowserEngine) {
    runtime = engine.runtime
    windowID = engine.windowID
    contextID = nil
    owns = { [weak engine] target in
      guard let engine, !engine.isClosed else { return false }
      return engine.store?.session.profileID(forTabID: target.tabID) == target.profileID
        && engine.runtime.windowID(forTabID: target.tabID.uuidString) == engine.windowID
    }
    loaded = { [weak engine] in engine?.pages[$0]?.loading == false }
  }

  init(session: PrivatePageSession) {
    runtime = session.runtime
    windowID = session.windowID
    contextID = session.contextID
    owns = { [weak session] in session?.ownsInspectorTarget($0) == true }
    loaded = { [weak session] in session?.pages[$0]?.loading == false }
  }

  func isReady(for target: SiteControlTarget) -> Bool { owns(target) && loaded(target.tabID) }

  func begin(_ target: SiteControlTarget) -> Bool {
    guard owns(target) else { return false }
    if let contextID {
      return runtime.beginInspector(
        forPrivateTabID: target.tabID.uuidString, windowID: windowID, contextID: contextID)
    }
    return runtime.beginInspector(
      forTabID: target.tabID.uuidString, profileID: target.profileID.uuidString, windowID: windowID)
  }

  func end(_ target: SiteControlTarget) { runtime.endInspector(forTabID: target.tabID.uuidString) }

  func call(_ method: String, params: [String: Any], target: SiteControlTarget) async throws
    -> [String: Any]
  {
    guard owns(target) else {
      throw InspectorFailure(InspectorL10n.string("This Inspector target is no longer available."))
    }
    let reply: [String: Any]
    if let contextID {
      reply = try await runtime.privateInspectorCall(
        method, params: params, tabID: target.tabID.uuidString,
        windowID: windowID, contextID: contextID)
    } else {
      reply = try await runtime.inspectorCall(
        method, params: params, tabID: target.tabID.uuidString,
        profileID: target.profileID.uuidString, windowID: windowID)
    }
    guard owns(target) else { throw CancellationError() }
    return reply
  }
}
