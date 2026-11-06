// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

@MainActor
final class NativeWindowCreationGuard {
  private let close: () -> Void
  private var isOwned = false

  init(close: @escaping () -> Void) {
    self.close = close
  }

  func transferToOwner() {
    isOwned = true
  }

  func closeIfUnowned() {
    guard !isOwned else { return }
    isOwned = true
    close()
  }
}
