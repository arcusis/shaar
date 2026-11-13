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
  var readError: Error?
  var writeError: Error?
  var delayNextRead = false
  var delayNextWrite = false
  var finishRead: (@MainActor @Sendable () -> Void)?
  var finishWrite: (@MainActor @Sendable () -> Void)?

  override func privateCookies(
    forTabID tabID: String, windowID: String, contextID: String, origin: String,
    completion: @escaping @MainActor @Sendable (NSNumber?, Error?) -> Void
  ) {
    if let readError {
      completion(nil, readError)
      return
    }
    let snapshot = actualAllowed
    if let readError {
      completion(nil, readError)
      return
    }
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
    if let writeError {
      completion(writeError)
      return
    }
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

private struct PrivateCookieFailure: Error {}

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

@MainActor @Test func privateCookieFailuresUseLocalizedRecoveryCopy() async throws {
  let readRuntime = PrivateCookieAsyncRuntime()
  readRuntime.readError = NSError(domain: "PrivateCookie", code: 1)
  let readModel = try privateCookieModel(readRuntime)
  await readModel.load()
  #expect(readModel.failure == PrivateSiteControlsModel.loadFailure())
  #expect(
    PrivateSiteControlsModel.loadFailure(language: .hebrew)
      == "לא ניתן לטעון את הרשאות האתר. כדאי לנסות שוב.")

  let writeRuntime = PrivateCookieAsyncRuntime()
  let writeModel = try privateCookieModel(writeRuntime)
  await writeModel.load()
  writeRuntime.writeError = NSError(domain: "PrivateCookie", code: 2)
  await writeModel.setAllowed(true)
  #expect(writeModel.failure == PrivateSiteControlsModel.updateFailure())
  #expect(
    PrivateSiteControlsModel.updateFailure(language: .hebrew)
      == "לא ניתן לעדכן את ההרשאה הזו. כדאי לנסות שוב.")
}

@MainActor @Test func cancelledPrivateCookieReadDoesNotPublishLateState() async throws {
  let runtime = PrivateCookieAsyncRuntime()
  runtime.delayNextRead = true
  let model = try privateCookieModel(runtime)
  let refresh = Task { await model.load() }
  for _ in 0..<100 where runtime.finishRead == nil { await Task.yield() }
  #expect(runtime.finishRead != nil)

  refresh.cancel()
  runtime.finishRead?()
  await refresh.value

  #expect(model.allowed == nil)
  #expect(model.failure == nil)
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

@MainActor @Test func privateCookieReadDuringWriteCannotUndoCompletion() async throws {
  let runtime = PrivateCookieAsyncRuntime()
  let model = try privateCookieModel(runtime)
  await model.load()
  runtime.delayNextWrite = true
  let write = Task { await model.setAllowed(true) }
  for _ in 0..<100 where runtime.finishWrite == nil { await Task.yield() }
  #expect(runtime.finishWrite != nil)

  runtime.delayNextRead = true
  let refresh = Task { await model.load() }
  for _ in 0..<100 where runtime.finishRead == nil { await Task.yield() }
  #expect(runtime.finishRead != nil)

  runtime.finishWrite?()
  await write.value
  #expect(model.allowed == true)
  runtime.finishRead?()
  await refresh.value
  #expect(model.allowed == true)
}

@MainActor @Test func privateCookieFailuresUseLocalizedRecoveryCopy() async throws {
  let readRuntime = PrivateCookieAsyncRuntime()
  readRuntime.readError = PrivateCookieFailure()
  let readModel = try privateCookieModel(readRuntime)
  await readModel.load()
  #expect(
    readModel.failure
      == ShellL10n.string("Could not load private site cookie settings. Try again."))
  #expect(
    PrivateSiteControlsModel.loadFailure(language: .hebrew)
      == "לא ניתן לטעון את הגדרות קובצי ה-Cookie של האתר בחלון הפרטי. כדאי לנסות שוב.")

  let writeRuntime = PrivateCookieAsyncRuntime()
  let writeModel = try privateCookieModel(writeRuntime)
  await writeModel.load()
  writeRuntime.writeError = PrivateCookieFailure()
  await writeModel.setAllowed(true)
  #expect(
    writeModel.failure
      == ShellL10n.string("Could not update private site cookie settings. Try again."))
  #expect(
    PrivateSiteControlsModel.updateFailure(language: .hebrew)
      == "לא ניתן לעדכן את הגדרות קובצי ה-Cookie של האתר בחלון הפרטי. כדאי לנסות שוב.")
}
