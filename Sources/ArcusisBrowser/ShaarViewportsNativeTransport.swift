// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import Foundation
import ShaarEngineABI

@MainActor protocol ShaarViewportRequesting {
  func request(
    _ operation: ShaarDevToolsOperation, target: SiteControlTarget, payload: [String: Any]
  ) async throws -> [String: Any]
}

/// Native replies are delivered on the engine's main thread and consumed on the main actor.
private struct ShaarViewportReplyBox: @unchecked Sendable {
  let value: [String: Any]
}

@MainActor struct ShaarViewportRuntimeRequester: ShaarViewportRequesting {
  let runtime: ARCShaarRuntime
  let windowID: String
  let contextID: String?

  func request(
    _ operation: ShaarDevToolsOperation, target: SiteControlTarget, payload: [String: Any]
  ) async throws -> [String: Any] {
    let reply: ShaarViewportReplyBox = try await withCheckedThrowingContinuation { continuation in
      runtime.viewportRequest(
        UInt(operation.rawValue), tabID: target.tabID.uuidString,
        profileID: target.profileID.uuidString, windowID: windowID,
        contextID: contextID, payload: payload
      ) { result, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let result {
          continuation.resume(returning: ShaarViewportReplyBox(value: result))
        } else {
          continuation.resume(throwing: ShaarViewportsError.unavailable)
        }
      }
    }
    return reply.value
  }
}

@MainActor private final class ShaarViewportSessionState {
  let target: SiteControlTarget
  var leaseID: Int?
  var mirroredScheme: ShaarViewportColorScheme?
  var frames: [(nativeID: Int, frame: ShaarViewportFrame)] = []
  var continuation: AsyncStream<ShaarViewportsMessage>.Continuation?
  var task: Task<Void, Never>?
  var closed = false

  init(target: SiteControlTarget) { self.target = target }
}

@MainActor final class ShaarViewportsNativeTransport: ShaarViewportsTransport {
  private let requester: any ShaarViewportRequesting
  private var session: ShaarViewportSessionState?

  init(requester: any ShaarViewportRequesting) { self.requester = requester }

  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarViewportsMessage> {
    if let session { close(session) }
    let next = ShaarViewportSessionState(target: target)
    session = next
    return AsyncStream { continuation in
      next.continuation = continuation
      next.task = Task { [weak self] in
        guard let self else { return }
        await self.start(next)
      }
      continuation.onTermination = { @Sendable [weak self, weak next] _ in
        Task { @MainActor in
          guard let self, let next else { return }
          self.close(next)
        }
      }
    }
  }

  func perform(_ action: ShaarViewportAction, for target: SiteControlTarget) async throws {
    guard let session, !session.closed, session.target == target,
      let leaseID = session.leaseID
    else { throw ShaarViewportsError.unavailable }
    switch action {
    case .add(let preset):
      guard session.frames.count < 4 else { throw ShaarViewportsError.invalidAction }
      try await add(preset, to: session, leaseID: leaseID)
    case .remove(let id):
      guard session.frames.count > 1,
        let nativeID = session.frames.first(where: { $0.frame.id == id })?.nativeID
      else { throw ShaarViewportsError.invalidAction }
      _ = try await requester.request(
        .viewportRemove, target: target,
        payload: ["schemaVersion": 1, "leaseID": leaseID, "viewportID": nativeID])
      guard current(session) else { throw ShaarViewportsError.staleTarget }
      session.frames.removeAll { $0.nativeID == nativeID }
    case .setSafeArea(let id, let insets):
      guard insets.isValid, let index = session.frames.firstIndex(where: { $0.frame.id == id })
      else { throw ShaarViewportsError.invalidAction }
      let nativeID = session.frames[index].nativeID
      _ = try await actionRequest(
        session, leaseID: leaseID,
        fields: ["kind": "safeArea", "viewportID": nativeID, "insets": insets.dictionary])
      guard current(session) else { throw ShaarViewportsError.staleTarget }
      guard let currentIndex = session.frames.firstIndex(where: { $0.nativeID == nativeID }) else {
        throw ShaarViewportsError.staleTarget
      }
      let old = session.frames[currentIndex].frame
      session.frames[currentIndex].frame = copy(old, safeArea: insets)
    case .rotate(let id):
      let nativeID = try viewportID(id, in: session)
      _ = try await actionRequest(
        session, leaseID: leaseID, fields: ["kind": "rotate", "viewportID": nativeID])
      guard current(session),
        let index = session.frames.firstIndex(where: { $0.nativeID == nativeID })
      else { throw ShaarViewportsError.staleTarget }
      session.frames[index].frame = session.frames[index].frame.rotated(keepingImage: false)
    case .click(let id, let x, let y):
      let nativeID = try viewportID(id, in: session)
      _ = try await actionRequest(
        session, leaseID: leaseID,
        fields: ["kind": "click", "viewportID": nativeID, "x": x, "y": y])
    case .hover(let id, let x, let y):
      let nativeID = try viewportID(id, in: session)
      _ = try await actionRequest(
        session, leaseID: leaseID,
        fields: ["kind": "hover", "viewportID": nativeID, "x": x, "y": y])
    case .type(let id, let text):
      guard ShaarViewportTyping.isValid(text) else { throw ShaarViewportsError.invalidAction }
      let nativeID = try viewportID(id, in: session)
      _ = try await actionRequest(
        session, leaseID: leaseID,
        fields: ["kind": "type", "viewportID": nativeID, "text": text])
    case .setColorScheme(let id, let scheme):
      let nativeID = try viewportID(id, in: session)
      _ = try await actionRequest(
        session, leaseID: leaseID,
        fields: ["kind": "colorScheme", "viewportID": nativeID, "scheme": scheme.rawValue])
      guard current(session),
        let index = session.frames.firstIndex(where: { $0.nativeID == nativeID })
      else { throw ShaarViewportsError.staleTarget }
      session.mirroredScheme = nil
      session.frames[index].frame = copy(session.frames[index].frame, colorScheme: scheme)
    case .mirrorColorScheme(let scheme):
      _ = try await actionRequest(
        session, leaseID: leaseID, fields: ["kind": "colorScheme", "scheme": scheme.rawValue])
      guard current(session) else { throw ShaarViewportsError.staleTarget }
      session.mirroredScheme = scheme
      session.frames = session.frames.map { nativeID, frame in
        (nativeID, copy(frame, colorScheme: scheme))
      }
    case .scroll(let id, let deltaX, let deltaY):
      let nativeID = try viewportID(id, in: session)
      _ = try await actionRequest(
        session, leaseID: leaseID,
        fields: [
          "kind": "scroll", "viewportID": nativeID, "deltaX": deltaX, "deltaY": deltaY,
        ])
    case .navigate(let url):
      _ = try await actionRequest(
        session, leaseID: leaseID, fields: ["kind": "navigate", "url": url.absoluteString])
      guard current(session) else { throw ShaarViewportsError.staleTarget }
      session.frames = session.frames.map { nativeID, frame in
        (nativeID, copy(frame, url: url, pngData: Data()))
      }
    }
    guard current(session) else { throw ShaarViewportsError.staleTarget }
    emitFrames(session)
  }

  private func start(_ session: ShaarViewportSessionState) async {
    do {
      let reply = try await requester.request(
        .viewportOpen, target: session.target, payload: ["schemaVersion": 1])
      guard reply["schemaVersion"] as? Int == 1,
        let leaseID = reply["leaseID"] as? Int, leaseID > 0
      else {
        throw ShaarViewportsError.unavailable
      }
      if session.closed {
        await closeNative(leaseID, target: session.target)
        return
      }
      session.leaseID = leaseID
      try await add(.iphone15Pro, to: session, leaseID: leaseID)
      try await add(.desktop, to: session, leaseID: leaseID)
      guard current(session) else { return }
      session.continuation?.yield(.capabilities(capabilities(in: reply)))
      session.continuation?.yield(.available)
      emitFrames(session)
      while current(session) {
        await refreshFrames(session, leaseID: leaseID)
        try await Task.sleep(for: .milliseconds(500))
      }
    } catch {
      guard current(session) else { return }
      session.continuation?.yield(.unavailable)
      session.continuation?.finish()
      close(session)
    }
  }

  private func add(
    _ preset: ShaarViewportPreset, to session: ShaarViewportSessionState, leaseID: Int
  ) async throws {
    let reply = try await requester.request(
      .viewportAdd, target: session.target,
      payload: [
        "schemaVersion": 1, "leaseID": leaseID, "preset": preset.rawValue,
        "width": preset.width, "height": preset.height,
      ])
    guard current(session), reply["schemaVersion"] as? Int == 1,
      let nativeID = reply["viewportID"] as? Int, nativeID > 0,
      !session.frames.contains(where: { $0.nativeID == nativeID })
    else { throw ShaarViewportsError.staleTarget }
    var frame = ShaarViewportFrame(
      id: UUID(), preset: preset,
      url: session.frames.first?.frame.url ?? session.target.url, pngData: Data(),
      safeArea: preset.defaultInsets)
    if let scheme = session.mirroredScheme, scheme != .noPreference {
      _ = try await actionRequest(
        session, leaseID: leaseID,
        fields: ["kind": "colorScheme", "viewportID": nativeID, "scheme": scheme.rawValue])
      guard current(session) else { throw ShaarViewportsError.staleTarget }
      frame = copy(frame, colorScheme: scheme)
    }
    session.frames.append((nativeID, frame))
  }

  private func capabilities(in reply: [String: Any]) -> ShaarViewportCapabilities {
    ShaarViewportCapabilities(
      colorScheme: reply["colorScheme"] as? Int == 1,
      hover: reply["hover"] as? Int == 1,
      typing: reply["typing"] as? Int == 1)
  }

  private func copy(
    _ frame: ShaarViewportFrame, url: URL? = nil, pngData: Data? = nil,
    safeArea: ShaarViewportInsets? = nil, colorScheme: ShaarViewportColorScheme? = nil
  ) -> ShaarViewportFrame {
    ShaarViewportFrame(
      id: frame.id, preset: frame.preset, url: url ?? frame.url, pngData: pngData ?? frame.pngData,
      safeArea: safeArea ?? frame.safeArea, orientation: frame.orientation,
      colorScheme: colorScheme ?? frame.colorScheme)
  }

  private func refreshFrames(_ session: ShaarViewportSessionState, leaseID: Int) async {
    let viewportIDs = session.frames.map(\.nativeID)
    for nativeID in viewportIDs {
      guard current(session) else { return }
      guard
        let reply = try? await requester.request(
          .viewportFrame, target: session.target,
          payload: ["schemaVersion": 1, "leaseID": leaseID, "viewportID": nativeID]),
        current(session), let index = session.frames.firstIndex(where: { $0.nativeID == nativeID }),
        let frame = decodeFrame(reply, old: session.frames[index].frame, nativeID: nativeID)
      else { continue }
      session.frames[index].frame = frame
    }
    emitFrames(session)
  }

  private func decodeFrame(
    _ reply: [String: Any], old: ShaarViewportFrame, nativeID: Int
  ) -> ShaarViewportFrame? {
    guard reply["schemaVersion"] as? Int == 1,
      reply["viewportID"] as? Int == nativeID,
      let address = reply["url"] as? String, address.utf8.count <= 8192,
      let url = URL(string: address), ["http", "https", "file"].contains(url.scheme ?? ""),
      let encoded = reply["data"] as? String, encoded.utf8.count <= 11_184_816,
      let data = Data(base64Encoded: encoded), data.count <= 8 * 1024 * 1024,
      data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    else { return nil }
    return copy(old, url: url, pngData: data)
  }

  private func actionRequest(
    _ session: ShaarViewportSessionState, leaseID: Int, fields: [String: Any]
  ) async throws -> [String: Any] {
    var payload = fields
    payload["schemaVersion"] = 1
    payload["leaseID"] = leaseID
    let reply = try await requester.request(
      .viewportAction, target: session.target, payload: payload)
    guard current(session) else { throw ShaarViewportsError.staleTarget }
    return reply
  }

  private func viewportID(_ id: UUID, in session: ShaarViewportSessionState) throws -> Int {
    guard let nativeID = session.frames.first(where: { $0.frame.id == id })?.nativeID else {
      throw ShaarViewportsError.invalidAction
    }
    return nativeID
  }

  private func emitFrames(_ session: ShaarViewportSessionState) {
    let frames = session.frames.map(\.frame)
    guard current(session), !frames.isEmpty, Set(frames.map(\.url)).count == 1 else { return }
    session.continuation?.yield(.frames(frames))
  }

  private func current(_ session: ShaarViewportSessionState) -> Bool {
    self.session === session && !session.closed
  }

  private func close(_ session: ShaarViewportSessionState) {
    guard !session.closed else { return }
    session.closed = true
    session.task?.cancel()
    session.task = nil
    session.continuation?.finish()
    session.continuation = nil
    if self.session === session { self.session = nil }
    if let leaseID = session.leaseID {
      Task { await closeNative(leaseID, target: session.target) }
    }
  }

  private func closeNative(_ leaseID: Int, target: SiteControlTarget) async {
    _ = try? await requester.request(
      .viewportClose, target: target, payload: ["schemaVersion": 1, "leaseID": leaseID])
  }
}

extension ShaarViewportInsets {
  fileprivate var dictionary: [String: Int] {
    ["top": top, "right": right, "bottom": bottom, "left": left]
  }
}
