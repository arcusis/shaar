// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

@testable import ArcusisBrowser

struct ShaarDevToolsFixtureTransport: ShaarDevToolsEventTransport {
  let fixture: [ShaarDevToolsEvent]
  var revokeAfterEvents = false
  var maskedFrames: [Data] = []

  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarDevToolsTransportMessage> {
    AsyncStream { continuation in
      for event in fixture { continuation.yield(.event(event)) }
      continuation.yield(.streamAvailable)
      for event in fixture { continuation.yield(.event(event)) }
      for frame in maskedFrames { continuation.yield(.maskedFrame(frame)) }
      if revokeAfterEvents { continuation.yield(.streamUnavailable) }
      continuation.finish()
    }
  }
}

@MainActor final class ShaarNetworkRulesFixtureTransport: ShaarNetworkRulesTransport {
  let available = true
  private(set) var lastTarget: SiteControlTarget?
  private(set) var lastRules: [ShaarResolvedNetworkRule] = []

  func apply(_ rules: [ShaarResolvedNetworkRule], to target: SiteControlTarget) async throws {
    lastTarget = target
    lastRules = rules
  }
}
