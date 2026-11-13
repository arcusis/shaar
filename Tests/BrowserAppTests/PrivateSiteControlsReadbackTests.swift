// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@MainActor
private final class CookieReadbackRuntime: ARCChromiumRuntime {
  var actualAllowed = false
  var writes: [Bool] = []
  var readError: Error?
  var writeError: Error?

  override func privateCookies(
    forTabID tabID: String, windowID: String, contextID: String, origin: String,
    completion: @escaping @MainActor @Sendable (NSNumber?, Error?) -> Void
  ) {
    completion(readError == nil ? NSNumber(value: actualAllowed) : nil, readError)
  }

  override func setPrivateCookiesAllowed(
    _ allowed: Bool, tabID: String, windowID: String, contextID: String, origin: String,
    completion: @escaping @MainActor @Sendable (Error?) -> Void
  ) {
    writes.append(allowed)
    completion(writeError)
  }
}

@MainActor @Test func privateCookieSwitchReflectsEngineReadbackAfterWrite() async throws {
  let runtime = CookieReadbackRuntime()
  let model = try #require(
    PrivateSiteControlsModel(
      tabID: UUID().uuidString, windowID: UUID().uuidString,
      contextID: UUID().uuidString, url: URL(string: "https://example.test")!,
      runtime: runtime))
  await model.load()
  #expect(model.allowed == false)

  await model.setAllowed(true)
  #expect(runtime.writes == [true])
  #expect(model.allowed == false)
  #expect(model.failure != nil)

  runtime.actualAllowed = true
  await model.setAllowed(true)
  #expect(runtime.writes == [true, true])
  #expect(model.allowed == true)
  #expect(model.failure == nil)
}

@MainActor @Test func privateCookieFailuresUseLocalizedMessages() async throws {
  let runtime = CookieReadbackRuntime()
  runtime.readError = NSError(
    domain: "DevTools", code: 1, userInfo: [NSLocalizedDescriptionKey: "The engine refused."])
  let model = try #require(
    PrivateSiteControlsModel(
      tabID: UUID().uuidString, windowID: UUID().uuidString,
      contextID: UUID().uuidString, url: URL(string: "https://example.test")!,
      runtime: runtime))

  await model.load()
  #expect(model.failure == ShellL10n.string("The private cookie setting could not be loaded."))

  runtime.readError = nil
  await model.load()
  runtime.writeError = NSError(
    domain: "DevTools", code: 2, userInfo: [NSLocalizedDescriptionKey: "The engine refused."])
  await model.setAllowed(true)
  #expect(model.failure == ShellL10n.string("The private cookie setting could not be changed."))
}
