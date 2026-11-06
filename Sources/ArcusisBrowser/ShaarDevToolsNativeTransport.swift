// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import Foundation
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

@MainActor final class ShaarDevToolsNativeTransport: ShaarDevToolsEventTransport {
  private let requester: any ShaarPanelRequesting
  private let windowID: String
  private var session: ShaarPanelSession?

  init(requester: any ShaarPanelRequesting, windowID: String) {
    self.requester = requester
    self.windowID = windowID
  }

  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarDevToolsTransportMessage> {
    if let session { close(session) }
    let next = ShaarPanelSession(target: target)
    session = next
    return AsyncStream { continuation in
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
    guard let projected = ShaarDevToolsPanelEventRouter.decode(
      event, scope: ShaarNavigationScope(profileID: profileID), windowID: windowID,
      tabID: tabID, leaseID: leaseID, afterSequence: session.sequence)
    else { return }
    session.sequence = sequence
    if projected.id == .eventsDropped {
      session.continuation?.yield(.streamUnavailable)
      close(session)
      return
    }
    if let frame = projected.data.frame {
      session.continuation?.yield(.maskedFrame(frame.jpeg))
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
    if let event = Self.project(projected) { session.continuation?.yield(.event(event)) }
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
      session.continuation?.yield(.streamAvailable)
      do {
        _ = try await requester.request(
          .panelScreencast, target: session.target,
          payload: ["schemaVersion": 1, "leaseID": leaseID, "commandID": 1])
        session.recording = true
      } catch {
        // Console and Network remain available if video is unsupported.
      }
    } catch {
      guard !session.closed else { return }
      session.continuation?.yield(.streamUnavailable)
      close(session)
    }
  }

  private func close(_ session: ShaarPanelSession) {
    guard !session.closed else { return }
    session.closed = true
    session.task?.cancel()
    if self.session === session { self.session = nil }
    session.continuation?.finish()
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
      return .console(ShaarConsoleEvent(
        id: UUID(), level: level, message: text, source: nil))
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
      return .network(ShaarNetworkEvent(
        id: UUID(), method: data.method ?? "", url: data.url ?? "",
        status: data.status.map(Int.init), requestID: requestID, phase: phase,
        mimeType: data.mimeType, encodedBytes: data.encodedBytes.map(Int.init),
        time: Date().timeIntervalSince1970, failure: phase == .failed ? data.text : nil))
    case .pageLifecycle, .performanceMetrics, .eventsDropped, .screencastFrame:
      return nil
    }
  }
}
