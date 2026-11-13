// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing
import Foundation

@testable import ShaarVerification

@Suite @MainActor struct ReloadWindowProbeTests {
  @Test func newWindowLinksMustProduceANewTab() {
    let source = UUID()
    let oldTab = UUID()
    let newTab = UUID()
    let prior: Set<UUID> = [source, oldTab]

    #expect(
      !ReloadWindowProbe.isDestinationCandidate(
        tabID: source, sourceID: source, prior: prior, requiresNewTab: true))
    #expect(
      !ReloadWindowProbe.isDestinationCandidate(
        tabID: oldTab, sourceID: source, prior: prior, requiresNewTab: true))
    #expect(
      ReloadWindowProbe.isDestinationCandidate(
        tabID: newTab, sourceID: source, prior: prior, requiresNewTab: true))
    #expect(
      ReloadWindowProbe.isDestinationCandidate(
        tabID: source, sourceID: source, prior: prior, requiresNewTab: false))
  }
}
