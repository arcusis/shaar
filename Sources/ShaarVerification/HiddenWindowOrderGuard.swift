// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import ObjectiveC.runtime

private typealias WindowOrderImplementation = @convention(c) (AnyObject, Selector, Int, Int) -> Void
private nonisolated(unsafe) var previousWindowOrder: WindowOrderImplementation?

private func hiddenWindowOrder(
  _ window: AnyObject, _ selector: Selector, _ place: Int, _ relative: Int
) {
  guard !HiddenWindowOrderGuard.blocks(place) else { return }
  previousWindowOrder?(window, selector, place, relative)
}

/// The verification process must never put an AppKit window onscreen, even if
/// Chromium or a future host path requests visibility before the probe audits it.
@MainActor
final class HiddenWindowOrderGuard {
  private let method: Method
  private let original: IMP
  private var installed = true

  private init(method: Method, original: IMP) {
    self.method = method
    self.original = original
  }

  static func install() throws -> HiddenWindowOrderGuard {
    guard previousWindowOrder == nil,
      let method = class_getInstanceMethod(
        NSWindow.self, NSSelectorFromString("orderWindow:relativeTo:"))
    else { throw GuardError.unavailable }
    let original = method_getImplementation(method)
    previousWindowOrder = unsafeBitCast(original, to: WindowOrderImplementation.self)
    let replacement = unsafeBitCast(hiddenWindowOrder as WindowOrderImplementation, to: IMP.self)
    method_setImplementation(method, replacement)
    return HiddenWindowOrderGuard(method: method, original: original)
  }

  nonisolated static func blocks(_ place: Int) -> Bool {
    place != NSWindow.OrderingMode.out.rawValue
  }

  func restore() {
    guard installed else { return }
    method_setImplementation(method, original)
    previousWindowOrder = nil
    installed = false
  }

  private enum GuardError: Error { case unavailable }
}
