// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@MainActor
private final class PrivateCookieAsyncRuntime: ARCChromiumRuntime {
  var actualAllowed = false
  var delayNextRead = false
  var delayNextWrite = false
  var finishRead: (@MainActor @Sendable () -> Void)?
  var finishWrite: (@MainActor @Sendable () -> Void)?

  override func privateCookies(
    forTabID tabID: String, windowID: String, contextID: String, origin: String,
    completion: @escaping @MainActor @Sendable (NSNumber?, Error?) -> Void
  ) {
    let snapshot = actualAllowed
    if delayNextRead {
      delayNextRead = false
      finishRead = { completion(NSNumber(value: snapshot), nil) }
    } else {
      completion(NSNumber(value: snapshot), nil)
    }
  }

  override func setPrivateCookiesAllowed(
    _ allowed: Bool, tabID: String, windowID: String, contextID: String, origin: String,
    completion: @escaping @MainActor @Sendable (Error?) -> Void
  ) {
    if delayNextWrite {
      delayNextWrite = false
      finishWrite = {
        self.actualAllowed = allowed
        completion(nil)
      }
    } else {
      actualAllowed = allowed
      completion(nil)
    }
  }
}

@MainActor
private func privateCookieModel(_ runtime: ARCChromiumRuntime) throws -> PrivateSiteControlsModel {
  try #require(
    PrivateSiteControlsModel(
      tabID: UUID().uuidString, windowID: UUID().uuidString,
      contextID: UUID().uuidString, url: URL(string: "https://example.test")!,
      runtime: runtime))
}

@MainActor @Test func latePrivateCookieReadDoesNotUndoNewerWrite() async throws {
  let runtime = PrivateCookieAsyncRuntime()
  let model = try privateCookieModel(runtime)
  await model.load()
  #expect(model.allowed == false)
  runtime.delayNextRead = true
  let refresh = Task { await model.load() }
  for _ in 0..<100 where runtime.finishRead == nil { await Task.yield() }
  #expect(runtime.finishRead != nil)

  await model.setAllowed(true)
  #expect(model.allowed == true)
  runtime.finishRead?()
  await refresh.value
  #expect(model.allowed == true)
}

@MainActor @Test func olderPrivateCookieReadCannotReplaceNewerRefresh() async throws {
  let runtime = PrivateCookieAsyncRuntime()
  let model = try privateCookieModel(runtime)
  runtime.delayNextRead = true
  let older = Task { await model.load() }
  for _ in 0..<100 where runtime.finishRead == nil { await Task.yield() }
  #expect(runtime.finishRead != nil)

  runtime.actualAllowed = true
  await model.load()
  #expect(model.allowed == true)
  runtime.finishRead?()
  await older.value
  #expect(model.allowed == true)
}
