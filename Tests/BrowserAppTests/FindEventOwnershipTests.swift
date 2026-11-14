// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import Foundation
import ObjectiveC
import ShaarEngineC
import Testing

@Suite @MainActor struct FindEventOwnershipTests {
  private struct Result {
    let tabID: String
    let requestID: String
    let count: Int32
    let active: Int32
    let final: Bool
  }

  @Test func findResultMustMatchItsRequestOwningTab() throws {
    let runtime = try configuredRuntime()

    var results: [Result] = []
    runtime.onFindResult = { tabID, requestID, count, active, final in
      results.append(Result(tabID: tabID, requestID: requestID, count: count, active: active, final: final))
    }

    try sendFindEvent(runtime, tabID: "tab-b")
    #expect(results.isEmpty)

    try sendFindEvent(runtime, tabID: "tab-a")
    #expect(results.count == 1)
    #expect(results.first?.tabID == "tab-a")
    #expect(results.first?.requestID == "request-a")
    #expect(results.first?.count == 1)
    #expect(results.first?.active == 1)
    #expect(results.first?.final == true)
  }

  @Test func findResultRejectsBooleanNumericFields() throws {
    let runtime = try configuredRuntime()
    var callbackCount = 0
    runtime.onFindResult = { _, _, _, _, _ in callbackCount += 1 }

    try sendFindEvent(
      runtime, tabID: "tab-a",
      payload: [
        "schemaVersion": 1, "kind": "result", "requestID": "7",
        "matchCount": true, "activeMatch": 1, "final": true,
      ])

    #expect(callbackCount == 0)
  }

  private func configuredRuntime() throws -> ARCShaarRuntime {
    let runtime = ARCShaarRuntime()
    try setIvar(runtime, "_shaarTabs", [
      "tab-a": NSValue(pointer: UnsafeMutableRawPointer(bitPattern: 0x101)!),
      "tab-b": NSValue(pointer: UnsafeMutableRawPointer(bitPattern: 0x102)!),
    ] as NSDictionary)
    try setIvar(runtime, "_shaarFindTokens", ["7": "request-a"] as NSDictionary)
    try setIvar(runtime, "_shaarFindRequests", ["tab-a": "7"] as NSDictionary)
    try setIvar(runtime, "_shaarTabProfiles", ["tab-a": "PROFILE-A", "tab-b": "PROFILE-A"] as NSDictionary)
    try setIvar(runtime, "_shaarTabWindows", ["tab-a": "window-a", "tab-b": "window-a"] as NSDictionary)
    return runtime
  }

  private func setIvar(_ object: AnyObject, _ name: String, _ value: NSDictionary) throws {
    let ivar = try #require(name.withCString { class_getInstanceVariable(ARCShaarRuntime.self, $0) })
    object_setIvar(object, ivar, value)
  }

  private func sendFindEvent(
    _ runtime: ARCShaarRuntime, tabID: String, payload payloadObject: [String: Any]? = nil
  ) throws {
    let payload = try JSONSerialization.data(withJSONObject: payloadObject ?? [
      "schemaVersion": 1, "kind": "result", "requestID": "7",
      "matchCount": 1, "activeMatch": 1, "final": true,
    ])
    let selector = NSSelectorFromString("receiveEvent:")
    let method = try #require(class_getInstanceMethod(ARCShaarRuntime.self, selector))
    typealias Receiver = @convention(c) (AnyObject, Selector, UnsafePointer<shaar_event>) -> Void
    let receive = unsafeBitCast(method_getImplementation(method), to: Receiver.self)
    let profile = Array("profile-a".utf8)
    let window = Array("window-a".utf8)
    let tab = Array(tabID.utf8)
    payload.withUnsafeBytes { rawBuffer in
      let bytes = rawBuffer.bindMemory(to: CChar.self)
      profile.withUnsafeBufferPointer { profileBytes in
        window.withUnsafeBufferPointer { windowBytes in
          tab.withUnsafeBufferPointer { tabBytes in
            var event = shaar_event()
            event.size = UInt32(MemoryLayout<shaar_event>.size)
            event.kind = SHAAR_EVENT_FIND
            event.profile_id = shaar_bytes(
              data: profileBytes.baseAddress.map {
                UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)
              }, size: profileBytes.count)
            event.window_id = shaar_bytes(
              data: windowBytes.baseAddress.map {
                UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)
              }, size: windowBytes.count)
            event.tab_id = shaar_bytes(
              data: tabBytes.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
              size: tabBytes.count)
            event.payload_json = shaar_bytes(data: bytes.baseAddress, size: bytes.count)
            receive(runtime, selector, &event)
          }
        }
      }
    }
  }
}
