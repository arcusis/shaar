// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Observation

@MainActor @Observable
final class DeveloperPageModel {
  private(set) var target: SiteControlTarget
  let agentBridge: AgentBridgeModel
  private(set) var simulation: DeveloperSimulation
  var includeSensitiveHeaders = false
  var creatingBugReport = false
  var reportFailure: String?
  var reportURL: URL?
  var performanceEnabled = false
  var performanceSnapshot: PagePerformanceSnapshot?
  private(set) var documentGeneration = 0
  private(set) var applying = false
  private(set) var failure: String?
  @ObservationIgnored weak var engine: BrowserEngine?
  @ObservationIgnored private var revision = 0
  @ObservationIgnored private(set) var closed = false
  private(set) var overridesMayBeActive = false
  var hasActiveSimulation: Bool { simulation.isActive || overridesMayBeActive }
  @ObservationIgnored private var userAgent: String?
  @ObservationIgnored private var builtInToolsOpen = false
  @ObservationIgnored private var mediaMonitor: Task<Void, Never>?
  @ObservationIgnored private var drainTask: Task<Void, Never>?
  @ObservationIgnored var bugReportArchiveWriter: ([String: Data], URL) async throws -> URL = {
    files, directory in
    try await BugReportArchive.save(files: files, directory: directory)
  }

  init(target: SiteControlTarget, engine: BrowserEngine?) {
    self.target = target
    self.engine = engine
    agentBridge = AgentBridgeModel(target: target) { [weak engine] operation, target, completion in
      guard let engine, !engine.isClosed else {
        completion(nil, AgentBridgeFailure.invalidReply)
        return
      }
      engine.runtime.agentBridgeRequest(
        UInt(operation.rawValue), forTabID: target.tabID.uuidString,
        profileID: target.profileID.uuidString, windowID: engine.windowID,
        completion: completion)
    }
    simulation =
      target.origin.map {
        engine?.store?.preferences.developerSimulation(on: $0, for: target.profileID)
          ?? DeveloperSimulation()
      } ?? DeveloperSimulation()
  }

  func update(target: SiteControlTarget, committed: Bool = false) {
    guard !closed else { return }
    let changed = self.target.origin != target.origin || self.target.profileID != target.profileID
    let toolsOpen = engine?.runtime.devToolsView(forTabID: target.tabID.uuidString) != nil
    let toolsChanged = toolsOpen != builtInToolsOpen
    builtInToolsOpen = toolsOpen
    if self.target != target { self.target = target }
    agentBridge.update(target: target, committed: committed)
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
      endSession()
    }
    if changed || committed || toolsChanged { schedule() }
  }

  func set(_ value: DeveloperSimulation) {
    guard !closed, target.origin != nil || value == DeveloperSimulation() else { return }
    simulation = value
    if let origin = target.origin {
      engine?.store?.preferences.setDeveloperSimulation(value, on: origin, for: target.profileID)
    }
    schedule()
  }

  func schedule() {
    guard !closed else { return }
    revision += 1
    monitorInspectorMedia()
    guard !applying else { return }
    applying = true
    drainTask = Task { [weak self] in
      guard let self else { return }
      await self.drain()
      self.drainTask = nil
    }
  }

  private func monitorInspectorMedia() {
    mediaMonitor?.cancel()
    mediaMonitor = nil
    guard simulation.darkMode || simulation.reducedMotion else { return }
    mediaMonitor = Task { [weak self] in
      var dockWasOpen = false
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        guard let self, !Task.isCancelled, let engine = self.engine, !engine.isClosed else {
          return
        }
        guard engine.runtime.devToolsView(forTabID: self.target.tabID.uuidString) != nil else {
          // Closing Chromium's frontend can reset media just as opening it does.
          if dockWasOpen {
            self.schedule()
            return
          }
          continue
        }
        dockWasOpen = true
        guard !self.applying else { continue }
        let target = self.target
        let desired = self.simulation
        let expression =
          "(!\(desired.darkMode) || matchMedia('(prefers-color-scheme: dark)').matches) && (!\(desired.reducedMotion) || matchMedia('(prefers-reduced-motion: reduce)').matches)"
        do {
          let matches = try await self.evaluate(expression) as? Bool
          guard !Task.isCancelled, target == self.target, desired == self.simulation else {
            return
          }
          if matches == false { self.schedule() }
        } catch {
          // Navigation can replace the execution context; its commit reapplies simulations.
        }
      }
    }
  }

  private func drain() async {
    defer {
      applying = false
      if closed { endSession() }
    }
    var completed = -1
    while completed != revision && !closed {
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
            throw DeveloperModeFailure(
              InspectorToolsL10n.string("The developer session could not start."))
          }
          if userAgent == nil {
            userAgent = try await evaluate("navigator.userAgent") as? String
          }
          guard let userAgent else {
            throw DeveloperModeFailure(
              InspectorToolsL10n.string("The page's user agent is unavailable."))
          }
          overridesMayBeActive = true
          for (method, params) in desired.commands(userAgent: userAgent) {
            guard current == revision else { break }
            _ = try await call(method, params: params)
          }
          if current == revision {
            overridesMayBeActive = desired.isActive
            if !desired.isActive && !performanceEnabled {
              endSession()
            }
          }
        }
        if !desired.isActive && !overridesMayBeActive && !performanceEnabled {
          endSession()
        }
        if current == revision && destination == target { failure = nil }
      } catch {
        if current == revision { failure = Self.failureMessage(for: error) }
      }
      completed = current
    }
  }

  static func failureMessage(for error: Error) -> String {
    if error is DeveloperModeFailure { return error.localizedDescription }
    return InspectorToolsL10n.string("Could not apply developer settings. Try again.")
  }

  func endSession() {
    guard let engine else { return }
    engine.runtime.endDeveloperSession(
      forTabID: target.tabID.uuidString,
      profileID: target.profileID.uuidString, windowID: engine.windowID)
  }

  func close() {
    agentBridge.close()
    closed = true
    revision += 1
    drainTask?.cancel()
    drainTask = nil
    mediaMonitor?.cancel()
    mediaMonitor = nil
    performanceEnabled = false
    endSession()
  }

  func retainDeveloperSession() throws {
    guard !closed, let engine,
      engine.runtime.beginDeveloperSession(
        forTabID: target.tabID.uuidString,
        profileID: target.profileID.uuidString, windowID: engine.windowID)
    else {
      throw DeveloperModeFailure(
        InspectorToolsL10n.string("The developer session could not start."))
    }
  }

  func call(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
    guard !closed, let engine, !engine.isClosed,
      engine.store?.session.profileID(forTabID: target.tabID) == target.profileID,
      engine.runtime.windowID(forTabID: target.tabID.uuidString) == engine.windowID
    else {
      throw DeveloperModeFailure(
        InspectorToolsL10n.string("The developer tools target is no longer available."))
    }
    let destination = target
    let generation = documentGeneration
    let call = DeveloperCallContinuation()
    let result = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        call.install(continuation)
        guard !Task.isCancelled else {
          call.resume(.failure(CancellationError()))
          return
        }
        engine.runtime.developerCall(
          method, params: params, tabID: destination.tabID.uuidString,
          profileID: destination.profileID.uuidString, windowID: engine.windowID
        ) { result, error in
          if let error {
            call.resume(.failure(error))
          } else if let result {
            call.resume(.success(DeveloperCallValue(result)))
          } else {
            call.resume(.failure(DeveloperModeFailure(
              InspectorToolsL10n.string("The developer tools returned no result."))))
          }
        }
      }
    } onCancel: {
      call.resume(.failure(CancellationError()))
    }
    .value
    guard !closed, destination == target && generation == documentGeneration else {
      throw DeveloperModeFailure(InspectorToolsL10n.string("The page changed. Try again."))
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
        ?? exception["text"] as? String ?? InspectorToolsL10n.string("Unknown script error")
      throw DeveloperModeFailure(
        InspectorToolsL10n.format(
          "The page script could not complete: %@",
          arguments: [.string(String(detail.prefix(240)))]))
    }
    return (result["result"] as? [String: Any])?["value"]
  }
}

struct DeveloperModeFailure: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}

private struct DeveloperCallValue: @unchecked Sendable {
  let value: [String: Any]

  init(_ value: [String: Any]) { self.value = value }
}

private final class DeveloperCallContinuation: @unchecked Sendable {
  private enum State {
    case waiting
    case installed(CheckedContinuation<DeveloperCallValue, any Error>)
    case finished(Result<DeveloperCallValue, any Error>)
  }

  private let lock = NSLock()
  private var state = State.waiting

  func install(_ continuation: CheckedContinuation<DeveloperCallValue, any Error>) {
    lock.lock()
    switch state {
    case .waiting:
      state = .installed(continuation)
      lock.unlock()
    case .installed:
      lock.unlock()
      preconditionFailure("A developer call continuation can only be installed once.")
    case .finished(let result):
      lock.unlock()
      continuation.resume(with: result)
    }
  }

  func resume(_ result: Result<DeveloperCallValue, any Error>) {
    lock.lock()
    let continuation: CheckedContinuation<DeveloperCallValue, any Error>?
    switch state {
    case .waiting:
      state = .finished(result)
      continuation = nil
    case .installed(let installed):
      state = .finished(result)
      continuation = installed
    case .finished:
      continuation = nil
    }
    lock.unlock()
    continuation?.resume(with: result)
  }
}

extension BrowserEngine {
  var selectedDeveloperModel: DeveloperPageModel? {
    guard let target = siteControlTarget, target.origin != nil else { return nil }
    return developerModel(for: target)
  }

  func developerModel(for target: SiteControlTarget) -> DeveloperPageModel {
    if let model = developerModels[target.tabID] {
      model.update(target: target)
      return model
    }
    let model = DeveloperPageModel(target: target, engine: self)
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
