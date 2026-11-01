// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Observation

@MainActor @Observable
final class SiteControlsDeveloperModel {
  private(set) var target: SiteControlTarget
  private(set) var simulation: DeveloperSimulation
  var performanceEnabled = false
  var performanceSnapshot: PagePerformanceSnapshot?
  var performanceFailure: String?
  private(set) var documentGeneration = 0
  private(set) var applying = false
  private(set) var failure: String?
  @ObservationIgnored weak var engine: BrowserEngine?
  @ObservationIgnored private var revision = 0
  private(set) var overridesMayBeActive = false
  var hasActiveSimulation: Bool { simulation.isActive || overridesMayBeActive }
  @ObservationIgnored private var userAgent: String?

  init(target: SiteControlTarget, engine: BrowserEngine) {
    self.target = target
    self.engine = engine
    simulation =
      target.origin.map {
        engine.store?.preferences.developerSimulation(on: $0, for: target.profileID)
          ?? DeveloperSimulation()
      } ?? DeveloperSimulation()
  }

  func update(target: SiteControlTarget, committed: Bool = false) {
    let changed = self.target.origin != target.origin || self.target.profileID != target.profileID
    if self.target != target { self.target = target }
    if changed {
      simulation =
        target.origin.map {
          engine?.store?.preferences.developerSimulation(on: $0, for: target.profileID)
            ?? DeveloperSimulation()
        } ?? DeveloperSimulation()
    }
    if committed {
      documentGeneration += 1
      performanceSnapshot = nil
      performanceFailure = nil
      engine?.runtime.endDeveloperSession(forTabID: target.tabID.uuidString)
    }
    if changed || committed { schedule() }
  }

  func set(_ value: DeveloperSimulation) {
    guard target.origin != nil else { return }
    simulation = value
    if let origin = target.origin {
      engine?.store?.preferences.setDeveloperSimulation(value, on: origin, for: target.profileID)
    }
    schedule()
  }

  func schedule() {
    revision += 1
    guard !applying else { return }
    applying = true
    Task { await drain() }
  }

  private func drain() async {
    defer { applying = false }
    var completed = -1
    while completed != revision {
      let current = revision
      let desired = simulation
      let destination = target
      do {
        if performanceEnabled { try retainDeveloperSession() }
        if desired.isActive || overridesMayBeActive {
          guard let engine,
            engine.runtime.beginDeveloperSession(
              forTabID: destination.tabID.uuidString, profileID: destination.profileID.uuidString,
              windowID: engine.windowID)
          else {
            throw DeveloperModeFailure("The developer session could not start.")
          }
          if userAgent == nil {
            userAgent = try await evaluate("navigator.userAgent") as? String
          }
          guard let userAgent else {
            throw DeveloperModeFailure("The page's user agent is unavailable.")
          }
          overridesMayBeActive = true
          for (method, params) in desired.commands(userAgent: userAgent) {
            guard current == revision else { break }
            _ = try await call(method, params: params)
          }
          if current == revision {
            overridesMayBeActive = desired.isActive
            if !desired.isActive && !performanceEnabled {
              engine.runtime.endDeveloperSession(forTabID: destination.tabID.uuidString)
            }
          }
        }
        if !desired.isActive && !overridesMayBeActive && !performanceEnabled {
          engine?.runtime.endDeveloperSession(forTabID: destination.tabID.uuidString)
        }
        if current == revision && destination == target { failure = nil }
      } catch {
        if current == revision { failure = error.localizedDescription }
      }
      completed = current
    }
  }

  func retainDeveloperSession() throws {
    guard let engine,
      engine.runtime.beginDeveloperSession(
        forTabID: target.tabID.uuidString,
        profileID: target.profileID.uuidString, windowID: engine.windowID)
    else {
      throw DeveloperModeFailure("The developer session could not start.")
    }
  }

  func call(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
    guard let engine, !engine.isClosed,
      engine.store?.session.profileID(forTabID: target.tabID) == target.profileID,
      engine.runtime.windowID(forTabID: target.tabID.uuidString) == engine.windowID
    else { throw DeveloperModeFailure("The developer tools target is no longer available.") }
    let destination = target
    let generation = documentGeneration
    let result = try await engine.runtime.developerCall(
      method, params: params, tabID: destination.tabID.uuidString,
      profileID: destination.profileID.uuidString, windowID: engine.windowID)
    guard destination == target && generation == documentGeneration else {
      throw DeveloperModeFailure("The page changed. Try again.")
    }
    return result
  }

  func evaluate(_ expression: String) async throws -> Any? {
    let result = try await call(
      "Runtime.evaluate",
      params: [
        "expression": expression, "returnByValue": true, "awaitPromise": true,
      ])
    if let exception = result["exceptionDetails"] as? [String: Any] {
      let detail =
        (exception["exception"] as? [String: Any])?["description"] as? String
        ?? exception["text"] as? String ?? "Unknown script error"
      throw DeveloperModeFailure("The page script could not complete: \(detail.prefix(240))")
    }
    return (result["result"] as? [String: Any])?["value"]
  }
}

struct DeveloperModeFailure: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}

extension BrowserEngine {
  var selectedDeveloperModel: SiteControlsDeveloperModel? {
    guard let target = siteControlTarget, target.origin != nil else { return nil }
    return developerModel(for: target)
  }

  func developerModel(for target: SiteControlTarget) -> SiteControlsDeveloperModel {
    if let model = developerModels[target.tabID] {
      model.update(target: target)
      return model
    }
    let model = SiteControlsDeveloperModel(target: target, engine: self)
    developerModels[target.tabID] = model
    model.schedule()
    return model
  }

  func developerDocumentChanged(_ tab: UUID, url: URL, committed: Bool = false) {
    guard let profile = store?.session.profileID(forTabID: tab) else { return }
    let target = SiteControlTarget(tabID: tab, profileID: profile, url: url)
    developerModel(for: target).update(target: target, committed: committed)
  }
}
