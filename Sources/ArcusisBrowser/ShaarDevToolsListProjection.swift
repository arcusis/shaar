// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation

@MainActor @Observable
final class ShaarDevToolsListProjection<Output: Sendable> {
  private(set) var result: Output?
  @ObservationIgnored private var pending: (@Sendable () -> Output)?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var runID = UUID()

  func schedule(_ work: @escaping @Sendable () -> Output) {
    pending = work
    guard task == nil else { return }
    let id = UUID()
    runID = id
    task = Task { [weak self] in await self?.run(id: id) }
  }

  func clear() {
    task?.cancel()
    task = nil
    runID = UUID()
    pending = nil
    result = nil
  }

  private func run(id: UUID) async {
    while !Task.isCancelled && runID == id {
      try? await Task.sleep(for: .milliseconds(50))
      guard !Task.isCancelled, runID == id, let work = pending else { break }
      pending = nil
      let result = await Task.detached(priority: .userInitiated, operation: work).value
      guard !Task.isCancelled, runID == id else { break }
      self.result = result
    }
    if runID == id { task = nil }
  }
}
