// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineABI

/// Phase 2 commands share the Console/Network lease for the selected tab.
@MainActor struct ShaarPhase2NativeTransport: ShaarPhase2Transport {
  let panel: ShaarDevToolsNativeTransport

  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarPhase2Message> {
    let signals = panel.phase2Messages(for: target)
    return AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
      let task = Task {
        for await message in signals {
          switch message {
          case .available:
            do {
              _ = try await panel.phase2Command(.resourceTree, for: target)
              panel.recordPhase2Failure(nil)
              continuation.yield(.available)
            } catch {
              panel.recordPhase2Failure(error)
              continuation.yield(.unavailable)
            }
          case .unavailable:
            continuation.yield(.unavailable)
          case .event(let event):
            continuation.yield(.event(event))
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  func execute(
    _ command: ShaarDevToolsPhase2Command, for target: SiteControlTarget
  ) async throws -> ShaarDevToolsPhase2Reply {
    try await panel.phase2Command(command, for: target)
  }
}
