// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import ObjectiveC.runtime
import Testing

@testable import ShaarVerification

@Suite @MainActor
struct HiddenWindowOrderGuardTests {
  @Test func probeBlocksWindowOrderingBeforeEngineStartup() throws {
    let selector = NSSelectorFromString("orderWindow:relativeTo:")
    let method = try #require(class_getInstanceMethod(NSWindow.self, selector))
    let original = method_getImplementation(method)

    let guardToken = try HiddenWindowOrderGuard.install()
    #expect(method_getImplementation(method) != original)
    #expect(HiddenWindowOrderGuard.blocks(NSWindow.OrderingMode.above.rawValue))
    #expect(HiddenWindowOrderGuard.blocks(NSWindow.OrderingMode.below.rawValue))
    #expect(!HiddenWindowOrderGuard.blocks(NSWindow.OrderingMode.out.rawValue))

    guardToken.restore()
    #expect(method_getImplementation(method) == original)
  }
}
