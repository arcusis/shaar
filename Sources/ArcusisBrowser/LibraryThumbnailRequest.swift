// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import QuickLookThumbnailing

final class CancellableContinuation<Value: Sendable>: @unchecked Sendable {
  private enum State {
    case waiting
    case installed(CheckedContinuation<Value, Never>)
    case finished(Value)
  }

  private let lock = NSLock()
  private var state = State.waiting

  func install(_ continuation: CheckedContinuation<Value, Never>) {
    lock.lock()
    let result: Value?
    switch state {
    case .waiting:
      state = .installed(continuation)
      result = nil
    case .installed:
      lock.unlock()
      preconditionFailure("A continuation can only be installed once.")
    case .finished(let value):
      result = value
    }
    lock.unlock()
    if let result { continuation.resume(returning: result) }
  }

  func resume(returning value: Value) {
    lock.lock()
    let continuation: CheckedContinuation<Value, Never>?
    switch state {
    case .waiting:
      state = .finished(value)
      continuation = nil
    case .installed(let installed):
      state = .finished(value)
      continuation = installed
    case .finished:
      continuation = nil
    }
    lock.unlock()
    continuation?.resume(returning: value)
  }
}

final class LibraryThumbnailRequest: @unchecked Sendable {
  typealias Completion = @Sendable (QLThumbnailRepresentation?, (any Error)?) -> Void
  typealias Start = @MainActor (QLThumbnailGenerator.Request, @escaping Completion) -> Void
  typealias Cancel = @Sendable (QLThumbnailGenerator.Request) -> Void

  private let request: QLThumbnailGenerator.Request
  private let start: Start
  private let cancelRequest: Cancel

  init(
    _ request: QLThumbnailGenerator.Request,
    start: @escaping Start = { request, completion in
      QLThumbnailGenerator.shared.generateBestRepresentation(
        for: request, completion: completion)
    },
    cancel: @escaping Cancel = { QLThumbnailGenerator.shared.cancel($0) }
  ) {
    self.request = request
    self.start = start
    self.cancelRequest = cancel
  }

  @MainActor func generate() async -> LibraryThumbnailResult? {
    let completion = CancellableContinuation<LibraryThumbnailResult?>()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        completion.install(continuation)
        guard !Task.isCancelled else {
          completion.resume(returning: nil)
          return
        }
        start(request) { representation, _ in
          completion.resume(returning: representation.map(LibraryThumbnailResult.init))
        }
      }
    } onCancel: {
      let request = self.request
      let cancelRequest = self.cancelRequest
      Task { @MainActor in cancelRequest(request) }
      completion.resume(returning: nil)
    }
  }

  func cancel() { cancelRequest(request) }
}

struct LibraryThumbnailResult: @unchecked Sendable {
  let representation: QLThumbnailRepresentation
}
