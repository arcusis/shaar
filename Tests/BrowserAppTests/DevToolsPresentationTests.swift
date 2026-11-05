// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import ShaarEngineC
import Testing

private final class RejectedDevToolsRuntime: ARCShaarRuntime {
  var rejects = true
  var frontendOpen = false
  var operations: [UInt] = []
  @objc(shaarDevToolsOwnsTabID:profileID:windowID:)
  func owns(_ tabID: String, profileID: String?, windowID: String?) -> Bool { true }

  @objc(shaarDevToolsSubmit:tabID:profileID:windowID:payload:completion:)
  func submit(
    _ operation: UInt, tabID: String, profileID: String?, windowID: String?,
    payload: [AnyHashable: Any], completion: @escaping ([String: Any]?, NSError?) -> Void
  ) -> Bool {
    operations.append(operation)
    if !rejects {
      if operation == UInt(SHAAR_OP_DEVTOOLS_UI_STATE.rawValue) {
        completion(["open": frontendOpen], nil)
      } else {
        frontendOpen = operation == UInt(SHAAR_OP_DEVTOOLS_UI_SHOW.rawValue)
        completion([:], nil)
      }
      return true
    }
    completion(
      nil,
      NSError(
        domain: "test", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "DevTools frontend is not ready."]))
    return true
  }
}

@Suite @MainActor struct DevToolsPresentationTests {
  @Test func nativeRejectionDoesNotLeaveAFakeOpenFrontendAndReportsTheError() {
    let runtime = RejectedDevToolsRuntime()
    var notice: String?
    runtime.onNotice = { notice = $0 }
    _ = runtime.showDevTools(forTabID: "tab")
    #expect(runtime.devToolsView(forTabID: "tab") == nil)
    #expect(notice == "DevTools frontend is not ready.")
  }

  @Test func shortcutReopensAFrontendClosedThroughItsNativeWindow() async throws {
    let runtime = RejectedDevToolsRuntime()
    runtime.rejects = false
    #expect(runtime.showDevTools(forTabID: "tab"))
    #expect(runtime.devToolsView(forTabID: "tab") != nil)
    runtime.frontendOpen = false
    runtime.operations = []
    try await runtime.toggleDevTools(forTabID: "tab")
    #expect(runtime.frontendOpen)
    #expect(
      runtime.operations == [
        UInt(SHAAR_OP_DEVTOOLS_UI_STATE.rawValue),
        UInt(SHAAR_OP_DEVTOOLS_UI_SHOW.rawValue),
      ])
    try await runtime.toggleDevTools(forTabID: "tab")
    #expect(!runtime.frontendOpen)
    #expect(runtime.devToolsView(forTabID: "tab") == nil)
  }
}
