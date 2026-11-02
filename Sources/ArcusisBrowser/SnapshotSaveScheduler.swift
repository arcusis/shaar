// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Serializes writes off the main thread and replaces snapshots that have not started yet.
///
/// Each write flushes to the storage device, which takes milliseconds, so ordinary changes never
/// wait for it. Deferred changes, such as rapid Space switches, also coalesce.
@MainActor
final class SnapshotSaveScheduler {
  private let queue = DispatchQueue(label: "browser.snapshot.persistence", qos: .utility)
  private let deferredDelay: DispatchTimeInterval
  private var pending: DispatchWorkItem?
  private var pendingWrite: SnapshotWrite?
  private var generation = 0

  init(deferredDelay: DispatchTimeInterval = .milliseconds(250)) {
    self.deferredDelay = deferredDelay
  }

  func schedule(
    deferred: Bool = true,
    _ write: @escaping @Sendable () throws -> Void,
    completion: @escaping @MainActor @Sendable (String?) -> Void
  ) {
    pending?.cancel()
    generation += 1
    let current = generation
    let snapshotWrite = SnapshotWrite(write)
    let item = Self.makeWork(snapshotWrite) { [weak self] failure in
      guard let self, self.generation == current else { return }
      self.pending = nil
      self.pendingWrite = nil
      completion(failure)
    }
    pending = item
    pendingWrite = snapshotWrite
    if deferred {
      queue.asyncAfter(deadline: .now() + deferredDelay, execute: item)
    } else {
      queue.async(execute: item)
    }
  }

  nonisolated private static func makeWork(
    _ write: SnapshotWrite,
    completion: @escaping @MainActor @Sendable (String?) -> Void
  ) -> DispatchWorkItem {
    DispatchWorkItem {
      let failure: String?
      do {
        try write.run()
        failure = nil
      } catch {
        failure = error.localizedDescription
      }
      Task { @MainActor in completion(failure) }
    }
  }

  /// Blocks until the latest scheduled snapshot is on disk, writing a delayed one immediately.
  func flush() throws {
    guard let pendingWrite else { return queue.sync {} }
    pending?.cancel()
    pending = nil
    self.pendingWrite = nil
    try queue.sync { try pendingWrite.run() }
  }

  func writeNow(_ write: @Sendable () throws -> Void) throws {
    pending?.cancel()
    pending = nil
    pendingWrite = nil
    generation += 1
    try queue.sync(execute: write)
  }
}

/// One snapshot write that runs at most once, from its scheduled work item or from a flush.
/// Writing it twice would rotate the backup onto the same snapshot.
private final class SnapshotWrite: @unchecked Sendable {
  private let write: @Sendable () throws -> Void
  private let lock = NSLock()
  private var result: Result<Void, Error>?

  init(_ write: @escaping @Sendable () throws -> Void) { self.write = write }

  func run() throws {
    lock.lock()
    defer { lock.unlock() }
    if result == nil { result = Result { try write() } }
    try result?.get()
  }
}
