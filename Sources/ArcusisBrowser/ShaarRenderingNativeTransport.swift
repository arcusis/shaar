// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import Foundation

@MainActor
final class ShaarRenderingNativeTransport: ShaarRenderingTransport {
  private let runtime: ARCShaarRuntime
  private let windowID: String
  private let contextID: String?

  init(runtime: ARCShaarRuntime, windowID: String, contextID: String?) {
    self.runtime = runtime
    self.windowID = windowID
    self.contextID = contextID
  }

  func probeOverlay(for target: SiteControlTarget) async -> Bool? {
    do {
      try await send([ShaarRenderingCall(payload: .paintRects(false))], to: target)
      return true
    } catch {
      if ShaarRenderingCapability.targetGone(error) { return nil }
      if ShaarRenderingCapability.isMissing(error) { return false }
      return true
    }
  }

  func send(_ calls: [ShaarRenderingCall], to target: SiteControlTarget) async throws {
    for call in calls {
      try await invoke(call.method, params: call.params, target: target)
    }
  }

  private func invoke(
    _ method: String, params: [String: Any], target: SiteControlTarget
  ) async throws {
    let tabID = target.tabID.uuidString
    if let contextID {
      _ = try await runtime.privateDeveloperCall(
        method, params: params, tabID: tabID, windowID: windowID, contextID: contextID)
      return
    }
    _ = try await runtime.developerCall(
      method, params: params, tabID: tabID, profileID: target.profileID.uuidString,
      windowID: windowID)
  }
}
