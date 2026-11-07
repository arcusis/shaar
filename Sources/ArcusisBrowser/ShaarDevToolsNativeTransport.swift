// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import Foundation
import Observation
import ShaarEngineABI

@MainActor protocol ShaarPanelRequesting {
  func request(
    _ operation: ShaarDevToolsOperation, target: SiteControlTarget, payload: [String: Any]
  ) async throws -> [String: Any]
}

private struct ShaarPanelReply: @unchecked Sendable {
  let value: [String: Any]
}

@MainActor struct ShaarPanelRuntimeRequester: ShaarPanelRequesting {
  let runtime: ARCShaarRuntime
  let windowID: String

  func request(
    _ operation: ShaarDevToolsOperation, target: SiteControlTarget, payload: [String: Any]
  ) async throws -> [String: Any] {
    let reply: ShaarPanelReply = try await withCheckedThrowingContinuation { continuation in
      runtime.panelRequest(
        UInt(operation.rawValue), tabID: target.tabID.uuidString,
        profileID: target.profileID.uuidString, windowID: windowID, payload: payload
      ) { result, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let result {
          continuation.resume(returning: ShaarPanelReply(value: result))
        } else {
          continuation.resume(throwing: ShaarPanelError.unavailable)
        }
      }
    }
    return reply.value
  }
}

private enum ShaarPanelError: Error { case unavailable }

private struct ShaarPhase2NativeError: LocalizedError {
  let errorDescription: String?
}

enum ShaarDOMPanelSignal: Sendable {
  case lease(UInt32)
  case event(ShaarDOMEvent)
  case unavailable
}

private struct ShaarDOMPanelObserver {
  let token: UUID
  let target: SiteControlTarget
  let continuation: AsyncStream<ShaarDOMPanelSignal>.Continuation
}

@MainActor private final class ShaarPanelSession {
  let target: SiteControlTarget
  var leaseID: UInt32?
  var sequence: UInt64 = 0
  var recording = false
  var closed = false
  var continuation: AsyncStream<ShaarDevToolsTransportMessage>.Continuation?
  var task: Task<Void, Never>?

  init(target: SiteControlTarget) { self.target = target }
}

@MainActor @Observable final class ShaarDevToolsNativeTransport: ShaarDevToolsEventTransport {
  private(set) var recordingAvailable = false
  private(set) var recordingFailure: String?
  private(set) var recordingStarting = false
  private(set) var failure: String?
  private(set) var phase2Failure: String?
  @ObservationIgnored private let requester: any ShaarPanelRequesting
  @ObservationIgnored private let windowID: String
  @ObservationIgnored private var session: ShaarPanelSession?
  @ObservationIgnored private var phase2Observers:
    [UUID: (SiteControlTarget, AsyncStream<ShaarPhase2Message>.Continuation)] = [:]
  @ObservationIgnored private var domObserver: ShaarDOMPanelObserver?
  @ObservationIgnored var onLeaseOpened: (() -> Void)?

  var hasActiveLease: Bool {
    guard let session, !session.closed else { return false }
    return session.leaseID != nil
  }

  func activeLease(for target: SiteControlTarget) -> UInt32? {
    guard let session, !session.closed, session.target == target else { return nil }
    return session.leaseID
  }

  func phase2Messages(for target: SiteControlTarget) -> AsyncStream<ShaarPhase2Message> {
    let token = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
      phase2Observers[token] = (target, continuation)
      continuation.yield(activeLease(for: target) == nil ? .unavailable : .available)
      continuation.onTermination = { @Sendable [weak self] _ in
        Task { @MainActor [weak self] in self?.phase2Observers[token] = nil }
      }
    }
  }

  func phase2Command(
    _ command: ShaarDevToolsPhase2Command, for target: SiteControlTarget
  ) async throws -> ShaarDevToolsPhase2Reply {
    guard let leaseID = activeLease(for: target), let params = command.parameters else {
      throw ShaarPhase2NativeError(errorDescription: "DevTools panel is unavailable.")
    }
    let result = try await requester.request(
      .panelPhase2Command, target: target,
      payload: [
        "schemaVersion": 1, "leaseID": leaseID,
        "commandID": command.id, "params": params,
      ])
    guard activeLease(for: target) == leaseID,
      let data = try? JSONSerialization.data(withJSONObject: result),
      let reply = ShaarDevToolsPhase2Reply.decode(data, command: command)
    else { throw ShaarPhase2NativeError(errorDescription: "Invalid DevTools panel reply.") }
    return reply
  }

  func recordPhase2Failure(_ error: Error?) {
    phase2Failure = error?.localizedDescription
  }

  func responseBody(requestID: String, for target: SiteControlTarget) async throws
    -> ShaarStoredResponseBody
  {
    guard let leaseID = activeLease(for: target), !requestID.isEmpty else {
      throw ShaarNetworkBodyError.unavailable
    }
    let reply = try await requester.request(
      .panelGetResponseBody, target: target,
      payload: ["schemaVersion": 1, "leaseID": leaseID, "requestID": requestID])
    guard activeLease(for: target) == leaseID,
      let data = try? JSONSerialization.data(withJSONObject: reply),
      let body = ShaarDevToolsResponseBody.decode(data)
    else { throw ShaarNetworkBodyError.unavailable }
    return ShaarStoredResponseBody(body: body.body, base64Encoded: body.base64Encoded)
  }

  func setNetworkRules(_ rules: [ShaarResolvedNetworkRule], for target: SiteControlTarget)
    async throws
  {
    guard let leaseID = activeLease(for: target), rules.count <= 32 else {
      throw ShaarNetworkRuleError.unavailable
    }
    let rows = rules.map { rule -> [String: Any] in
      let kind = ShaarNetworkRulesLeasedTransport.action(rule).kind.rawValue
      return [
        "method": rule.method, "url": rule.url, "kind": kind,
        "status": rule.status,
        "headers": rule.headers.map { ["name": $0.name, "value": $0.value] },
        "bodyBase64": rule.bodyBase64 ?? "", "redirectURL": rule.redirectURL,
        "delayMilliseconds": rule.delayMilliseconds,
      ]
    }
    let reply = try await requester.request(
      .panelNetworkRules, target: target,
      payload: ["schemaVersion": 1, "leaseID": leaseID, "rules": rows])
    guard activeLease(for: target) == leaseID, reply["schemaVersion"] as? Int == 1 else {
      throw ShaarNetworkRuleError.unavailable
    }
  }

  init(requester: any ShaarPanelRequesting, windowID: String) {
    self.requester = requester
    self.windowID = windowID
  }

  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarDevToolsTransportMessage> {
    if let session { close(session) }
    let next = ShaarPanelSession(target: target)
    session = next
    // The engine flushes a backlog on one turn. A newest-32 buffer drops the
    // console line at the front of that backlog and used to close the lease.
    return AsyncStream(bufferingPolicy: .unbounded) { continuation in
      next.continuation = continuation
      next.task = Task { [weak self] in await self?.start(next) }
      continuation.onTermination = { @Sendable [weak self, weak next] _ in
        Task { @MainActor in
          guard let self, let next else { return }
          self.close(next)
        }
      }
    }
  }

  func domSignals(for target: SiteControlTarget) -> AsyncStream<ShaarDOMPanelSignal> {
    domObserver?.continuation.finish()
    let token = UUID()
    return AsyncStream { continuation in
      domObserver = ShaarDOMPanelObserver(
        token: token, target: target, continuation: continuation)
      if let session, session.target == target, let leaseID = session.leaseID {
        continuation.yield(.lease(leaseID))
      }
      continuation.onTermination = { @Sendable [weak self] _ in
        Task { @MainActor in
          if self?.domObserver?.token == token { self?.domObserver = nil }
        }
      }
    }
  }

  func receive(
    tabID: String, profileID: String, payload: Data, sequence: UInt64
  ) {
    guard let session, !session.closed, let leaseID = session.leaseID,
      session.target.tabID.uuidString == tabID,
      session.target.profileID.uuidString == profileID
    else { return }
    let event = ShaarCopiedEvent(
      sequence: sequence, kind: 14, profileID: Data(profileID.utf8),
      sessionID: Data(), windowID: Data(windowID.utf8),
      tabID: Data(tabID.utf8), payloadJSON: payload)
    if let phase2 = ShaarDevToolsPhase2EventRouter.decode(
      event, scope: ShaarNavigationScope(profileID: profileID),
      windowID: windowID, tabID: tabID, leaseID: leaseID,
      afterSequence: session.sequence)
    {
      session.sequence = sequence
      emitPhase2(.event(phase2), for: session.target)
      return
    }
    if let dom = ShaarDOMEventRouter.decode(
      event, scope: ShaarNavigationScope(profileID: profileID), windowID: windowID,
      tabID: tabID, leaseID: leaseID, afterSequence: session.sequence)
    {
      session.sequence = sequence
      if domObserver?.target == session.target {
        domObserver?.continuation.yield(.event(dom))
      }
      return
    }
    guard
      let projected = ShaarDevToolsPanelEventRouter.decode(
        event, scope: ShaarNavigationScope(profileID: profileID), windowID: windowID,
        tabID: tabID, leaseID: leaseID, afterSequence: session.sequence)
    else { return }
    session.sequence = sequence
    if projected.id == .eventsDropped {
      // Those events are already gone. Closing the lease would also drop every
      // console and network line that arrives after the burst.
      return
    }
    if let frame = projected.data.frame {
      emit(.maskedFrame(frame.jpeg), to: session)
      Task { [weak self, weak session] in
        guard let self, let session, !session.closed else { return }
        try? await self.requester.request(
          .panelScreencast, target: session.target,
          payload: [
            "schemaVersion": 1, "leaseID": leaseID, "commandID": 3,
            "sessionID": frame.sessionID,
          ])
      }
      return
    }
    if let event = Self.project(projected) { emit(.event(event), to: session) }
  }

  private func start(_ session: ShaarPanelSession) async {
    do {
      let reply = try await requester.request(
        .panelOpen, target: session.target, payload: ["schemaVersion": 1])
      guard let raw = reply["leaseID"] as? Int,
        let leaseID = UInt32(exactly: raw), leaseID > 0
      else { throw ShaarPanelError.unavailable }
      guard self.session === session, !session.closed else {
        await closeLease(leaseID, target: session.target)
        return
      }
      session.leaseID = leaseID
      failure = nil
      phase2Failure = nil
      if domObserver?.target == session.target {
        domObserver?.continuation.yield(.lease(leaseID))
      }
      emit(.streamAvailable, to: session)
      emitPhase2(.available, for: session.target)
      onLeaseOpened?()
      guard !session.closed else { return }
      recordingStarting = true
      do {
        _ = try await requester.request(
          .panelScreencast, target: session.target,
          payload: ["schemaVersion": 1, "leaseID": leaseID, "commandID": 1])
        guard self.session === session, !session.closed else { return }
        session.recording = true
        recordingAvailable = true
        recordingFailure = nil
      } catch {
        // Console and Network remain available if video is unsupported.
        recordingFailure = error.localizedDescription
      }
      recordingStarting = false
    } catch {
      guard !session.closed else { return }
      failure = error.localizedDescription
      emit(.streamUnavailable, to: session)
      close(session)
    }
  }

  /// Stops the repro screencast. Its mask style is removed from the page, which
  /// otherwise happens on its own once the document passes 2000 elements and
  /// looks like the Elements tree reloaded.
  func releaseRecording() async {
    guard let session, !session.closed, session.recording, let leaseID = session.leaseID else {
      return
    }
    session.recording = false
    recordingAvailable = false
    try? await requester.request(
      .panelScreencast, target: session.target,
      payload: ["schemaVersion": 1, "leaseID": leaseID, "commandID": 2])
  }

  private func emit(_ message: ShaarDevToolsTransportMessage, to session: ShaarPanelSession) {
    guard let continuation = session.continuation else { return }
    switch continuation.yield(message) {
    case .enqueued, .dropped: break
    case .terminated: close(session)
    @unknown default: close(session)
    }
  }

  private func close(_ session: ShaarPanelSession) {
    guard !session.closed else { return }
    session.closed = true
    if domObserver?.target == session.target {
      domObserver?.continuation.yield(.unavailable)
    }
    recordingAvailable = false
    recordingStarting = false
    session.task?.cancel()
    if self.session === session { self.session = nil }
    session.continuation?.finish()
    emitPhase2(.unavailable, for: session.target)
    guard let leaseID = session.leaseID else { return }
    Task { [requester] in
      if session.recording {
        try? await requester.request(
          .panelScreencast, target: session.target,
          payload: ["schemaVersion": 1, "leaseID": leaseID, "commandID": 2])
      }
      try? await requester.request(
        .panelClose, target: session.target,
        payload: ["schemaVersion": 1, "leaseID": leaseID])
    }
  }

  private func emitPhase2(_ message: ShaarPhase2Message, for target: SiteControlTarget) {
    for (scope, continuation) in phase2Observers.values where scope == target {
      continuation.yield(message)
    }
  }

  private func closeLease(_ leaseID: UInt32, target: SiteControlTarget) async {
    try? await requester.request(
      .panelClose, target: target,
      payload: ["schemaVersion": 1, "leaseID": leaseID])
  }

  private static func project(_ event: ShaarDevToolsPanelEvent) -> ShaarDevToolsEvent? {
    let data = event.data
    switch event.id {
    case .consoleAPICalled, .logEntryAdded, .exceptionThrown:
      guard let text = data.text else { return nil }
      let level: ShaarConsoleEvent.Level
      switch data.level {
      case "error": level = .error
      case "warning", "warn": level = .warning
      case "info": level = .info
      default: level = .log
      }
      let frames =
        data.stack.isEmpty
        ? ShaarConsoleLocations.frames(in: text)
        : data.stack.map { ShaarConsoleFrame(function: $0.function, source: $0.source) }
      return .console(
        ShaarConsoleEvent(
          id: UUID(), level: level, message: text,
          source: frames.first?.source, stack: frames))
    case .requestWillBeSent, .responseReceived, .loadingFinished,
      .loadingFailed, .dataReceived:
      guard let requestID = data.requestID else { return nil }
      let phase: ShaarNetworkEvent.Phase
      switch event.id {
      case .requestWillBeSent: phase = .request
      case .responseReceived: phase = .response
      case .loadingFinished: phase = .finished
      case .loadingFailed: phase = .failed
      default: phase = .data
      }
      return .network(
        ShaarNetworkEvent(
          id: UUID(), method: data.method ?? "", url: data.url ?? "",
          status: data.status.map(Int.init), requestID: requestID, phase: phase,
          mimeType: data.mimeType, encodedBytes: data.encodedBytes.map(Int.init),
          time: Date().timeIntervalSince1970, failure: phase == .failed ? data.text : nil,
          requestHeaders: data.requestHeaders.map {
            ShaarNetworkHeader(name: $0.name, value: $0.value)
          },
          responseHeaders: data.responseHeaders.map {
            ShaarNetworkHeader(name: $0.name, value: $0.value)
          }))
    case .pageLifecycle, .performanceMetrics, .eventsDropped, .screencastFrame:
      return nil
    }
  }
}
