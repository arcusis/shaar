// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import QuickLookThumbnailing

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
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        start(request) { representation, _ in
          continuation.resume(returning: representation.map(LibraryThumbnailResult.init))
        }
      }
    } onCancel: {
      cancel()
    }
  }

  func cancel() { cancelRequest(request) }
}

struct LibraryThumbnailResult: @unchecked Sendable {
  let representation: QLThumbnailRepresentation
}
