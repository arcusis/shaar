// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Serializes writes and replaces pending snapshots during rapid selection changes.
@MainActor
final class SnapshotSaveScheduler {
  private let queue = DispatchQueue(label: "browser.snapshot.persistence", qos: .utility)
  private var pending: DispatchWorkItem?
  private var generation = 0

  func schedule(
    _ write: @escaping @Sendable () throws -> Void,
    completion: @escaping @MainActor @Sendable (String?) -> Void
  ) {
    pending?.cancel()
    generation += 1
    let current = generation
    let item = Self.makeWork(write) { [weak self] failure in
      guard let self, self.generation == current else { return }
      self.pending = nil
      completion(failure)
    }
    pending = item
    queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: item)
  }

  nonisolated private static func makeWork(
    _ write: @escaping @Sendable () throws -> Void,
    completion: @escaping @MainActor @Sendable (String?) -> Void
  ) -> DispatchWorkItem {
    DispatchWorkItem {
      let failure: String?
      do {
        try write()
        failure = nil
      } catch {
        failure = error.localizedDescription
      }
      Task { @MainActor in completion(failure) }
    }
  }

  func writeNow(_ write: @Sendable () throws -> Void) throws {
    pending?.cancel()
    pending = nil
    generation += 1
    try queue.sync(execute: write)
  }
}
