// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import ShaarEngineABI

enum ShaarPhase2Message {
  case available
  case unavailable
  case event(ShaarDevToolsPhase2Event)
}

@MainActor protocol ShaarPhase2Transport {
  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarPhase2Message>
  func execute(_ command: ShaarDevToolsPhase2Command, for target: SiteControlTarget) async throws
    -> ShaarDevToolsPhase2Reply
}

private struct ShaarPhase2Unavailable: LocalizedError {
  var errorDescription: String? {
    ShellL10n.string("Live Application is unavailable for this tab")
  }
}

/// The app remains unavailable until the engine-backed panel lease is connected.
struct ShaarPhase2PendingTransport: ShaarPhase2Transport {
  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarPhase2Message> {
    AsyncStream { continuation in
      continuation.yield(.unavailable)
      continuation.finish()
    }
  }

  func execute(_ command: ShaarDevToolsPhase2Command, for target: SiteControlTarget) async throws
    -> ShaarDevToolsPhase2Reply
  {
    throw ShaarPhase2Unavailable()
  }
}

@MainActor @Observable
final class ShaarPhase2Model {
  private(set) var target: SiteControlTarget
  private(set) var available = false
  private(set) var events: [ShaarDevToolsPhase2Event] = []
  private(set) var isOpen = false
  @ObservationIgnored private let transport: any ShaarPhase2Transport
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var generation = 0

  var nativeFailure: String? {
    (transport as? ShaarPhase2NativeTransport)?.panel.phase2Failure
  }

  init(target: SiteControlTarget, transport: any ShaarPhase2Transport) {
    self.target = target
    self.transport = transport
  }

  func open() {
    guard !isOpen else { return }
    isOpen = true
    startStream()
  }

  func close() {
    generation += 1
    task?.cancel()
    task = nil
    isOpen = false
    available = false
    events.removeAll()
  }

  func updateTarget(_ target: SiteControlTarget, committed: Bool = false) {
    guard self.target != target || committed else { return }
    self.target = target
    generation += 1
    task?.cancel()
    task = nil
    available = false
    events.removeAll()
    if isOpen { startStream() }
  }

  func execute(_ command: ShaarDevToolsPhase2Command) async throws -> ShaarDevToolsPhase2Reply {
    guard isOpen && available else { throw ShaarPhase2Unavailable() }
    let target = target
    let generation = generation
    let reply = try await transport.execute(command, for: target)
    guard isOpen, available, self.target == target, self.generation == generation else {
      throw CancellationError()
    }
    return reply
  }

  private func startStream() {
    let target = target
    let generation = generation
    task = Task { [weak self, transport] in
      for await message in transport.messages(for: target) {
        guard let self, self.isOpen, self.target == target,
          self.generation == generation
        else { return }
        self.receive(message)
      }
    }
  }

  private func receive(_ message: ShaarPhase2Message) {
    switch message {
    case .available: available = true
    case .unavailable:
      available = false
      events.removeAll()
    case .event(let event):
      events.append(event)
      if events.count > 2_000 { events.removeFirst(events.count - 2_000) }
    }
  }

  isolated deinit { task?.cancel() }
}
