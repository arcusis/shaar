// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import Testing

private final class InspectorTransportRuntime: ARCShaarRuntime {
  var owned = true
  var evaluations = 0

  @objc(shaarDevToolsOwnsTabID:profileID:windowID:)
  func owns(_ tabID: String, profileID: String, windowID: String) -> Bool { owned }

  @objc(privateTabOwned:windowID:contextID:)
  func privateOwns(_ tabID: String, windowID: String, contextID: String) -> Bool { owned }

  @objc(shaarDevToolsCall:params:capability:tabID:profileID:windowID:completion:)
  func call(
    _ method: String, params: [AnyHashable: Any], capability: UInt, tabID: String,
    profileID: String, windowID: String,
    completion: @escaping ([String: Any]?, NSError?) -> Void
  ) {
    evaluations += 1
    completion([:], nil)
  }

  @objc(shaarPrivateDevToolsCall:params:capability:tabID:windowID:contextID:completion:)
  func privateCall(
    _ method: String, params: [AnyHashable: Any], capability: UInt, tabID: String,
    windowID: String, contextID: String,
    completion: @escaping ([String: Any]?, NSError?) -> Void
  ) {
    evaluations += 1
    completion([:], nil)
  }
}

@Suite @MainActor struct InspectorTransportTests {
  @Test func openingInspectorAndPageToolsDoesNotQueueAwaitedKeepalives() {
    let runtime = InspectorTransportRuntime()
    #expect(runtime.beginInspector(forTabID: "tab", profileID: "profile", windowID: "window"))
    #expect(
      runtime.beginInspector(forPrivateTabID: "private", windowID: "window", contextID: "context"))
    #expect(
      runtime.beginDeveloperSession(forTabID: "tab", profileID: "profile", windowID: "window"))
    #expect(runtime.evaluations == 0)
    runtime.endInspector(forTabID: "tab")
    runtime.endInspector(forTabID: "private")
    runtime.endDeveloperSession(forTabID: "tab", profileID: "profile", windowID: "window")
  }

  @Test func persistentSessionsStillRejectUnownedTargets() {
    let runtime = InspectorTransportRuntime()
    runtime.owned = false
    #expect(!runtime.beginInspector(forTabID: "tab", profileID: "profile", windowID: "window"))
    #expect(
      !runtime.beginInspector(forPrivateTabID: "private", windowID: "window", contextID: "context"))
    #expect(
      !runtime.beginDeveloperSession(forTabID: "tab", profileID: "profile", windowID: "window"))
    #expect(runtime.evaluations == 0)
  }
}
